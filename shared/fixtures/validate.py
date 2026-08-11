#!/usr/bin/env python3
"""Validate the checked-in mobile fixture contracts without dependencies.

Two fixtures live here: the native share payload contract and the settings
queue-state table that both platforms group into the frozen six sections.
"""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path
from urllib.parse import urlsplit


ROOT = Path(__file__).resolve().parent
DATA_PATH = ROOT / "share-payloads.json"
SCHEMA_PATH = ROOT / "share-payloads.schema.json"
QUEUE_STATES_PATH = ROOT / "queue-states.json"
MIN_CASES = 200

# The frozen settings grouping: section order, and which queue state feeds which
# section. Both are part of the contract, so they are spelled out here rather than
# read back out of the fixture that is being checked.
QUEUE_GROUP_ORDER = (
    "pending_and_retry",
    "blocked_credential",
    "blocked_identity",
    "blocked_quota",
    "failed_permanent",
    "expired",
)
QUEUE_STATE_GROUPS = {
    "pending_submit": "pending_and_retry",
    "retry_wait": "pending_and_retry",
    "blocked_auth": "blocked_credential",
    "blocked_scope": "blocked_credential",
    "blocked_identity": "blocked_identity",
    "blocked_quota": "blocked_quota",
    "failed_permanent": "failed_permanent",
    "expired": "expired",
}
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


def validate_queue_row(row: object, path: str, ids: set[str]) -> None:
    require_type(row, dict, path)
    required = {
        "id",
        "state",
        "url",
        "first_failed_at",
        "next_attempt_at",
        "identity_mismatch",
    }
    missing = required - row.keys()
    if missing:
        fail(f"{path} missing {sorted(missing)}")
    extra = set(row) - required
    if extra:
        fail(f"{path} has unsupported fields {sorted(extra)}")

    row_id = row["id"]
    require_type(row_id, str, f"{path}.id")
    if not re.fullmatch(r"[a-z0-9][a-z0-9-]{2,96}", row_id):
        fail(f"{path}.id has invalid format")
    if row_id in ids:
        fail(f"duplicate row id: {row_id}")
    ids.add(row_id)

    if row["state"] not in QUEUE_STATE_GROUPS:
        fail(f"{path}.state is not one of the eight queue states")

    mismatch = row["identity_mismatch"]
    require_type(mismatch, bool, f"{path}.identity_mismatch")
    url = row["url"]
    require_type(url, str, f"{path}.url")
    # A row the repository fenced out of the active identity reaches the UI with its
    # URL already stripped; a fixture that carries one would let a redaction
    # regression pass unnoticed.
    if mismatch:
        if url:
            fail(f"{path}.url must be empty for an identity-mismatched row")
        if row["state"] != "blocked_identity":
            fail(f"{path} identity mismatch is only representable as blocked_identity")
    else:
        validate_url(url, f"{path}.url")

    for field in ("first_failed_at", "next_attempt_at"):
        value = row[field]
        if value is None:
            continue
        require_type(value, int, f"{path}.{field}")
        if value <= 0:
            fail(f"{path}.{field} must be a positive epoch millisecond value")
    if SENSITIVE_PATTERN.search(url):
        fail(f"{path} contains a sensitive-looking fixture value")


def validate_queue_case(case: object, index: int, ids: set[str]) -> None:
    path = f"cases[{index}]"
    require_type(case, dict, path)
    required = {"id", "rows", "expected_total", "expected_groups"}
    missing = required - case.keys()
    if missing:
        fail(f"{path} missing {sorted(missing)}")
    extra = set(case) - required
    if extra:
        fail(f"{path} has unsupported fields {sorted(extra)}")

    case_id = case["id"]
    require_type(case_id, str, f"{path}.id")
    if case_id in ids:
        fail(f"duplicate case id: {case_id}")
    ids.add(case_id)

    rows = case["rows"]
    require_type(rows, list, f"{path}.rows")
    row_ids: set[str] = set()
    for row_index, row in enumerate(rows):
        validate_queue_row(row, f"{path}.rows[{row_index}]", row_ids)

    # Independently derive what the grouping has to produce. Recomputing it here is
    # what stops a hand-edited `expected_groups` from teaching both platform suites
    # the same wrong answer.
    derived: dict[str, list[str]] = {}
    for row in rows:
        derived.setdefault(QUEUE_STATE_GROUPS[row["state"]], []).append(row["id"])
    expected_derived = [
        {"key": key, "count": len(derived[key]), "row_ids": derived[key]}
        for key in QUEUE_GROUP_ORDER
        if key in derived
    ]
    if case["expected_groups"] != expected_derived:
        fail(
            f"{path}.expected_groups disagrees with the frozen mapping: "
            f"expected {expected_derived!r}, got {case['expected_groups']!r}"
        )
    if case["expected_total"] != len(rows):
        fail(f"{path}.expected_total must count every durable row")


def validate_queue_states() -> int:
    data = json.loads(QUEUE_STATES_PATH.read_text(encoding="utf-8"))
    if data.get("version") != 1:
        fail("queue-states fixture version must be 1")

    groups = data.get("groups")
    require_type(groups, list, "groups")
    if [group["key"] for group in groups] != list(QUEUE_GROUP_ORDER):
        fail("groups must list the frozen section order exactly once each")
    declared_states = [state for group in groups for state in group["states"]]
    if sorted(declared_states) != sorted(QUEUE_STATE_GROUPS):
        fail("groups must partition all eight queue states")
    for group in groups:
        for state in group["states"]:
            if QUEUE_STATE_GROUPS[state] != group["key"]:
                fail(f"state {state} is declared under the wrong group")

    cases = data.get("cases")
    require_type(cases, list, "cases")
    ids: set[str] = set()
    for index, case in enumerate(cases):
        validate_queue_case(case, index, ids)

    covered = {row["state"] for case in cases for row in case["rows"]}
    uncovered = set(QUEUE_STATE_GROUPS) - covered
    if uncovered:
        fail(f"queue-state fixture does not cover {sorted(uncovered)}")
    return len(cases)


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
        queue_cases = validate_queue_states()
        print(
            f"validated {len(cases)} share payload cases "
            f"and {queue_cases} queue-state grouping cases"
        )
        return 0
    except (OSError, json.JSONDecodeError, ValueError) as error:
        print(f"fixture validation failed: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
