package com.alpenl.webtag.share

import com.alpenl.webtag.share.contract.SharePayload

/**
 * Flattens one native Android share into the frozen source order without touching an Android type.
 *
 * The ClipData is handed over as an item count plus two accessors rather than as a `ClipData`, so
 * the traversal lives here instead of in the Activity. That traversal is the part that actually
 * regressed — reading only the first item, or letting `EXTRA_TEXT` suppress the item texts, is what
 * made shared links disappear — and keeping it free of Android types is what lets a plain JVM test
 * pin it. The Activity is left with nothing but the accessors themselves.
 */
internal object NativeShareSources {
    /**
     * @param clipItemCount `ClipData.getItemCount()`, or 0 when the Intent carries no ClipData.
     * @param clipUriAt `ClipData.getItemAt(index).getUri()`, rendered as a string.
     * @param clipTextAt `ClipData.getItemAt(index).getText()`. Deliberately the literal text and not
     *   `coerceToText`, which would resolve content URIs and pull in data the user never shared.
     */
    fun payload(
        intentDataUrl: String?,
        clipItemCount: Int,
        clipUriAt: (Int) -> String?,
        extraText: String?,
        clipTextAt: (Int) -> String?,
    ): SharePayload = SharePayload(
        // Structured stage: the Intent data first, then every item URI by index. Only explicit
        // HTTP(S) URIs qualify; any other scheme is dropped untouched so nothing is dereferenced.
        structuredUrls = buildList {
            intentDataUrl?.takeIf(::isHttpUrl)?.let(::add)
            for (index in 0 until clipItemCount) {
                clipUriAt(index)?.takeIf(::isHttpUrl)?.let(::add)
            }
        },
        // Text stage: EXTRA_TEXT is only the first text source, never a switch. An Android share
        // routinely puts the title in EXTRA_TEXT and the real links in the ClipData items, so a
        // present (or empty) EXTRA_TEXT must not stop the item texts from being scanned, and every
        // item is read rather than just the first non-empty one.
        texts = buildList {
            extraText?.let(::add)
            for (index in 0 until clipItemCount) {
                clipTextAt(index)?.takeIf(String::isNotBlank)?.let(::add)
            }
        },
    )

    private fun isHttpUrl(value: String): Boolean =
        value.startsWith("http://", ignoreCase = true) || value.startsWith("https://", ignoreCase = true)
}
