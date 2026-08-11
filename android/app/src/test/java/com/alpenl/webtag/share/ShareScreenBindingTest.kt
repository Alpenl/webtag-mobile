package com.alpenl.webtag.share

import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The Compose function in `ShareScreen.kt` is the one part of this feature a JVM test cannot run:
 * rendering it needs an Android runtime, and instrumented tests are deliberately kept out of the
 * gate. Everything that could be moved out of it has been — it receives a [ShareScreenModel] of
 * labels and reports a row position — so what is left is two bindings that a compiler cannot check
 * for us, and this test reads the source to pin them.
 *
 * These are structural assertions on purpose, and they are narrow on purpose: they say nothing about
 * how the screen looks, only that the line budget the model carries actually reaches both label call
 * sites, and that the screen has not regained a parameter that would let a URL back onto the screen.
 */
class ShareScreenBindingTest {
    private val source: String = shareScreenSource()

    @Test
    fun everyRenderedLabelIsClampedToTheModelsLineBudget() {
        val bindings = Regex("""maxLines\s*=\s*([^,\n]+)""")
            .findAll(source)
            .map { it.groupValues[1].trim() }
            .toList()

        // Both the chooser rows and the committed selection render a label, and both are clamped by
        // the model's budget rather than by a literal that could drift away from it.
        assertEquals(listOf("model.labelMaxLines", "model.labelMaxLines"), bindings)
    }

    @Test
    fun theScreenOnlyEverReceivesTheModelAndItsCallbacks() {
        val header = "internal fun ShareScreen("
        val start = source.indexOf(header)
        assertTrue("ShareScreen declaration not found", start >= 0)
        val end = source.indexOf("\n) {", start)
        assertTrue("ShareScreen parameter list is not closed on its own line", end > start)

        val parameters = source.substring(start + header.length, end)
            .lines()
            .map { it.trim().removeSuffix(",") }
            .filter { it.isNotEmpty() }

        // A `selected: String?` or `candidates: List<UrlCandidate>` parameter would hand the screen a
        // submission value again, and with it the query and fragment the label exists to hide.
        assertEquals(
            listOf(
                "model: ShareScreenModel",
                "onSelectRow: (Int) -> Unit",
                "onClose: () -> Unit",
            ),
            parameters,
        )
    }

    private companion object {
        private const val RELATIVE_PATH = "src/main/java/com/alpenl/webtag/share/ShareScreen.kt"

        /** Unit tests run with the module directory as their working directory. */
        fun shareScreenSource(): String {
            val file = File(RELATIVE_PATH)
            check(file.isFile) { "$RELATIVE_PATH not found from ${File("").absolutePath}" }
            return file.readText()
        }
    }
}
