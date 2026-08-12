package com.alpenl.webtag.share.todo

import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId
import org.json.JSONObject

enum class TodoOriginKind(val wireValue: String) {
    STANDALONE("standalone"),
    THOUGHT("thought"),
    NOTE("note"),
    INBOX("inbox"),
    UNKNOWN("unknown"),
    ;

    companion object {
        fun fromWire(value: String): TodoOriginKind = entries.firstOrNull { it.wireValue == value } ?: UNKNOWN
    }
}

data class TodoItem(
    val id: String,
    val text: String,
    val dueAt: Long?,
    val done: Boolean,
    val originKind: TodoOriginKind,
    val originHostKind: String?,
    val originHostId: String?,
    val originRefJson: String?,
    val hostRevision: Long,
    val completedAt: Long?,
    val createdAt: Long,
    val updatedAt: Long,
    val expired: Boolean,
    val sourceHref: String? = null,
    val localOnly: Boolean = false,
    val pending: Boolean = false,
) {
    val isStandalone: Boolean get() = originKind == TodoOriginKind.STANDALONE
}

data class TodoCreate(
    val text: String,
    val dueAt: Long?,
)

data class TodoPatch(
    val text: String? = null,
    val dueAt: Long? = null,
    val dueAtSet: Boolean = false,
    val done: Boolean? = null,
    val expectedHostRevision: Long? = null,
)

data class TodoCapabilities(
    val todos: Boolean,
    val home: Boolean,
    val inbox: Boolean,
)

data class HomeSnapshot(
    val today: String,
    val summary: String,
    val counts: Map<String, Int>,
    val todos: List<TodoItem>,
    val freshness: String,
    val partial: Boolean,
    val stale: Boolean,
)

internal object TodoItemCodec {
    fun decode(json: JSONObject): TodoItem {
        val id = json.getString("id")
        require(runCatching { java.util.UUID.fromString(id) }.isSuccess) { "invalid TODO ID" }
        val text = json.getString("text")
        val originKind = TodoOriginKind.fromWire(json.getString("origin_kind"))
        require(originKind != TodoOriginKind.UNKNOWN) { "unknown TODO origin" }
        val createdAt = parseInstant(json.getString("created_at"))
        val updatedAt = parseInstant(json.getString("updated_at"))
        val hostRevision = json.getLong("host_revision")
        require(hostRevision >= 0) { "invalid TODO host revision" }
        if (originKind != TodoOriginKind.STANDALONE) require(hostRevision > 0) {
            "projected TODO is missing its host revision"
        }
        return TodoItem(
            id = id,
            text = text,
            dueAt = json.optionalInstant("due_at"),
            done = json.getBoolean("done"),
            originKind = originKind,
            originHostKind = json.optionalString("origin_host_kind"),
            originHostId = json.optionalString("origin_host_id"),
            originRefJson = json.opt("origin_ref")
                ?.takeUnless { it == JSONObject.NULL }
                ?.let { value -> if (value is String) JSONObject.quote(value) else value.toString() },
            hostRevision = hostRevision,
            completedAt = json.optionalInstant("completed_at"),
            createdAt = createdAt,
            updatedAt = updatedAt,
            expired = json.getBoolean("expired"),
            sourceHref = json.optionalString("source_href")?.also {
                require(it.startsWith("/") && !it.startsWith("//")) { "invalid TODO source href" }
            },
        )
    }

    fun encode(item: TodoItem): String = JSONObject()
        .put("id", item.id)
        .put("text", item.text)
        .put("due_at", item.dueAt?.let(::formatInstant) ?: JSONObject.NULL)
        .put("done", item.done)
        .put("origin_kind", item.originKind.wireValue)
        .put("origin_host_kind", item.originHostKind ?: JSONObject.NULL)
        .put("origin_host_id", item.originHostId ?: JSONObject.NULL)
        .put(
            "origin_ref",
            item.originRefJson?.let { raw -> runCatching { JSONObject(raw) }.getOrElse { raw } }
                ?: JSONObject.NULL,
        )
        .put("host_revision", item.hostRevision)
        .put("completed_at", item.completedAt?.let(::formatInstant) ?: JSONObject.NULL)
        .put("created_at", formatInstant(item.createdAt))
        .put("updated_at", formatInstant(item.updatedAt))
        .put("expired", item.expired)
        .put("source_href", item.sourceHref ?: JSONObject.NULL)
        .toString()

    fun decode(raw: String): TodoItem = decode(JSONObject(raw))

    fun formatInstant(epochMillis: Long): String = Instant.ofEpochMilli(epochMillis).toString()

    private fun parseInstant(value: String): Long = Instant.parse(value).toEpochMilli()

    private fun JSONObject.optionalInstant(name: String): Long? =
        if (!has(name) || isNull(name)) null else parseInstant(getString(name))

    private fun JSONObject.optionalString(name: String): String? =
        if (!has(name) || isNull(name)) null else getString(name)
}

enum class TodoFilter {
    ALL,
    STANDALONE,
    PROJECTED,
}

enum class TodoSection {
    OVERDUE,
    TODAY,
    UPCOMING,
    UNSCHEDULED,
    COMPLETED,
}

data class TodoSectionView(
    val section: TodoSection,
    val items: List<TodoItem>,
)

data class TodoDayCount(
    val date: LocalDate,
    val count: Int,
)

data class TodoProjection(
    val sections: List<TodoSectionView>,
    val days: List<TodoDayCount>,
    val openCount: Int,
    val overdueCount: Int,
    val todayCount: Int,
) {
    val isEmpty: Boolean get() = sections.all { it.items.isEmpty() }
}

object TodoPresenter {
    fun project(
        items: List<TodoItem>,
        nowMillis: Long,
        zoneId: ZoneId,
        filter: TodoFilter = TodoFilter.ALL,
        visibleDays: Int = 7,
    ): TodoProjection {
        require(visibleDays > 0)
        val today = Instant.ofEpochMilli(nowMillis).atZone(zoneId).toLocalDate()
        val filtered = items.filter { item ->
            when (filter) {
                TodoFilter.ALL -> true
                TodoFilter.STANDALONE -> item.isStandalone
                TodoFilter.PROJECTED -> !item.isStandalone
            }
        }
        val ordered = filtered.sortedWith(todoComparator())
        val buckets = linkedMapOf<TodoSection, MutableList<TodoItem>>()
        TodoSection.entries.forEach { buckets[it] = mutableListOf() }
        for (item in ordered) {
            buckets.getValue(sectionFor(item, today, zoneId)).add(item)
        }
        val open = filtered.filterNot(TodoItem::done)
        return TodoProjection(
            sections = TodoSection.entries.map { section -> TodoSectionView(section, buckets.getValue(section)) },
            days = (0 until visibleDays).map { offset ->
                val date = today.plusDays(offset.toLong())
                TodoDayCount(
                    date = date,
                    count = open.count { item -> item.dueAt?.localDate(zoneId) == date },
                )
            },
            openCount = open.size,
            overdueCount = buckets.getValue(TodoSection.OVERDUE).size,
            todayCount = buckets.getValue(TodoSection.TODAY).size,
        )
    }

    fun todayItems(
        items: List<TodoItem>,
        nowMillis: Long,
        zoneId: ZoneId,
        limit: Int = 5,
    ): List<TodoItem> {
        require(limit >= 0)
        val projection = project(items, nowMillis, zoneId)
        val urgent = projection.sections
            .filter { it.section in setOf(TodoSection.OVERDUE, TodoSection.TODAY) }
            .flatMap(TodoSectionView::items)
        if (urgent.size >= limit) return urgent.take(limit)
        val unscheduled = projection.sections.first { it.section == TodoSection.UNSCHEDULED }.items
        return (urgent + unscheduled).take(limit)
    }

    private fun sectionFor(item: TodoItem, today: LocalDate, zoneId: ZoneId): TodoSection {
        if (item.done) return TodoSection.COMPLETED
        val dueDate = item.dueAt?.localDate(zoneId) ?: return TodoSection.UNSCHEDULED
        return when {
            dueDate.isBefore(today) -> TodoSection.OVERDUE
            dueDate == today -> TodoSection.TODAY
            else -> TodoSection.UPCOMING
        }
    }

    private fun todoComparator(): Comparator<TodoItem> = Comparator { left, right ->
        if (left.done != right.done) return@Comparator if (left.done) 1 else -1
        if (left.done) {
            val completion = compareNullableDescending(left.completedAt, right.completedAt)
            if (completion != 0) return@Comparator completion
            return@Comparator right.updatedAt.compareTo(left.updatedAt)
        }
        val due = compareNullableAscending(left.dueAt, right.dueAt)
        if (due != 0) return@Comparator due
        val created = right.createdAt.compareTo(left.createdAt)
        if (created != 0) return@Comparator created
        left.id.compareTo(right.id)
    }

    private fun compareNullableAscending(left: Long?, right: Long?): Int = when {
        left == null && right == null -> 0
        left == null -> 1
        right == null -> -1
        else -> left.compareTo(right)
    }

    private fun compareNullableDescending(left: Long?, right: Long?): Int = when {
        left == null && right == null -> 0
        left == null -> 1
        right == null -> -1
        else -> right.compareTo(left)
    }

    private fun Long.localDate(zoneId: ZoneId): LocalDate =
        Instant.ofEpochMilli(this).atZone(zoneId).toLocalDate()
}

enum class TodoConflictResolution {
    CONVERGED,
    RELOAD_REQUIRED,
}

object TodoConflictPolicy {
    fun resolveDesiredDone(desiredDone: Boolean, refreshed: TodoItem?): TodoConflictResolution =
        if (refreshed?.done == desiredDone) TodoConflictResolution.CONVERGED
        else TodoConflictResolution.RELOAD_REQUIRED
}
