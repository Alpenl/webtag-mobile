package com.alpenl.webtag.share

import android.content.Intent
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.lifecycle.lifecycleScope
import com.alpenl.webtag.share.contract.ErrorKind
import com.alpenl.webtag.share.contract.QueueError
import com.alpenl.webtag.share.contract.QueueState
import com.alpenl.webtag.share.contract.SessionIdentity
import com.alpenl.webtag.share.contract.SubmissionOutcome
import com.alpenl.webtag.share.contract.UrlCandidate
import com.alpenl.webtag.share.contract.UrlCandidateExtractor
import com.alpenl.webtag.share.queue.MobileRuntime
import com.alpenl.webtag.share.ui.theme.WebTagShareTheme
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

internal data class ShareActivityRestoredState(
    val processed: Boolean,
    val selectedIndex: Int,
    val status: String?,
    val processing: Boolean,
) {
    /** Resolves back to the verbatim URL; the saved index is the only thing that crosses recreation. */
    fun selectedCandidate(candidates: List<UrlCandidate>): String? =
        ShareCandidatePresenter.submissionValueAt(candidates, selectedIndex)

    fun shouldResumeSubmission(candidates: List<UrlCandidate>): Boolean =
        processing && selectedCandidate(candidates) != null
}

class ShareActivity : ComponentActivity() {
    private companion object {
        const val STATE_PROCESSED = "share.processed"
        const val STATE_SELECTED_INDEX = "share.selected_index"
        const val STATE_STATUS = "share.status"
        const val STATE_PROCESSING = "share.processing"
    }

    private var candidates by mutableStateOf(emptyList<UrlCandidate>())
    private var status by mutableStateOf<String?>(null)
    private var selected by mutableStateOf<String?>(null)
    private var processing by mutableStateOf(false)
    private var processedCandidate: String? = null
    private var submissionGeneration = 0
    private var submissionJob: Job? = null
    private lateinit var runtime: MobileRuntime

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        runtime = MobileRuntime.get(this)
        if (savedInstanceState == null) {
            inspectIntent(intent)
        } else {
            val restored = ShareActivityRestoredState(
                processed = savedInstanceState.getBoolean(STATE_PROCESSED),
                selectedIndex = savedInstanceState.getInt(STATE_SELECTED_INDEX, -1),
                status = savedInstanceState.getString(STATE_STATUS),
                processing = savedInstanceState.getBoolean(STATE_PROCESSING),
            )
            inspectIntent(intent, autoSubmit = false)
            restoreState(restored)
        }
        setContent {
            WebTagShareTheme {
                ShareScreen(
                    model = ShareCandidatePresenter.screenModel(candidates, selected, status, processing),
                    onSelectRow = ::selectRow,
                    onClose = ::finish,
                )
            }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        submissionJob?.cancel()
        submissionJob = null
        submissionGeneration += 1
        processing = false
        processedCandidate = null
        status = null
        selected = null
        inspectIntent(intent, autoSubmit = true)
    }

    override fun onSaveInstanceState(outState: Bundle) {
        outState.putBoolean(STATE_PROCESSED, processedCandidate != null)
        outState.putInt(STATE_SELECTED_INDEX, ShareCandidatePresenter.selectedIndex(candidates, selected))
        status?.let { outState.putString(STATE_STATUS, it) }
        outState.putBoolean(STATE_PROCESSING, processing)
        super.onSaveInstanceState(outState)
    }

    private fun inspectIntent(intent: Intent, autoSubmit: Boolean = true) {
        if (intent.action != Intent.ACTION_SEND || intent.type != "text/plain") {
            candidates = emptyList()
            selected = null
            processedCandidate = null
            processing = false
            status = getString(R.string.share_no_supported_content)
            return
        }
        // Nothing but accessors: the traversal, the scheme filter and the ordering all live in
        // NativeShareSources so they can be pinned without an Android runtime.
        val clipData = intent.clipData
        candidates = UrlCandidateExtractor.extract(
            NativeShareSources.payload(
                intentDataUrl = intent.data?.toString(),
                clipItemCount = clipData?.itemCount ?: 0,
                clipUriAt = { index -> clipData?.getItemAt(index)?.uri?.toString() },
                extraText = intent.getCharSequenceExtra(Intent.EXTRA_TEXT)?.toString(),
                clipTextAt = { index -> clipData?.getItemAt(index)?.text?.toString() },
            ),
        )
        if (candidates.isEmpty()) {
            status = getString(R.string.share_no_supported_content)
            selected = null
            processedCandidate = null
            processing = false
            return
        }
        if (!autoSubmit) {
            status = null
            selected = null
            processedCandidate = null
            processing = false
            return
        }
        ShareCandidatePresenter.autoSubmitValue(candidates)?.let(::submit)
    }

    /** A tap only carries a position; the URL behind it is resolved here, never rebuilt from a label. */
    private fun selectRow(index: Int) {
        ShareCandidatePresenter.submissionValueAt(candidates, index)?.let(::submit)
    }

    private fun restoreState(restored: ShareActivityRestoredState) {
        val restoredCandidate = restored.selectedCandidate(candidates)
        selected = restoredCandidate
        status = restored.status ?: status
        processedCandidate = null
        processing = false
        if (restoredCandidate == null) return

        if (restored.shouldResumeSubmission(candidates)) {
            resumeRestoredSubmission(restoredCandidate)
        } else if (restored.processed) {
            processedCandidate = restoredCandidate
        }
    }

    private fun resumeRestoredSubmission(url: String) {
        processing = true
        lifecycleScope.launch {
            val restored = withContext(Dispatchers.IO) {
                val config = runtime.activeConfiguration()
                val identity = config?.sessionIdentity()
                if (identity == null || !identity.canWrite() ||
                    runCatching { runtime.repository.activeSessionSnapshot() }.getOrNull()?.let { snapshot ->
                        snapshot.identity != identity || snapshot.activationRevision != config.activationRevision
                    } != false
                ) {
                    RestoredSubmission()
                } else {
                    val queueIdentity = com.alpenl.webtag.share.contract.QueueIdentity(
                        identity.origin,
                        identity.clientDataNamespace,
                    )
                    val existing = runCatching { runtime.repository.findByUrl(url, queueIdentity) }.getOrNull()
                    val existingState = existing?.let { runCatching { QueueState.fromWire(it.state) }.getOrNull() }
                    if (existingState != null && existingState !in setOf(
                            QueueState.PENDING_SUBMIT,
                            QueueState.RETRY_WAIT,
                        )
                    ) {
                        RestoredSubmission(terminalState = existingState)
                    } else if (existing != null) {
                        RestoredSubmission()
                    } else {
                        RestoredSubmission(
                            recent = runCatching { runtime.repository.readRecent(queueIdentity) }.getOrNull(),
                        )
                    }
                }
            }
            if (restored.terminalState != null) {
                processedCandidate = url
                selected = url
                processing = false
                status = queueStateLabel(restored.terminalState)
            } else if (restored.recent?.url == url && !restored.recent.isIdentityMismatch) {
                processedCandidate = url
                selected = url
                processing = false
                status = recentResultLabel(restored.recent.status)
                delay(300)
                finish()
            } else {
                submit(url)
            }
        }
    }

    private fun submit(url: String) {
        if (processing || processedCandidate == url) return
        val generation = ++submissionGeneration
        selected = url
        processing = true
        status = getString(R.string.share_received)
        submissionJob = lifecycleScope.launch {
            val outcome = withContext(Dispatchers.IO) {
                runCatching {
                    val config = runtime.activeConfiguration()
                    val identity = config?.sessionIdentity()
                    runtime.coordinator.submit(url, identity)
                }.getOrElse {
                    SubmissionOutcome.Blocked(
                        QueueState.FAILED_PERMANENT,
                        QueueError(ErrorKind.LOCAL_DATA_UNREADABLE, null, null, null),
                        durable = false,
                    )
                }
            }
            if (!isActive || generation != submissionGeneration) return@launch
            status = outcomeLabel(outcome)
            if (shouldMarkCandidateProcessed(outcome)) processedCandidate = url
            processing = false
            if (outcome is SubmissionOutcome.Submitted || outcome is SubmissionOutcome.Queued) {
                delay(300)
                finish()
            }
        }
    }

    private fun outcomeLabel(outcome: SubmissionOutcome): String = when (outcome) {
        is SubmissionOutcome.Submitted -> when (outcome.response.status) {
            "pending", "processing" -> getString(R.string.status_saved)
            "done" -> getString(R.string.status_existing)
            "failed" -> getString(R.string.status_failed)
            else -> getString(R.string.status_permanent)
        }
        is SubmissionOutcome.Queued -> getString(R.string.status_queued)
        is SubmissionOutcome.Blocked -> when (outcome.state) {
            QueueState.BLOCKED_AUTH -> getString(R.string.status_auth)
            QueueState.BLOCKED_SCOPE -> getString(R.string.status_scope)
            QueueState.BLOCKED_QUOTA -> getString(R.string.status_quota)
            QueueState.BLOCKED_IDENTITY -> getString(R.string.status_identity)
            QueueState.EXPIRED -> getString(R.string.status_expired)
            else -> getString(R.string.status_permanent)
        }
        SubmissionOutcome.ConfigurationRequired -> getString(R.string.configuration_required)
        SubmissionOutcome.IdentityChanged -> getString(R.string.status_identity)
        SubmissionOutcome.StaleClaim -> getString(R.string.status_queued)
        SubmissionOutcome.NoCandidate -> getString(R.string.status_no_candidate)
    }

    private fun recentResultLabel(status: String): String = when (status) {
        "pending", "processing" -> getString(R.string.status_saved)
        "done" -> getString(R.string.status_existing)
        "failed" -> getString(R.string.status_failed)
        else -> getString(R.string.status_permanent)
    }

    private fun queueStateLabel(state: QueueState): String = when (state) {
        QueueState.BLOCKED_AUTH -> getString(R.string.status_auth)
        QueueState.BLOCKED_SCOPE -> getString(R.string.status_scope)
        QueueState.BLOCKED_QUOTA -> getString(R.string.status_quota)
        QueueState.BLOCKED_IDENTITY -> getString(R.string.status_identity)
        QueueState.EXPIRED -> getString(R.string.status_expired)
        else -> getString(R.string.status_permanent)
    }

    private data class RestoredSubmission(
        val recent: com.alpenl.webtag.share.contract.RecentResult? = null,
        val terminalState: QueueState? = null,
    )
}

internal fun shouldMarkCandidateProcessed(outcome: SubmissionOutcome): Boolean = when (outcome) {
    is SubmissionOutcome.Submitted, is SubmissionOutcome.Queued -> true
    is SubmissionOutcome.Blocked -> outcome.durable
    SubmissionOutcome.ConfigurationRequired,
    SubmissionOutcome.IdentityChanged,
    SubmissionOutcome.StaleClaim,
    SubmissionOutcome.NoCandidate,
    -> false
}
