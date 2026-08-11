package com.alpenl.webtag.share.contract

import java.util.Locale

/**
 * Renders the only part of a shared URL that is safe to put on screen.
 *
 * Shared links routinely carry credentials, tracking identifiers and referrer state in the query or
 * fragment, and a share sheet is shown over whatever app the user came from. Everything after the
 * path is therefore dropped instead of merely truncated, so nothing sensitive can be shoulder-surfed
 * or read out by a screen reader. The result is deliberately lossy and must never be parsed back
 * into a URL.
 */
object UrlDisplayLabel {
    private const val DEFAULT_HTTP_PORT = 80
    private const val DEFAULT_HTTPS_PORT = 443

    /**
     * Returns `host[:port]path` from the parts of an already-parsed URL. Total on purpose: candidate
     * validation has to parse the URL and prove it has a host anyway, so it can hand the parts over
     * and there is no failure left to branch on. A candidate can never exist without a label.
     *
     * The host is lower-cased because host comparison is case-insensitive and a mixed-case host is a
     * classic spoofing trick; the path keeps its original bytes because path comparison is
     * case-sensitive and percent-encoding must survive.
     */
    fun render(host: String, port: Int, scheme: String?, rawPath: String?): String = buildString {
        append(host.lowercase(Locale.ROOT))
        if (port != -1 && port != defaultPortFor(scheme)) {
            append(':').append(port)
        }
        append(if (rawPath.isNullOrEmpty()) "/" else rawPath)
    }

    private fun defaultPortFor(scheme: String?): Int =
        when (scheme?.lowercase(Locale.ROOT)) {
            "http" -> DEFAULT_HTTP_PORT
            "https" -> DEFAULT_HTTPS_PORT
            else -> -1
        }
}
