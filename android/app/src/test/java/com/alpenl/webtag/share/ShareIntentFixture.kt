package com.alpenl.webtag.share

import com.alpenl.webtag.share.contract.SharePayload

/** One `ClipData.Item`: a share can attach a URI, a text, both, or neither on the same item. */
internal data class ClipItem(val uri: String? = null, val text: String? = null)

/**
 * Builds the payload exactly the way [ShareActivity] does — by handing [NativeShareSources] an item
 * count and two accessors — so every test that starts from an Intent exercises the real traversal
 * instead of a pre-flattened list. An accessor called with an out-of-range index throws here, which
 * is the point: the count and the reads have to agree.
 */
internal fun sharePayload(
    intentDataUrl: String? = null,
    extraText: String? = null,
    clipItems: List<ClipItem> = emptyList(),
): SharePayload = NativeShareSources.payload(
    intentDataUrl = intentDataUrl,
    clipItemCount = clipItems.size,
    clipUriAt = { index -> clipItems[index].uri },
    extraText = extraText,
    clipTextAt = { index -> clipItems[index].text },
)
