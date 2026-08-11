package com.alpenl.webtag.share.settings

import java.text.DateFormat
import java.util.Date

/**
 * Absolute wall-clock times for the settings surface, in the platform's own locale and time zone.
 *
 * Absolute rather than relative on purpose: "下次重试：14:20" tells the reader whether waiting is
 * worth it, while "in about 3 hours" drifts the moment the screen stops recomposing and is wrong
 * again as soon as the host is backgrounded.
 */
internal object SettingsTimeFormatter {
    /**
     * Returns null when there is no such instant, which is how a missing time stays off the screen.
     *
     * A queue row that has never failed has no first-failure time, and rendering a placeholder for
     * it ("--", "未知") would read as a fact about the row rather than as an absence.
     */
    fun absolute(epochMillis: Long?): String? = epochMillis?.let {
        DateFormat.getDateTimeInstance(DateFormat.SHORT, DateFormat.SHORT).format(Date(it))
    }
}
