package com.alpenl.webtag.share

import com.alpenl.webtag.share.contract.OriginNormalizer
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Test

class OriginNormalizerTest {
    @Test
    fun normalizesOnlyAnHttpsOrigin() {
        assertEquals("https://example.org", OriginNormalizer.normalize(" HTTPS://Example.ORG/ "))
        assertEquals("https://example.org:8443", OriginNormalizer.normalize("https://example.org:8443"))
    }

    @Test
    fun rejectsOriginDataThatCouldLeakCredentials() {
        listOf(
            "http://example.org",
            "https://user:pass@example.org",
            "https://example.org/path",
            "https://example.org/?q=1",
            "https://example.org/#fragment",
        ).forEach { assertThrows(IllegalArgumentException::class.java) { OriginNormalizer.normalize(it) } }
    }
}
