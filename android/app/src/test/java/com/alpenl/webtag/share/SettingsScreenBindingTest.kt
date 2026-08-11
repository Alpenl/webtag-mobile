package com.alpenl.webtag.share

import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The settings Composable is the one part of this feature a JVM test cannot run, and instrumented
 * tests are deliberately kept out of the gate. Everything that could be moved out of it has been —
 * grouping, redaction, the load fence, the foreground sequence and the cooldown wait are all plain
 * functions with their own tests — so what is left is a handful of bindings a compiler cannot check
 * for us, and this test reads the source to pin them.
 *
 * These are structural assertions on purpose, and narrow on purpose: they say nothing about how the
 * screen looks, only that it is wired to the tested logic rather than to a second copy of it.
 */
class SettingsScreenBindingTest {
    private val source: String = settingsScreenSource()

    @Test
    fun theQueueIsRenderedAsSectionsRatherThanOneFlatList() {
        assertTrue(
            "the queue must be laid out from the grouped projection",
            source.contains("projection.queue.groups.forEach"),
        )
        // The flat list is the thing being replaced. Eight interleaved states under one heading is
        // what made "which of these can I act on" unanswerable.
        assertFalse(
            "a flat queue list has come back",
            Regex("""items\(\s*queue\b""").containsMatchIn(source),
        )
        assertTrue(
            "each section needs its own heading and count",
            source.contains("QueueGroupHeader(group)"),
        )
    }

    @Test
    fun theTotalHeaderCountsDurableRowsNotRenderedSections() {
        assertTrue(
            source.contains("stringResource(R.string.queue_title, projection.queue.total)"),
        )
    }

    @Test
    fun becomingVisibleReadsOnceAndThenReadsAgainAfterTheDrain() {
        val effect = source.substringAfter("repeatOnLifecycle(Lifecycle.State.STARTED)")
            .substringBefore("\n        }\n    }")

        // Both reads come from `runForegroundConvergence`, which is where their order is tested. A
        // screen that inlined its own reload/drain pair would drift away from that test.
        assertTrue("the arrival read is not wired", effect.contains("runForegroundConvergence("))
        assertTrue(effect.contains("reload = { reloadLocal() }"))
        assertTrue(effect.contains("reconcile = { runtime.reconcileForeground() }"))
        // A cooldown deadline crossed while the process was frozen is only noticed by recomputing.
        assertTrue("the cooldown is not recomputed on arrival", effect.contains("resumeTick += 1"))
    }

    @Test
    fun everyLoadGoesThroughTheFencedLoaderAndCommitsOnlyTheProjection() {
        val reload = source.substringAfter("suspend fun reloadLocal() {").substringBefore("\n    }")

        assertEquals(
            listOf("loader.load { snapshot -> projection = snapshot.toProjection() }"),
            reload.lines().map { it.trim() }.filter { it.isNotEmpty() },
        )
        // Assigning `origin` or `apiKey` here is the regression that discards a half-typed
        // credential every time the host comes back to the foreground.
        assertFalse(reload.contains("origin ="))
        assertFalse(reload.contains("apiKey ="))
    }

    @Test
    fun theRecentCardIsDrivenByTheInjectedClockRatherThanTheSystemOne() {
        assertTrue(source.contains("clock = runtime.clock"))
        assertTrue(source.contains("resumeTick = resumeTick"))
        assertTrue(source.contains("awaitCooldownDeadline("))
        // A direct `System.currentTimeMillis()` in the card is what made the deadline behaviour
        // untestable and left the button locked past its own deadline.
        assertFalse(
            "the recent card reads the wall clock directly",
            recentCardSource().contains("System.currentTimeMillis()"),
        )
    }

    @Test
    fun theRecentCardOnlyEverReadsTheRedactedProjection() {
        val card = recentCardSource()
        val reads = Regex("""\brecent\.(\w+)""").findAll(card).map { it.groupValues[1] }.toSet()

        // `recent` reaches the card so its identity can key the cooldown wait; every rendered value
        // has to come off `view`, because that is the copy an identity mismatch has emptied.
        assertEquals(setOf("refreshBlockReason", "refreshNotBefore"), reads)
    }

    private fun recentCardSource(): String =
        source.substringAfter("private fun RecentResultCard(").substringBefore("\nprivate fun ")

    private companion object {
        private const val RELATIVE_PATH = "src/main/java/com/alpenl/webtag/share/MainActivity.kt"

        /** Unit tests run with the module directory as their working directory. */
        fun settingsScreenSource(): String {
            val file = File(RELATIVE_PATH)
            check(file.isFile) { "$RELATIVE_PATH not found from ${File("").absolutePath}" }
            return file.readText()
        }
    }
}
