package com.alpenl.webtag.share

import com.alpenl.webtag.share.contract.UrlCandidateExtractor
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Test

/**
 * Covers the display label through the pipeline that actually produces it — a shared URL becomes a
 * candidate, and the candidate carries the label. Going through extraction rather than calling the
 * renderer directly is deliberate: it is the extraction path that decides which parts of the parsed
 * URL reach the renderer, and a label that is only correct when a test hands it the right parts
 * would prove nothing about what ends up on screen.
 */
class UrlDisplayLabelTest {
    @Test
    fun labelIsLowercasedHostWithNonDefaultPortAndTheRawPath() {
        val table = listOf(
            "https://example.com/article" to "example.com/article",
            // An absent path still renders as a root path so the label never ends on the host alone.
            "https://example.com" to "example.com/",
            "https://example.com/" to "example.com/",
            "HTTPS://Example.COM/Keep%2FCase" to "example.com/Keep%2FCase",
            "https://example.com/%E6%B5%8B%E8%AF%95" to "example.com/%E6%B5%8B%E8%AF%95",
            "https://example.com/a/b/c/d/e/f/g/h/i/j/k" to "example.com/a/b/c/d/e/f/g/h/i/j/k",
            // Default ports are noise; non-default ports are part of the identity of the target.
            "https://example.com:443/x" to "example.com/x",
            "http://example.com:80/x" to "example.com/x",
            "HTTPS://Example.com:443/x" to "example.com/x",
            "HTTP://Example.com:80/x" to "example.com/x",
            "https://example.com:8443/x" to "example.com:8443/x",
            "http://example.com:8080/x" to "example.com:8080/x",
            // 443 is only default for https, 80 only for http.
            "http://example.com:443/x" to "example.com:443/x",
            "https://example.com:80/x" to "example.com:80/x",
            "http://192.168.1.10:8080/status" to "192.168.1.10:8080/status",
            "https://[2001:DB8::1]/v6" to "[2001:db8::1]/v6",
            "https://[::1]:8443/v6" to "[::1]:8443/v6",
            "https://[::1]:443/v6" to "[::1]/v6",
        )

        for ((url, expected) in table) {
            assertEquals(url, expected, labelOf(url))
        }
    }

    @Test
    fun labelNeverLeaksTheSchemeQueryOrFragment() {
        assertEquals(
            "example.com/search",
            labelOf("https://example.com/search?q=secret&access_token=abc123#section"),
        )
        assertEquals("example.com/p", labelOf("https://example.com/p#frag?notquery"))

        for (url in listOf(
            "https://example.com/search?q=secret&access_token=abc123#section",
            "HTTP://Example.com:8080/Path%20One?session=zzz#tail",
            "https://[2001:db8::1]:9443/v6?k=v#f",
        )) {
            val label = labelOf(url)
            assertFalse(url, label.contains("://"))
            assertFalse(url, label.contains("?"))
            assertFalse(url, label.contains("#"))
            assertFalse(url, label.contains("secret"))
            assertFalse(url, label.contains("session"))
        }
    }

    @Test
    fun urlsWithoutAUsableHostNeverBecomeACandidateAtAll() {
        // There is no "candidate we could not label" state: an unlabelable URL is one that failed
        // validation, so it is dropped before a candidate exists rather than rendered as a blank.
        for (url in listOf("http:///missing-host", "not a url", "https://exa mple.com/a")) {
            assertEquals(
                url,
                emptyList<String>(),
                UrlCandidateExtractor.extract(sharePayload(intentDataUrl = url)).map { it.displayLabel },
            )
        }
    }

    /** The label the share sheet would draw for a URL shared as the Intent's data. */
    private fun labelOf(url: String): String =
        UrlCandidateExtractor.extract(sharePayload(intentDataUrl = url)).single().displayLabel
}
