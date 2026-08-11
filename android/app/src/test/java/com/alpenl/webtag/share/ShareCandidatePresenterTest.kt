package com.alpenl.webtag.share

import com.alpenl.webtag.share.contract.UrlCandidate
import com.alpenl.webtag.share.contract.UrlCandidateExtractor
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class ShareCandidatePresenterTest {
    private val ambiguous = UrlCandidateExtractor.extract(
        sharePayload(extraText = "https://example.com/a?v=1 https://example.com/a?v=2"),
    )

    @Test
    fun chooserAppearsOnlyWhileSeveralCandidatesAreStillUncommitted() {
        assertFalse(ShareCandidatePresenter.requiresSelection(emptyList(), null))
        assertFalse(ShareCandidatePresenter.requiresSelection(ambiguous.take(1), null))
        assertTrue(ShareCandidatePresenter.requiresSelection(ambiguous, null))
        assertFalse(ShareCandidatePresenter.requiresSelection(ambiguous, "https://example.com/a?v=2"))
    }

    @Test
    fun theSingleCandidateIsAutoSubmittedAsTheVerbatimUrl() {
        // The ordinary "share one link" path. Submitting the label here would POST a string that is
        // not a URL for every single-link share, so the exact bytes are the assertion.
        val single = UrlCandidateExtractor.extract(
            sharePayload(intentDataUrl = "HTTPS://Docs.Example.com:8443/Guide%20One?token=abc#top"),
        )

        assertEquals("docs.example.com:8443/Guide%20One", single.single().displayLabel)
        assertEquals(
            "HTTPS://Docs.Example.com:8443/Guide%20One?token=abc#top",
            ShareCandidatePresenter.autoSubmitValue(single),
        )
    }

    @Test
    fun nothingIsAutoSubmittedWhenThereIsStillAChoiceToMake() {
        assertNull(ShareCandidatePresenter.autoSubmitValue(emptyList()))
        assertNull(ShareCandidatePresenter.autoSubmitValue(ambiguous))
    }

    @Test
    fun rowsRenderLabelsWhileClicksCarryTheVerbatimUrl() {
        val candidates = UrlCandidateExtractor.extract(
            sharePayload(
                intentDataUrl = "HTTPS://Docs.Example.com:8443/Guide%20One?token=abc#top",
                extraText = "https://news.example/story",
            ),
        )
        val model = ShareCandidatePresenter.screenModel(candidates, null, null, processing = false)

        assertEquals(listOf("docs.example.com:8443/Guide%20One", "news.example/story"), model.rowLabels)
        assertEquals(
            listOf("HTTPS://Docs.Example.com:8443/Guide%20One?token=abc#top", "https://news.example/story"),
            candidates.map { it.submissionValue },
        )
        // A tap reports a row position, and that position resolves back to the untouched URL.
        assertEquals(
            candidates.map { it.submissionValue },
            model.rowLabels.indices.map { ShareCandidatePresenter.submissionValueAt(candidates, it) },
        )
    }

    @Test
    fun theChooserPutsNoSchemeQueryOrFragmentOnScreen() {
        val candidates = UrlCandidateExtractor.extract(
            sharePayload(
                extraText = "https://example.com/search?q=secret&access_token=abc123#section " +
                    "http://other.example:8080/p?session=zzz#tail",
            ),
        )

        val model = ShareCandidatePresenter.screenModel(candidates, null, null, processing = false)

        assertEquals(listOf("example.com/search", "other.example:8080/p"), model.rowLabels)
        for (label in model.rowLabels) {
            assertFalse(label, label.contains("://"))
            assertFalse(label, label.contains("?"))
            assertFalse(label, label.contains("#"))
            assertFalse(label, label.contains("secret"))
            assertFalse(label, label.contains("session"))
        }
    }

    @Test
    fun theCommittedScreenShowsTheStatusAndTheSelectionsLabelNeverTheSelection() {
        val selected = ambiguous[1].submissionValue

        val model = ShareCandidatePresenter.screenModel(ambiguous, selected, "已加入队列", processing = false)

        assertEquals("https://example.com/a?v=2", selected)
        assertEquals(emptyList<String>(), model.rowLabels)
        assertEquals("已加入队列", model.statusText)
        // The selected row renders the same lossy label as the chooser did: the query the user
        // selected must not reappear on screen just because the choice is now made.
        assertEquals("example.com/a", model.selectedLabel)
    }

    @Test
    fun theScreenHasNoLabelBeforeAnythingIsSelectedAndNoStatusWhileChoosing() {
        val choosing = ShareCandidatePresenter.screenModel(ambiguous, null, "忽略我", processing = false)
        assertEquals("", choosing.statusText)
        assertNull(choosing.selectedLabel)

        val empty = ShareCandidatePresenter.screenModel(emptyList(), null, null, processing = false)
        assertEquals(emptyList<String>(), empty.rowLabels)
        assertEquals("", empty.statusText)
        assertNull(empty.selectedLabel)

        val gone = ShareCandidatePresenter.screenModel(ambiguous, "https://gone.example/x", "已加入队列", false)
        assertNull(gone.selectedLabel)
    }

    @Test
    fun closingIsBlockedExactlyWhileASubmissionIsInFlight() {
        assertFalse(ShareCandidatePresenter.screenModel(ambiguous, null, null, processing = true).closeEnabled)
        assertTrue(ShareCandidatePresenter.screenModel(ambiguous, null, null, processing = false).closeEnabled)
    }

    @Test
    fun labelLookupResolvesBySubmissionValueNotByPosition() {
        val candidates = listOf(
            UrlCandidate("https://one.example/a", "one.example/a"),
            UrlCandidate("https://two.example/b", "two.example/b"),
        )

        assertEquals("two.example/b", ShareCandidatePresenter.displayLabel(candidates, "https://two.example/b"))
        assertNull(ShareCandidatePresenter.displayLabel(candidates, "https://three.example/c"))
        assertNull(ShareCandidatePresenter.displayLabel(candidates, null))
    }

    @Test
    fun indexRoundTripKeepsTheExactUrlEvenWhenTwoCandidatesShareOneLabel() {
        // Both entries render as "example.com/a"; only the index-to-value mapping can tell them apart.
        val second = ambiguous[1].submissionValue

        val index = ShareCandidatePresenter.selectedIndex(ambiguous, second)

        assertEquals(1, index)
        assertEquals("https://example.com/a?v=2", second)
        assertEquals(second, ShareCandidatePresenter.submissionValueAt(ambiguous, index))
    }

    @Test
    fun unknownSelectionsCollapseToTheAbsentIndex() {
        assertEquals(-1, ShareCandidatePresenter.selectedIndex(ambiguous, null))
        assertEquals(-1, ShareCandidatePresenter.selectedIndex(ambiguous, "https://gone.example/x"))
        assertNull(ShareCandidatePresenter.submissionValueAt(ambiguous, -1))
        assertNull(ShareCandidatePresenter.submissionValueAt(ambiguous, ambiguous.size))
    }

    @Test
    fun longLabelsReachTheUiIntactSoTheLineBudgetIsTheOnlyTruncation() {
        val candidates = UrlCandidateExtractor.extract(
            sharePayload(extraText = "https://example.com/" + "segment/".repeat(30) + "end"),
        )
        val expected = "example.com/" + "segment/".repeat(30) + "end"

        assertEquals(expected, candidates.single().displayLabel)
        // Nothing shortens the label on the way to the screen; the screen is told to clamp it to a
        // line budget instead, which ShareScreenBindingTest pins to the label call sites.
        val model = ShareCandidatePresenter.screenModel(candidates, candidates.single().submissionValue, "已收藏", false)
        assertEquals(expected, model.selectedLabel)
        assertEquals(ShareCandidatePresenter.LABEL_MAX_LINES, model.labelMaxLines)
    }

    @Test
    fun labelsAreLimitedToTwoLines() {
        assertEquals(2, ShareCandidatePresenter.LABEL_MAX_LINES)
    }
}
