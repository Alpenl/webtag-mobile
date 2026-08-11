package com.alpenl.webtag.share

import com.alpenl.webtag.share.contract.ErrorKind
import com.alpenl.webtag.share.contract.QueueError
import com.alpenl.webtag.share.contract.QueueState
import com.alpenl.webtag.share.contract.SubmissionOutcome
import com.alpenl.webtag.share.contract.UrlCandidate
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class ShareActivityStateTest {
    private val candidates = listOf(
        UrlCandidate("https://one.example/article", "one.example/article"),
        UrlCandidate("https://two.example/article", "two.example/article"),
    )

    @Test
    fun restorationUsesCandidateIndexWithoutPersistingTheUrl() {
        val restored = ShareActivityRestoredState(
            processed = true,
            selectedIndex = 1,
            status = "已加入队列",
            processing = false,
        )

        assertEquals("https://two.example/article", restored.selectedCandidate(candidates))
        assertEquals("已加入队列", restored.status)
        assertFalse(restored.shouldResumeSubmission(candidates))
    }

    @Test
    fun processingRestorationRequestsSubmissionForTheSavedCandidate() {
        val restored = ShareActivityRestoredState(
            processed = true,
            selectedIndex = 0,
            status = "正在收藏",
            processing = true,
        )

        assertTrue(restored.shouldResumeSubmission(candidates.take(1)))
    }

    @Test
    fun recreationKeepsTheDurableRowBoundToTheSameUrlWhenLabelsCollide() {
        // Both rows render as "example.com/a"; the queue row is keyed by the full URL, so a restore
        // that resolved by label would resume the wrong submission.
        val colliding = listOf(
            UrlCandidate("https://example.com/a?v=1", "example.com/a"),
            UrlCandidate("https://example.com/a?v=2", "example.com/a"),
        )
        val selected = colliding[1].submissionValue
        val savedIndex = ShareCandidatePresenter.selectedIndex(colliding, selected)

        val restored = ShareActivityRestoredState(
            processed = true,
            selectedIndex = savedIndex,
            status = "已加入队列",
            processing = true,
        )

        assertEquals("https://example.com/a?v=2", restored.selectedCandidate(colliding))
        assertTrue(restored.shouldResumeSubmission(colliding))
    }

    @Test
    fun aSelectionThatNoLongerExistsDoesNotResumeAnySubmission() {
        val restored = ShareActivityRestoredState(
            processed = true,
            selectedIndex = 5,
            status = null,
            processing = true,
        )

        assertNull(restored.selectedCandidate(candidates))
        assertFalse(restored.shouldResumeSubmission(candidates))
    }

    @Test
    fun candidateIsMarkedProcessedOnlyAfterAConfirmedDurableOutcome() {
        val error = QueueError(ErrorKind.LOCAL_DATA_UNREADABLE, null, null, null)

        assertTrue(shouldMarkCandidateProcessed(SubmissionOutcome.Queued(QueueState.PENDING_SUBMIT, error)))
        assertTrue(shouldMarkCandidateProcessed(SubmissionOutcome.Blocked(QueueState.FAILED_PERMANENT, error)))
        assertFalse(
            shouldMarkCandidateProcessed(
                SubmissionOutcome.Blocked(QueueState.FAILED_PERMANENT, error, durable = false),
            ),
        )
        assertFalse(shouldMarkCandidateProcessed(SubmissionOutcome.ConfigurationRequired))
        assertFalse(shouldMarkCandidateProcessed(SubmissionOutcome.IdentityChanged))
        assertFalse(shouldMarkCandidateProcessed(SubmissionOutcome.StaleClaim))
    }
}
