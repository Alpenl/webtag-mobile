#!/usr/bin/env python3
"""Compare shared fixture results and native source-test wiring.

This standard-library reference extractor prevents a malformed or stale
fixture from making both platform suites agree on the wrong answer. It also
checks that the Android suite and frozen iOS snapshot remain wired to their
real extractors and the ordered fixture source rather than merely checking the
JSON shape. Android executes these fixtures in the required JVM gate; iOS
runtime execution is intentionally outside the frozen snapshot gate.
"""

from __future__ import annotations

import json
import hashlib
import re
from pathlib import Path
from urllib.parse import urlsplit


ROOT = Path(__file__).resolve().parent
# 本仓库就是 Mobile 交付面，fixtures 位于 <repo>/shared/fixtures，因此仓库根是
# parents[1]，且 android / ios 直接挂在根下，没有 mobile/ 前缀。
REPOSITORY = ROOT.parents[1]
DATA_PATH = ROOT / "share-payloads.json"
ANDROID_TEST = REPOSITORY / "android/app/src/test/java/com/alpenl/webtag/share/UrlCandidateExtractorTest.kt"
IOS_TEST = REPOSITORY / "ios/WebTagShareTests/WebTagShareTests.swift"
URL_PATTERN = re.compile(
    r'''(?i)https?://[^\s<>"'\u2018-\u201f\u3000-\u303f\uff00-\uffef\u4e00-\u9fff]+'''
)
LEADING_WRAPPERS = set("([{<\u3008\u300a\u300c\u300e")
TRAILING_WRAPPERS = set(")]}>\u3009\u300b\u300d\u300f")
SENTENCE_PUNCTUATION = set(
    ".,!?:;#\u3002\uff0c\u3001\uff01\uff1f\u061f\u2026*`"
)


def normalize_candidate(raw: str) -> str | None:
    value = raw.strip()
    while value and value[0] in LEADING_WRAPPERS:
        value = value[1:]
    while value and value[-1] in TRAILING_WRAPPERS:
        value = value[:-1]
    while value and value[-1] in SENTENCE_PUNCTUATION:
        value = value[:-1]
        while value and value[-1] in TRAILING_WRAPPERS:
            value = value[:-1]
    if not value or " " in value:
        return None
    try:
        parsed = urlsplit(value)
        if parsed.scheme.lower() not in {"http", "https"}:
            return None
        if not parsed.hostname or parsed.username or parsed.password:
            return None
        _ = parsed.port
    except ValueError:
        return None
    return value


def deduplication_key(value: str) -> str:
    parsed = urlsplit(value)
    host = (parsed.hostname or "").lower()
    port = f":{parsed.port}" if parsed.port is not None else ""
    return (
        f"{parsed.scheme.lower()}://{host}{port}"
        f"{parsed.path}"
        f"{('?' + parsed.query) if parsed.query else ''}"
        f"{('#' + parsed.fragment) if parsed.fragment else ''}"
    )


def reference_extract(structured_urls: list[str], plain_text: str | None) -> list[str]:
    raw_values = list(structured_urls)
    if plain_text is not None:
        raw_values.extend(match.group(0) for match in URL_PATTERN.finditer(plain_text))
    candidates: list[str] = []
    seen: set[str] = set()
    for raw in raw_values:
        candidate = normalize_candidate(raw)
        if candidate is None:
            continue
        key = deduplication_key(candidate)
        if key not in seen:
            seen.add(key)
            candidates.append(candidate)
    return candidates


def result_digest(cases: list[dict[str, object]]) -> str:
    canonical = json.dumps(
        [
            {
                "id": case["id"],
                "expected_candidates": case["expected_candidates"],
                "expected_outcome": case["expected_outcome"],
            }
            for case in cases
        ],
        ensure_ascii=True,
        separators=(",", ":"),
    ).encode("utf-8")
    return hashlib.sha256(canonical).hexdigest()


def require_tokens(platform: str, source: str, tokens: tuple[str, ...]) -> None:
    missing = [token for token in tokens if token not in source]
    if missing:
        raise SystemExit(f"{platform} fixture test is missing required wiring: {missing}")


def main() -> int:
    data = json.loads(DATA_PATH.read_text(encoding="utf-8"))
    cases = data["cases"]
    ids = [case["id"] for case in cases]
    if len(ids) != len(set(ids)):
        raise SystemExit("fixture IDs are not unique")

    if len(cases) < 200:
        raise SystemExit(f"fixture count is below the X1 minimum: {len(cases)}")

    for index, case in enumerate(cases):
        expected = case["expected_candidates"]
        actual = reference_extract(case["structured_urls"], case["plain_text"])
        if actual != expected:
            raise SystemExit(
                f"reference extractor mismatch for {case['id']} at index {index}: "
                f"expected {expected!r}, got {actual!r}"
            )
        outcome = "reject" if not actual else "submit" if len(actual) == 1 else "choose"
        if outcome != case["expected_outcome"]:
            raise SystemExit(
                f"reference outcome mismatch for {case['id']}: "
                f"expected {case['expected_outcome']!r}, got {outcome!r}"
            )

    android_source = ANDROID_TEST.read_text(encoding="utf-8")
    ios_source = IOS_TEST.read_text(encoding="utf-8")
    require_tokens(
        "Android",
        android_source,
        (
            "share-payloads.json",
            "for (index in 0 until cases.length())",
            "UrlCandidateExtractor.extract",
            "expected_candidates",
            "expected_outcome",
            "assertEquals(fixture.getString(\"id\"",
        ),
    )
    require_tokens(
        "iOS",
        ios_source,
        (
            "share-payloads.json",
            "for fixture in cases",
            "URLCandidateExtractor.extract",
            "expected_candidates",
            "expected_outcome",
            "XCTAssertEqual(actual, expected, id)",
        ),
    )

    print(
        f"compared shared fixture results: {len(cases)} ordered cases, "
        f"result_digest={result_digest(cases)}, "
        "Android and frozen iOS parameterized sources wire native extractors to the same fields"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
