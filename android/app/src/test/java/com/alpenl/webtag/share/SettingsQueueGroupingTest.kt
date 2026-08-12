package com.alpenl.webtag.share

import com.alpenl.webtag.share.contract.ErrorKind
import com.alpenl.webtag.share.contract.QueueIdentity
import com.alpenl.webtag.share.contract.QueueState
import com.alpenl.webtag.share.contract.QueueView
import com.alpenl.webtag.share.settings.QueueGroup
import com.alpenl.webtag.share.settings.SettingsQueuePresenter
import com.alpenl.webtag.share.settings.SettingsTimeFormatter
import java.util.Locale
import java.util.TimeZone
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

/**
 * Runs the shared `queue-states.json` table through the real grouping.
 *
 * The fixture is the contract both platforms answer to, so the assertions here are deliberately
 * whole-projection rather than spot checks: section order, per-section counts, the total, the fact
 * that an empty section is absent rather than rendered with a zero, and repository order inside
 * each section all come out of one comparison.
 */
class SettingsQueueGroupingTest {
    private val previousLocale: Locale = Locale.getDefault()
    private val previousZone: TimeZone = TimeZone.getDefault()

    @Before
    fun pinPlatformFormatting() {
        // Rows render their times in the device's locale and zone, so both are pinned to make the
        // time assertions deterministic. Nothing below compares against a literal rendering: the
        // short pattern is CLDR data and it moves between JDK builds.
        Locale.setDefault(Locale.SIMPLIFIED_CHINESE)
        TimeZone.setDefault(TimeZone.getTimeZone("Asia/Shanghai"))
    }

    @After
    fun restorePlatformFormatting() {
        Locale.setDefault(previousLocale)
        TimeZone.setDefault(previousZone)
    }

    @Test
    fun sharedFixtureCasesGroupIntoTheFrozenSectionsInOrder() {
        val root = fixture()
        val cases = root.getJSONArray("cases")
        assertTrue(cases.length() >= 5)
        for (index in 0 until cases.length()) {
            val case = cases.getJSONObject(index)
            val id = case.getString("id")
            val rows = readRows(case.getJSONArray("rows"))

            val projection = SettingsQueuePresenter.project(rows)

            assertEquals(id, case.getInt("expected_total"), projection.total)
            val expectedGroups = case.getJSONArray("expected_groups")
            assertEquals(id, expectedGroups.length(), projection.groups.size)
            for (groupIndex in 0 until expectedGroups.length()) {
                val expected = expectedGroups.getJSONObject(groupIndex)
                val actual = projection.groups[groupIndex]
                // Section order is positional: comparing by index is what makes a reordered
                // `QueueGroup` enum fail here rather than quietly re-sort the screen.
                assertEquals(id, expected.getString("key"), actual.group.key)
                assertEquals(id, expected.getInt("count"), actual.count)
                val expectedRowIds = expected.getJSONArray("row_ids")
                    .let { ids -> (0 until ids.length()).map(ids::getString) }
                assertEquals(id, expectedRowIds, actual.rows.map { it.id })
            }
        }
    }

    @Test
    fun everyQueueStateIsCoveredByTheFixtureAndLandsInItsDeclaredSection() {
        val root = fixture()
        val declared = buildMap {
            val groups = root.getJSONArray("groups")
            for (index in 0 until groups.length()) {
                val group = groups.getJSONObject(index)
                val states = group.getJSONArray("states")
                for (stateIndex in 0 until states.length()) {
                    put(states.getString(stateIndex), group.getString("key"))
                }
            }
        }

        // Eight states, eight declarations: a ninth state added to the enum without a fixture entry
        // has to fail rather than silently inherit somebody else's section.
        assertEquals(QueueState.entries.map { it.wireValue }.toSet(), declared.keys)
        for (state in QueueState.entries) {
            assertEquals(
                state.wireValue,
                declared.getValue(state.wireValue),
                SettingsQueuePresenter.groupOf(state).key,
            )
        }
    }

    @Test
    fun anEmptySectionIsAbsentRatherThanRenderedAsZero() {
        val projection = SettingsQueuePresenter.project(
            listOf(row("only", QueueState.EXPIRED)),
        )

        assertEquals(listOf(QueueGroup.EXPIRED), projection.groups.map { it.group })
        assertTrue(projection.groups.none { it.count == 0 })
        assertEquals(1, projection.total)
    }

    @Test
    fun theTotalCountsDurableRowsNotRenderedSections() {
        // Six sections, one row each: a total derived from `groups.size` would read 6 here too, so
        // the row counts are made uneven to separate the two.
        val rows = listOf(
            row("a", QueueState.PENDING_SUBMIT),
            row("b", QueueState.RETRY_WAIT),
            row("c", QueueState.BLOCKED_AUTH),
            row("d", QueueState.BLOCKED_SCOPE),
            row("e", QueueState.BLOCKED_IDENTITY),
            row("f", QueueState.BLOCKED_QUOTA),
            row("g", QueueState.FAILED_PERMANENT),
            row("h", QueueState.EXPIRED),
        )

        val projection = SettingsQueuePresenter.project(rows)

        assertEquals(8, projection.total)
        assertEquals(6, projection.groups.size)
        assertEquals(8, projection.groups.sumOf { it.count })
    }

    @Test
    fun anIdentityMismatchedRowKeepsItsRedactionAndItsBlockedSection() {
        val redacted = QueueView(
            id = "mismatched",
            url = "",
            state = QueueState.BLOCKED_IDENTITY,
            firstFailedAt = null,
            nextAttemptAt = null,
            errorKind = ErrorKind.IDENTITY_MISMATCH,
            identity = QueueIdentity("https://other.example", "other-namespace"),
        )

        val projection = SettingsQueuePresenter.project(listOf(redacted))

        // Grouping must not reconstruct anything the repository stripped; it only partitions.
        assertEquals(listOf(QueueGroup.BLOCKED_IDENTITY), projection.groups.map { it.group })
        assertEquals(listOf(redacted), projection.groups.single().rows)
        assertEquals("", projection.groups.single().rows.single().url)
    }

    @Test
    fun everyFixtureRowCarriesItsExactFailureAndRetryInstantsThroughTheGrouping() {
        val root = fixture()
        val cases = root.getJSONArray("cases")
        var nullTimes = 0
        var presentTimes = 0

        for (index in 0 until cases.length()) {
            val case = cases.getJSONObject(index)
            val id = case.getString("id")
            val declared = case.getJSONArray("rows")
            val rows = readRows(declared)
            val projected = SettingsQueuePresenter.project(rows)
                .groups
                .flatMap { it.rows }
                .associateBy { it.id }

            for (rowIndex in 0 until declared.length()) {
                val json = declared.getJSONObject(rowIndex)
                val rowId = json.getString("id")
                val row = projected.getValue(rowId)

                for ((field, actual) in listOf(
                    "first_failed_at" to row.firstFailedAt,
                    "next_attempt_at" to row.nextAttemptAt,
                )) {
                    val expected = json.optLongOrNull(field)
                    // Partitioning must hand the row's instants on untouched: a projection that
                    // rounded or dropped them would still group correctly and still be wrong.
                    assertEquals("$id/$rowId/$field", expected, actual)
                    if (expected == null) {
                        // No instant means no line at all. A placeholder like "--" or "未知" would
                        // read as a fact about the row rather than as an absence.
                        assertNull("$id/$rowId/$field", SettingsTimeFormatter.absolute(actual))
                        nullTimes += 1
                    } else {
                        assertNotNull("$id/$rowId/$field", SettingsTimeFormatter.absolute(actual))
                        presentTimes += 1
                    }
                }
            }
        }

        // Both branches have to be reachable in the shared table, or this asserts nothing.
        assertTrue("fixture has no absent times", nullTimes > 0)
        assertTrue("fixture has no present times", presentTimes > 0)
    }

    @Test
    fun rowTimesAnHourApartRenderAsDifferentInstants() {
        val instants = fixture().getJSONArray("cases").let { cases ->
            (0 until cases.length()).flatMap { index ->
                val rows = cases.getJSONObject(index).getJSONArray("rows")
                (0 until rows.length()).mapNotNull { rows.getJSONObject(it).optLongOrNull("first_failed_at") }
            }
        }.toSortedSet()

        val rendered = instants.map { SettingsTimeFormatter.absolute(it) }

        // The fixture's failure times are an hour apart, so a rendering that kept only the date
        // would collapse them onto each other. Distinctness is what proves the time of day —
        // the part that tells the reader whether waiting is worth it — reaches the view state.
        assertTrue("fixture needs several distinct instants", instants.size >= 5)
        assertEquals(rendered.size, rendered.toSet().size)
    }

    private fun readRows(rows: org.json.JSONArray): List<QueueView> =
        (0 until rows.length()).map { index ->
            val json = rows.getJSONObject(index)
            QueueView(
                id = json.getString("id"),
                url = json.getString("url"),
                state = QueueState.fromWire(json.getString("state")),
                firstFailedAt = json.optLongOrNull("first_failed_at"),
                nextAttemptAt = json.optLongOrNull("next_attempt_at"),
                errorKind = null,
                identity = if (json.getBoolean("identity_mismatch")) {
                    QueueIdentity("https://other.example", "other-namespace")
                } else {
                    null
                },
            )
        }

    private fun JSONObject.optLongOrNull(key: String): Long? =
        if (isNull(key)) null else getLong(key)

    private fun row(id: String, state: QueueState) = QueueView(
        id = id,
        url = "https://example.com/$id",
        state = state,
        firstFailedAt = null,
        nextAttemptAt = null,
        errorKind = null,
    )

    private companion object {
        fun fixture(): JSONObject =
            SettingsQueueGroupingTest::class.java.getResourceAsStream("/queue-states.json")!!
                .use { JSONObject(it.reader().readText()) }
    }
}
