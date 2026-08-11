#!/usr/bin/env python3
"""Validate the checked-in native share payload contract without dependencies."""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path
from urllib.parse import urlsplit


ROOT = Path(__file__).resolve().parent
DATA_PATH = ROOT / "share-payloads.json"
SCHEMA_PATH = ROOT / "share-payloads.schema.json"
MIN_CASES = 200
URL_PATTERN = re.compile(r"^https?://[^\s]+$", re.IGNORECASE)
SENSITIVE_PATTERN = re.compile(
    r"(?:authorization|bearer|cookie|token=|api[_-]?key|password|session=)",
    re.IGNORECASE,
)


def fail(message: str) -> None:
    raise ValueError(message)


def require_type(value: object, kind: type, path: str) -> None:
    if not isinstance(value, kind):
        fail(f"{path} must be {kind.__name__}")


def validate_url(value: object, path: str) -> None:
    require_type(value, str, path)
    if not URL_PATTERN.fullmatch(value):
        fail(f"{path} is not an http(s) URL")
    parsed = urlsplit(value)
    if parsed.scheme.lower() not in {"http", "https"} or not parsed.hostname:
        fail(f"{path} must have an http(s) scheme and host")
    if parsed.username or parsed.password:
        fail(f"{path} must not contain userinfo")


def validate_case(case: object, index: int, ids: set[str]) -> None:
    path = f"cases[{index}]"
    require_type(case, dict, path)
    required = {
        "id",
        "source",
        "structured_urls",
        "plain_text",
        "expected_candidates",
        "expected_outcome",
        "requires_user_selection",
    }
    missing = required - case.keys()
    if missing:
        fail(f"{path} missing {sorted(missing)}")
    allowed = required
    extra = set(case) - allowed
    if extra:
        fail(f"{path} has unsupported fields {sorted(extra)}")

    case_id = case["id"]
    require_type(case_id, str, f"{path}.id")
    if not re.fullmatch(r"[a-z0-9][a-z0-9-]{2,96}", case_id):
        fail(f"{path}.id has invalid format")
    if case_id in ids:
        fail(f"duplicate case id: {case_id}")
    ids.add(case_id)

    sources = {
        "structured_url",
        "plain_text",
        "mixed",
        "clip_data",
        "ios_item_provider",
        "android_intent",
        "unsupported_scheme",
        "empty",
    }
    if case["source"] not in sources:
        fail(f"{path}.source is unsupported")

    structured = case["structured_urls"]
    require_type(structured, list, f"{path}.structured_urls")
    for item_index, item in enumerate(structured):
        require_type(item, str, f"{path}.structured_urls[{item_index}]")
    plain_text = case["plain_text"]
    if plain_text is not None:
        require_type(plain_text, str, f"{path}.plain_text")

    expected = case["expected_candidates"]
    require_type(expected, list, f"{path}.expected_candidates")
    for item_index, candidate in enumerate(expected):
        validate_url(candidate, f"{path}.expected_candidates[{item_index}]")
    if len(expected) != len(set(expected)):
        fail(f"{path}.expected_candidates must be unique")

    outcome = case["expected_outcome"]
    if outcome not in {"submit", "choose", "reject"}:
        fail(f"{path}.expected_outcome is unsupported")
    selected = case["requires_user_selection"]
    require_type(selected, bool, f"{path}.requires_user_selection")
    if selected != (outcome == "choose"):
        fail(f"{path}.requires_user_selection disagrees with outcome")
    if outcome == "submit" and len(expected) != 1:
        fail(f"{path} submit cases need exactly one candidate")
    if outcome == "choose" and len(expected) < 2:
        fail(f"{path} choose cases need multiple candidates")
    if outcome == "reject" and expected:
        fail(f"{path} reject cases cannot have candidates")

    for field in (plain_text, *structured):
        if field is not None and SENSITIVE_PATTERN.search(field):
            fail(f"{path} contains a sensitive-looking fixture value")


def main() -> int:
    try:
        schema = json.loads(SCHEMA_PATH.read_text(encoding="utf-8"))
        data = json.loads(DATA_PATH.read_text(encoding="utf-8"))
        if schema.get("$schema") != "https://json-schema.org/draft/2020-12/schema":
            fail("schema must declare JSON Schema 2020-12")
        if data.get("version") != 1:
            fail("fixture version must be 1")
        cases = data.get("cases")
        require_type(cases, list, "cases")
        if len(cases) < MIN_CASES:
            fail(f"expected at least {MIN_CASES} cases, got {len(cases)}")
        ids: set[str] = set()
        for index, case in enumerate(cases):
            validate_case(case, index, ids)
        print(f"validated {len(cases)} share payload cases")
        return 0
    except (OSError, json.JSONDecodeError, ValueError) as error:
        print(f"fixture validation failed: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
