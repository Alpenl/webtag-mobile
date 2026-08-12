package com.alpenl.webtag.share

import com.alpenl.webtag.share.todo.TodoConflictPolicy
import com.alpenl.webtag.share.todo.TodoConflictResolution
import com.alpenl.webtag.share.todo.TodoFilter
import com.alpenl.webtag.share.todo.TodoItem
import com.alpenl.webtag.share.todo.TodoOriginKind
import com.alpenl.webtag.share.todo.TodoPresenter
import com.alpenl.webtag.share.todo.TodoSection
import java.time.LocalDate
import java.time.ZoneId
import org.junit.Assert.assertEquals
import org.junit.Test

class TodoPresenterTest {
    private val zone = ZoneId.of("Asia/Shanghai")
    private val today = LocalDate.of(2026, 8, 13)
    private val now = today.atTime(10, 0).atZone(zone).toInstant().toEpochMilli()

    @Test
    fun groupsByLocalCalendarDayAndKeepsCompletedCollapsedAsOneSection() {
        val projection = TodoPresenter.project(
            listOf(
                todo("overdue", due = today.minusDays(1)),
                todo("today", due = today),
                todo("upcoming", due = today.plusDays(2)),
                todo("none"),
                todo("done", due = today, done = true),
            ),
            now,
            zone,
        )

        assertEquals(
            mapOf(
                TodoSection.OVERDUE to listOf("overdue"),
                TodoSection.TODAY to listOf("today"),
                TodoSection.UPCOMING to listOf("upcoming"),
                TodoSection.UNSCHEDULED to listOf("none"),
                TodoSection.COMPLETED to listOf("done"),
            ),
            projection.sections.associate { it.section to it.items.map(TodoItem::id) },
        )
        assertEquals(4, projection.openCount)
        assertEquals(1, projection.overdueCount)
        assertEquals(1, projection.todayCount)
    }

    @Test
    fun dateBandCountsOnlyOpenTodosAndFilterNeverMutatesTheItems() {
        val items = listOf(
            todo("mine", due = today),
            todo("projected", due = today.plusDays(1), origin = TodoOriginKind.NOTE),
            todo("complete", due = today, done = true),
        )

        val all = TodoPresenter.project(items, now, zone)
        val projected = TodoPresenter.project(items, now, zone, TodoFilter.PROJECTED)

        assertEquals(listOf(1, 1, 0, 0, 0, 0, 0), all.days.map { it.count })
        assertEquals(listOf("projected"), projected.sections.flatMap { it.items }.map { it.id })
        assertEquals(3, items.size)
    }

    @Test
    fun todaySummaryUsesOverdueThenTodayThenNewestUnscheduled() {
        val items = listOf(
            todo("old-none", createdAt = 1),
            todo("future", due = today.plusDays(1), createdAt = 9),
            todo("today", due = today, createdAt = 3),
            todo("overdue", due = today.minusDays(1), createdAt = 2),
            todo("new-none", createdAt = 5),
        )

        assertEquals(
            listOf("overdue", "today", "new-none", "old-none"),
            TodoPresenter.todayItems(items, now, zone).map(TodoItem::id),
        )
    }

    @Test
    fun projectedConflictConvergesOnlyWhenTheServerAlreadyHasTheDesiredState() {
        assertEquals(
            TodoConflictResolution.CONVERGED,
            TodoConflictPolicy.resolveDesiredDone(true, todo("p", done = true)),
        )
        assertEquals(
            TodoConflictResolution.RELOAD_REQUIRED,
            TodoConflictPolicy.resolveDesiredDone(true, todo("p", done = false)),
        )
        assertEquals(
            TodoConflictResolution.RELOAD_REQUIRED,
            TodoConflictPolicy.resolveDesiredDone(true, null),
        )
    }

    private fun todo(
        id: String,
        due: LocalDate? = null,
        done: Boolean = false,
        origin: TodoOriginKind = TodoOriginKind.STANDALONE,
        createdAt: Long = 1,
    ): TodoItem = TodoItem(
        id = id,
        text = id,
        dueAt = due?.atTime(12, 0)?.atZone(zone)?.toInstant()?.toEpochMilli(),
        done = done,
        originKind = origin,
        originHostKind = origin.takeUnless { it == TodoOriginKind.STANDALONE }?.wireValue,
        originHostId = null,
        originRefJson = null,
        hostRevision = if (origin == TodoOriginKind.STANDALONE) 0 else 3,
        completedAt = if (done) now else null,
        createdAt = createdAt,
        updatedAt = createdAt,
        expired = false,
    )
}
