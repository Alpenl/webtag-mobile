package com.alpenl.webtag.share

import java.io.File
import org.junit.Assert.assertTrue
import org.junit.Test

/** Pins the thin Android-to-platform-neutral binding that local JVM tests cannot execute. */
class ShareActivityBindingTest {
    private val source = File(SOURCE_PATH).readText().replace(Regex("\\s+"), " ")

    @Test
    fun everyExplicitIntentSourceIsBoundToItsMatchingPayloadInput() {
        assertBinding("intentDataUrl = intent.data?.toString()")
        assertBinding("clipItemCount = clipData?.itemCount ?: 0")
        assertBinding("clipUriAt = { index -> clipData?.getItemAt(index)?.uri?.toString() }")
        assertBinding("extraText = intent.getCharSequenceExtra(Intent.EXTRA_TEXT)?.toString()")
        assertBinding("clipTextAt = { index -> clipData?.getItemAt(index)?.text?.toString() }")
    }

    @Test
    fun aScreenRowIsResolvedByIndexToTheSubmissionValue() {
        assertBinding("onSelectRow = ::selectRow")
        assertBinding("ShareCandidatePresenter.submissionValueAt(candidates, index)?.let(::submit)")
    }

    private fun assertBinding(expected: String) {
        assertTrue("Missing ShareActivity binding: $expected", source.contains(expected))
    }

    private companion object {
        private const val SOURCE_PATH = "src/main/java/com/alpenl/webtag/share/ShareActivity.kt"
    }
}
