# WebTag Share Mobile Fixtures

This directory holds the cross-platform fixture contracts. It contains only
synthetic or sanitized values.

- `share-payloads.json` — deterministic URL extraction from native share
  payloads.
- `queue-states.json` — how the eight durable queue states are grouped into the
  settings screen's six sections.

Both platforms must consume the same JSON files and produce the recorded
answers in the recorded order.

## Share payload contract

Each case records its `source`, the structured URL values supplied by a share
provider, an optional plain-text value, the expected candidate strings, and
whether the user must choose a candidate. Candidates are only `http` or
`https` URLs with a host. The candidate string is preserved after removing
only adjacent wrapping characters and sentence punctuation.

Deduplication is stable: the first occurrence wins. The comparison key
normalizes the scheme and host to lowercase while preserving path, query,
fragment, percent-encoding, and the original string returned for submission.
The same rules apply to structured values and text-scanned values. A case with
zero candidates is rejected without persisting or uploading its source text.

## Queue state contract

`queue-states.json` freezes the settings grouping. `groups` records the section
order and which queue state feeds which section: `pending_submit` and
`retry_wait` become `pending_and_retry`, `blocked_auth` and `blocked_scope`
become `blocked_credential`, and the remaining four states each keep a section
of their own.

Each case is a table of durable rows in repository order plus the projection it
must produce: `expected_total` counts every row, and `expected_groups` lists
only the non-empty sections, in section order, each with its own count and the
row IDs it contains in repository order. An empty section is absent rather than
present with a zero count. A row with `identity_mismatch` is a `blocked_identity`
row whose URL the repository has already stripped, so its fixture URL is empty.

Grouping is a presentation fact only. It does not change send priority,
claiming, or the queue state machine.

## Validation

Run the standard-library validator from the repository root:

```bash
python3 mobile/shared/fixtures/validate.py
```

The validator checks the JSON shape, unique IDs, minimum case count, candidate
scheme/host rules, expected outcome invariants, and sensitive fixture patterns.
For `queue-states.json` it re-derives every case's grouping from the frozen
state-to-section mapping and rejects a hand-edited `expected_groups` that
disagrees, which is what stops a stale fixture from teaching both platform
suites the same wrong answer. It intentionally does not import either native
implementation.

The cross-platform result contract can be checked with the repository command
`python3 shared/fixtures/compare.py`. This gate runs a dependency-free
reference extractor against every ordered case, compares candidates and the
recorded outcome, prints a stable result digest, and confirms that the Android
and iOS parameterized suites remain wired to their native extractors and the
same JSON fields. Android runs the fast JVM suite and API 26 instrumentation;
iOS runs its XCTest and UI test targets on a public macOS runner.
