package com.alpenl.webtag.share

import com.alpenl.webtag.share.contract.UrlCandidate

/**
 * Everything the share sheet renders, resolved before Compose sees it.
 *
 * The screen is given labels and a line budget and nothing else. It holds no submission value at
 * all, which is what makes "a query or fragment reaches the screen" unrepresentable rather than
 * merely tested for, and it identifies a chosen row by position because a label is lossy and can
 * belong to several candidates at once.
 */
internal data class ShareScreenModel(
    val rowLabels: List<String>,
    val statusText: String,
    val selectedLabel: String?,
    val closeEnabled: Boolean,
    val labelMaxLines: Int,
)

/**
 * Deterministic share-sheet logic, deliberately free of any Android or Compose dependency so the
 * ordering and the label/value split can be pinned by plain JVM tests.
 *
 * Every function here takes the submission value as the identity of a candidate. Display labels are
 * lossy (`host + path`), so two different candidates can share one label; resolving a selection by
 * label would submit the wrong URL.
 */
internal object ShareCandidatePresenter {
    /**
     * A label wraps at most twice: a share sheet is an overlay on someone else's screen, and letting
     * a long path push the action row off-screen is worse than eliding the tail.
     */
    const val LABEL_MAX_LINES = 2

    /** The chooser is only meaningful while more than one candidate exists and none is committed. */
    fun requiresSelection(candidates: List<UrlCandidate>, selected: String?): Boolean =
        candidates.size > 1 && selected == null

    /**
     * The one URL to submit without asking, or null whenever the user still has a choice to make.
     *
     * Auto-submit is the ordinary "share one link" path, so it is also the one that would quietly
     * POST garbage for every single share if it ever picked up the label instead of the URL.
     */
    fun autoSubmitValue(candidates: List<UrlCandidate>): String? =
        candidates.singleOrNull()?.submissionValue

    /** The label to render for a submission value, or null when it is not one of the candidates. */
    fun displayLabel(candidates: List<UrlCandidate>, submissionValue: String?): String? =
        candidates.firstOrNull { it.submissionValue == submissionValue }?.displayLabel

    /** Position of a submission value, used to survive Activity recreation without persisting URLs. */
    fun selectedIndex(candidates: List<UrlCandidate>, submissionValue: String?): Int =
        candidates.indexOfFirst { it.submissionValue == submissionValue }

    /**
     * Inverse of [selectedIndex]; returns the verbatim URL that must be submitted. This is also how a
     * tap on row *n* becomes a submission: the screen only knows positions.
     */
    fun submissionValueAt(candidates: List<UrlCandidate>, index: Int): String? =
        candidates.getOrNull(index)?.submissionValue

    /**
     * Resolves the whole screen in one place. A non-empty [ShareScreenModel.rowLabels] means the
     * chooser is up; otherwise the screen is a status line plus, once something is selected, the
     * label of that selection — never the selection itself.
     */
    fun screenModel(
        candidates: List<UrlCandidate>,
        selected: String?,
        status: String?,
        processing: Boolean,
    ): ShareScreenModel = if (requiresSelection(candidates, selected)) {
        ShareScreenModel(
            rowLabels = candidates.map { it.displayLabel },
            statusText = "",
            selectedLabel = null,
            closeEnabled = !processing,
            labelMaxLines = LABEL_MAX_LINES,
        )
    } else {
        ShareScreenModel(
            rowLabels = emptyList(),
            statusText = status.orEmpty(),
            selectedLabel = displayLabel(candidates, selected),
            closeEnabled = !processing,
            labelMaxLines = LABEL_MAX_LINES,
        )
    }
}
