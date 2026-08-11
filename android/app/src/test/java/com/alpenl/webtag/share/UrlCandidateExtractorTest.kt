package com.alpenl.webtag.share

import com.alpenl.webtag.share.contract.SharePayload
import com.alpenl.webtag.share.contract.UrlCandidateExtractor
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class UrlCandidateExtractorTest {
    @Test
    fun sharedFixturesProduceTheRecordedCandidatesAndOutcome() {
        val root = javaClass.getResourceAsStream("/share-payloads.json")!!.use {
            JSONObject(it.reader().readText())
        }
        val cases = root.getJSONArray("cases")
        assertTrue(cases.length() >= 200)
        for (index in 0 until cases.length()) {
            val fixture = cases.getJSONObject(index)
            val structured = fixture.getJSONArray("structured_urls")
            val structuredUrls = buildList {
                for (itemIndex in 0 until structured.length()) add(structured.getString(itemIndex))
            }
            val plainText = if (fixture.isNull("plain_text")) null else fixture.getString("plain_text")
            val payload = SharePayload(structuredUrls, listOfNotNull(plainText))
            val actual = UrlCandidateExtractor.extract(payload).map { it.submissionValue }
            val expectedJson = fixture.getJSONArray("expected_candidates")
            val expected = buildList {
                for (itemIndex in 0 until expectedJson.length()) add(expectedJson.getString(itemIndex))
            }
            assertEquals(fixture.getString("id"), expected, actual)
            val outcome = fixture.getString("expected_outcome")
            val actualOutcome = when {
                actual.isEmpty() -> "reject"
                actual.size == 1 -> "submit"
                else -> "choose"
            }
            assertEquals(fixture.getString("id"), outcome, actualOutcome)
            assertEquals(fixture.getString("id"), outcome == "choose", actual.size > 1)
        }
    }
}
