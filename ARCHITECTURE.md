# WebTag Share Mobile Architecture

This document owns the current Mobile process, storage, identity, queue,
retry, encryption, and dependency boundaries. Android is the maintained MVP
runtime. The iOS implementation is retained as a frozen, unverified source
snapshot and is not an active release target.

## Component Layout

```text
shared/fixtures/       payload schema, synthetic cases, and reference tools
scripts/               X1 static contract gate and local wire smoke
android/
  app/                 maintained Android application and tests
  gradle/              wrapper, version catalog, and verification metadata
ios/
  Config/              shared identifiers and build settings
  WebTagShare/         frozen host, extension, and shared Swift source
  WebTagShare.xcodeproj
  WebTagShareTests/
  WebTagShareUITests/
```

Android and iOS are independent native build roots. Neither imports backend,
Reader, browser-extension, or generated TypeScript source. Both communicate
only through the public WebTag HTTP API. A route, DTO, scope, or response
identity change starts in the backend's OpenAPI document
(`internal/app/assets/openapi.json` in the upstream WebTag repository, which is
private); native fixtures and tests here then update against the published
contract. That seam is now cross-repository, so nothing in this repository can
verify it automatically — a backend contract change that this repository has
not followed shows up as a runtime failure against a real server, not as a red
gate.

## Dependency Direction

```text
Android sharesheet -> ShareActivity -> queue/network/security core
Android launcher   -> MainActivity  -> queue/network/security core
Android scheduler  -> QueueWorker   -> queue/network/security core

iOS system share sheet -> WebTagShareExtension -> shared Swift core
iOS launcher           -> WebTagShare          -> shared Swift core

native clients -> public WebTag HTTP API
```

The iOS arrows describe the checked-in snapshot. They do not imply current
runtime verification or ongoing maintenance.

## Shared Request Invariants

- Candidate extraction is deterministic. Structured URLs take precedence over
  plain-text scanning, results retain first-seen order, and multiple distinct
  candidates require explicit selection.
- Only a proven HTTP(S) URL can be persisted or uploaded. Original share text
  is never stored, queued, logged, or sent.
- A queue record is committed before its first network request. Its URL body,
  request fingerprint, and `Idempotency-Key` remain bound across foreground
  sends, background sends, timeouts, process recreation, and retries.
- `POST /api/links` sends only `{"url":"..."}`. A valid
  `SubmitResponse.status` of `pending`, `processing`, `done`, or
  `failed` completes the submit record. `status=failed` never triggers an
  implicit refresh.
- Explicit refresh is a settings action against the recent result. Cooldown,
  quota, link ID, job ID, and refresh timing remain in recent-result storage;
  refresh does not recreate a submit queue record.
- Authenticated requests never follow redirects across origins, allow an HTTP
  downgrade, install a custom trust bypass, or disable system TLS validation.

## Identity And Credentials

The configured server URL is normalized to an HTTPS origin with no user info,
query, fragment, or non-root path. Hosts are lowercased, an explicit default
port `443` is removed, and a non-default HTTPS port is retained. A candidate
configuration is activated only after `GET /api/session` returns:

- HTTP 200;
- `representation_contract=v2`;
- a canonical scope set containing `write`;
- a valid `client_data_namespace`; and
- a matching `X-WebTag-Data-Namespace` response header.

Validation happens before the encrypted credential and active-session identity
are switched. A failed validation or activation restores the previous usable
configuration. Without a validated active identity, a share attempt does not
create an anonymous queue row.

Each queue and recent-result row stores the validated origin and opaque
namespace. Sending a row, accepting a response, showing sensitive result
details, or refreshing a result requires both values to match the active
identity.

A newly validated credential automatically restores only
`blocked_auth`/`blocked_scope` rows whose origin and namespace still match.
An identity change leaves rows redacted and `blocked_identity` until the user
confirms migration. Migration preserves the row ID, URL, and creation time,
rebinds encrypted data to the new identity, clears transient failure and lease
fields, and rotates the idempotency key. Recent results are not migrated across
identities because their link IDs are identity-local.

Every successful HTTP response is still untrusted input. A missing or unknown
status, malformed JSON, invalid UUID, mismatched link ID, or missing/mismatched
namespace header is classified as `invalid_success_payload` (or the equivalent
local client-response error) and must not be shown as success. Submit rows fail
closed as `failed_permanent`; refresh writes additionally compare the selected
`link_id` so a late response cannot overwrite a newer recent result.

## Queue State And Ownership

The queue has exactly eight business states:

| State | Automatic work | Recovery |
| --- | --- | --- |
| `pending_submit` | eligible immediately | retry or delete |
| `retry_wait` | eligible at `next_attempt_at` | retry or delete |
| `blocked_auth` | no | validate a matching credential |
| `blocked_scope` | no | validate a matching `write` credential |
| `blocked_quota` | no | user retries after quota recovery |
| `blocked_identity` | no | switch identity, migrate, or delete |
| `failed_permanent` | no | confirmed retry or delete |
| `expired` | no | explicit retry or delete |

There is no durable `sending` state. A sender atomically claims one eligible
row with a random `lease_owner` and finite `lease_expires_at`. Only that
owner may apply its response. An expired lease can be reclaimed, and a late
callback from the old owner is ignored. This rule prevents a foreground
request, worker, or recovered background callback from overwriting a newer
result.

Claims are selected by due time and then creation order. `next_attempt_at` in
Room is authoritative; WorkManager only wakes the process. Completion updates
must match both the row ID and the current, unexpired lease owner. A successful
submit writes the encrypted recent result and removes the active queue row in
one Room transaction.

Each row carries a SHA-256 fingerprint of the submitted URL. Decryption must
reproduce that fingerprint before a request is sent or a result is committed.
Persistent failure data is restricted to the stable error kind, a bounded
80-character server error code, HTTP status, and retry time. Raw response
bodies, headers, stack traces, cookies, credentials, and complete URLs are not
stored as error diagnostics.

Retryable network failures, HTTP 408/425, HTTP 5xx, and
`429 rate_limit_exceeded` move to `retry_wait`. Retry timing uses bounded
exponential jitter with a 30-second base, samples from half of the current cap
through the cap, honors both delta-seconds and HTTP-date `Retry-After`, applies
a 60-second minimum for rate limits/cooldowns, and caps one automatic delay at
six hours. A row is never scheduled before `next_attempt_at`. The first failure
starts a seven-day window; after it elapses the row becomes `expired` without
being deleted.

TLS trust failures, redirects, unsupported 4xx responses, invalid success
payloads, and unreadable local ciphertext become `failed_permanent`.
`401`, insufficient scope, quota exhaustion, and identity mismatch use their
dedicated blocked states. Refresh cooldown and quota responses update the
recent result rather than this submit state machine.

Manual retry preserves the URL, row ID, idempotency key, and identity. Retrying
an expired row also resets its failure window but does not rotate its key. Only
an explicitly confirmed identity migration rotates the key and re-encrypts the
URL for the new identity.

## Android Runtime

`ShareActivity` is an exported, translucent activity limited to
`ACTION_SEND` and `text/plain`. It reads `EXTRA_TEXT`, `Intent.data`,
and `ClipData`, presents a chooser when necessary, and persists through the
coordinator before finishing. Recreated activities restore only non-sensitive
selection/status state and reuse an existing durable row so the original key
and URL pairing is preserved.

`MainActivity` is the launcher and settings surface. It drains at most 16 due
rows when the app starts or returns to the foreground, then asks the scheduler
to arrange the next wake-up. `QueueWorker` is the durable fallback and uses
the unique work name `webtag-share-queue-drain`,
`NetworkType.CONNECTED`, earliest-due scheduling, and the same lease
protocol. WorkManager is eventual scheduling, not a promise of immediate
execution after force-stop or under vendor battery restrictions.

Room is the Android queue source of truth. Schema version 2 adds
`active_session` through non-destructive `MIGRATION_1_2`; existing queue
and recent-result rows remain intact, and the API key is never stored in the
database.

UI commands read and mutate durable state through the repository/coordinator;
the settings surface only observes Room invalidations to refresh its snapshot.
All producers share the same scheduler and lease protocol rather than creating
independent retry loops.

Queued URLs use a non-exportable Android Keystore AES-256-GCM key, a fresh
randomized nonce for each encryption, and additional authenticated data bound
to row ID, schema version, origin, and namespace. Identity migration decrypts
with the old binding and writes new ciphertext and a new nonce under the new
binding. The API key is stored in an atomic private file protected by a
Keystore key. Decryption, authentication, key-loss, or migration failure fails
closed: it must not clear the queue, silently discard a row, or fall back to
plaintext. The manifest disables backup and wires storage exclusion rules.

## Frozen iOS Boundary

`WebTagShare` is the long-lived SwiftUI host and
`WebTagShareExtension` is the short-lived system share process. The snapshot
uses an App Group SQLite database, a shared Keychain access group, and the
background-session identifier
`com.alpenl.webtag.share.background-submit`.

The snapshot stores upload bodies under the App Group, applies file protection
and backup exclusion, attaches queue/lease ownership to background tasks, and
lets the host reconcile expired leases and drain pending rows on launch or
foreground entry. It does not promise a system wake after the user force-quits
the host; reopening the host is the recovery trigger.

The GitHub macOS workflow runs the XCTest contract against an iOS simulator.
No device, signing, production release, or runtime background-recovery result
is claimed. These source boundaries are retained so the snapshot remains
understandable, not as an obligation to continue iOS development.

## Security And Verification Ownership

Production logging must exclude API keys, Authorization headers, complete
URLs, namespaces, response bodies, cookies, and original share text. Signing
certificates, provisioning profiles, Team IDs, keystores, passwords, signed
packages, and machine SDK paths stay outside version control.

Release variants must not contain test certificate authorities, mock endpoints,
fault injection, or verbose sensitive logging. Future destructive storage
changes use an expand/contract migration and retain backward-read checks;
uninstalling the app is not a migration or recovery procedure.

[`README.md`](README.md) owns current platform support, developer commands,
and fast-gate status. The maintained gate covers shared fixtures, static and
wire contracts, Android JVM tests/debug assembly/lint, and iOS XCTest on a
macOS simulator runner. Device matrices, signed builds, production smoke,
accessibility, and upgrade/rollback exercises are optional release confidence
work rather than closeout blockers.
