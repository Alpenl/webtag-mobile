package com.alpenl.webtag.share

import com.alpenl.webtag.share.contract.UrlCandidateExtractor
import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * Pins the flattening of native share sources, starting from the same shape an Intent has: an
 * optional data URL, an optional EXTRA_TEXT and a ClipData addressed by item index.
 *
 * The regressions these tests exist for both live in that traversal — a share whose EXTRA_TEXT held
 * only a title made every ClipData link disappear, and only the first ClipData item was ever read —
 * so reading a single item, or letting EXTRA_TEXT suppress the items, has to fail here.
 */
class NativeShareExtractionTest {
    @Test
    fun oneShareFlattensDataUrisExtraTextAndEveryClipTextInTheFrozenOrder() {
        val candidates = extract(
            intentDataUrl = "https://data.example/intent",
            extraText = "标题 https://extra.example/from-extra-text",
            clipItems = listOf(
                ClipItem(
                    uri = "https://clip.example/uri-one",
                    text = "first https://clip.example/text-one",
                ),
                ClipItem(
                    uri = "https://clip.example/uri-two",
                    text = "second https://clip.example/text-two 还有 https://clip.example/text-three",
                ),
            ),
        )

        assertEquals(
            listOf(
                "https://data.example/intent",
                "https://clip.example/uri-one",
                "https://clip.example/uri-two",
                "https://extra.example/from-extra-text",
                "https://clip.example/text-one",
                "https://clip.example/text-two",
                "https://clip.example/text-three",
            ),
            candidates,
        )
    }

    @Test
    fun everyClipItemIsReadNotJustTheFirstOne() {
        // Six items, one link each: anything that stops after the first item, or after the first
        // non-empty text, loses the rest of what the user shared.
        val items = (1..6).map { ClipItem(text = "第 $it 条 https://clip.example/item-$it") }

        assertEquals((1..6).map { "https://clip.example/item-$it" }, extract(clipItems = items))
        assertEquals(
            (1..6).map { "https://clip.example/uri-$it" },
            extract(clipItems = (1..6).map { ClipItem(uri = "https://clip.example/uri-$it") }),
        )
    }

    @Test
    fun clipTextsAreScannedWhetherExtraTextIsPresentEmptyOrMissing() {
        val clipItems = listOf(
            ClipItem(text = "一 https://clip.example/one"),
            ClipItem(text = "二 https://clip.example/two"),
        )
        val fromClip = listOf("https://clip.example/one", "https://clip.example/two")

        assertEquals(
            listOf("https://extra.example/x") + fromClip,
            extract(extraText = "see https://extra.example/x", clipItems = clipItems),
        )
        assertEquals(fromClip, extract(extraText = "", clipItems = clipItems))
        assertEquals(fromClip, extract(extraText = null, clipItems = clipItems))
        assertEquals(fromClip, extract(extraText = "只有标题没有链接", clipItems = clipItems))
    }

    @Test
    fun oneItemContributesItsUriAndItsTextInSeparateStages() {
        assertEquals(
            listOf("https://item.example/uri", "https://item.example/text"),
            extract(
                clipItems = listOf(
                    ClipItem(uri = "https://item.example/uri", text = "正文 https://item.example/text"),
                ),
            ),
        )
    }

    @Test
    fun blankItemsAndUnsupportedSourcesDoNotShiftTheOrder() {
        assertEquals(
            listOf("https://a.example/one", "https://b.example/two"),
            extract(
                extraText = "   ",
                clipItems = listOf(
                    ClipItem(uri = "https://a.example/one", text = ""),
                    ClipItem(),
                    ClipItem(text = "   "),
                    ClipItem(text = "ftp://x.example/f mailto:reader@x.example example.com/bare tel:+100000"),
                    ClipItem(text = "尾部 https://b.example/two"),
                ),
            ),
        )
    }

    @Test
    fun blankClipTextsDoNotEnterTheFlattenedPayload() {
        val payload = sharePayload(
            extraText = " ",
            clipItems = listOf(
                ClipItem(text = ""),
                ClipItem(text = "   "),
                ClipItem(text = "see https://example.com/kept"),
            ),
        )

        assertEquals(listOf(" ", "see https://example.com/kept"), payload.texts)
    }

    @Test
    fun onlyExplicitHttpUrisLeaveTheStructuredStage() {
        // A content:// URI never enters the pipeline at all, so nothing can later dereference it,
        // and the URIs that do enter keep their item order and their exact casing.
        val payload = sharePayload(
            intentDataUrl = "content://media/external/images/1",
            clipItems = listOf(
                ClipItem(uri = "content://com.other.app/note/1"),
                ClipItem(uri = "https://second.example/b"),
                ClipItem(uri = "app://private/item"),
                ClipItem(uri = "HTTPS://Fourth.example/D"),
            ),
        )

        assertEquals(
            listOf("https://second.example/b", "HTTPS://Fourth.example/D"),
            payload.structuredUrls,
        )
        assertEquals(emptyList<String>(), payload.texts)
    }

    @Test
    fun userinfoHostlessAndNonHttpSourcesAreRejectedEverywhere() {
        assertEquals(
            emptyList<String>(),
            extract(
                intentDataUrl = "http:///missing-host",
                extraText = "https://user@example.com/b",
                clipItems = listOf(
                    ClipItem(uri = "https://user:secret@example.com/a", text = "ftp://example.com/file"),
                    ClipItem(uri = "app://private/item", text = "example.com/bare-domain"),
                ),
            ),
        )
    }

    @Test
    fun duplicatesAcrossSourcesKeepTheFirstSubmissionString() {
        assertEquals(
            listOf("https://Example.com/Article?ref=A"),
            extract(
                intentDataUrl = "https://Example.com/Article?ref=A",
                extraText = "https://EXAMPLE.com/Article?ref=A",
                clipItems = listOf(
                    ClipItem(
                        uri = "https://example.com/Article?ref=A",
                        text = "https://example.com/Article?ref=A",
                    ),
                ),
            ),
        )
    }

    @Test
    fun urlsThatShareALabelButDifferAfterThePathStaySeparateCandidates() {
        val candidates = UrlCandidateExtractor.extract(
            sharePayload(
                extraText = "https://example.com/a?v=1 https://example.com/a?v=2 https://example.com/a#tail",
            ),
        )

        assertEquals(
            listOf("https://example.com/a?v=1", "https://example.com/a?v=2", "https://example.com/a#tail"),
            candidates.map { it.submissionValue },
        )
        // All three collapse to the same label, which is exactly why selection may not go by label.
        assertEquals(listOf("example.com/a", "example.com/a", "example.com/a"), candidates.map { it.displayLabel })
    }

    private fun extract(
        intentDataUrl: String? = null,
        extraText: String? = null,
        clipItems: List<ClipItem> = emptyList(),
    ): List<String> = UrlCandidateExtractor
        .extract(sharePayload(intentDataUrl, extraText, clipItems))
        .map { it.submissionValue }
}
