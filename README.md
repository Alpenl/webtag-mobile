# WebTag Share (Mobile)

Share targets for [WebTag](https://github.com/Alpenl/WebTag): tap **Share → WebTag**
in any app and the link is filed into your own WebTag instance. Nothing else — no
reading list, no reader, no bottom navigation.

- **Android** — the maintained target. Kotlin, Compose, Room, WorkManager.
- **iOS** — a frozen source snapshot. It builds and its XCTest contract passes, but
  there is no signing, release, or device-verification guarantee. Do not read its
  presence here as a supported platform.

The URL is persisted locally *before* the first network request, with a stable
`Idempotency-Key`, so a failed or offline share is retried rather than lost.

## Install

Grab the APK from [Releases](../../releases) and sideload it. Then open the app once
to enter your server URL and an API key minted with the `write` scope.

Verify what you downloaded:

```bash
sha256sum -c SHA256SUMS
apksigner verify --print-certs webtag-share-v<version>.apk
```

The certificate SHA-256 is printed in every release's notes. **It must stay the same
across upgrades** — a different fingerprint means the APK was not signed with the
project's key, and Android will refuse to install it over an existing copy anyway.

## Support status

Android is the only maintained target. Its main flow covers deterministic URL
extraction, configuration validation, encrypted credentials and queued URLs,
Room-backed delivery, stable idempotency keys, foreground drain, WorkManager
fallback, explicit refresh, and the settings and share UI.

The iOS tree is a frozen source snapshot: a SwiftUI host, Share Extension, App
Group SQLite queue, Keychain integration, URLSession client, identity checks,
and background-upload recovery. Its XCTest contract is runnable, but Linux
development cannot run Xcode or a simulator, and there is no signing or release
guarantee. Shared fixtures and static checks still cover the contracts the
snapshot relies on, so it cannot silently drift away from Android — but Android
is the delivery surface.

Signed artifacts, production API smoke, emulator and device matrices, and
accessibility passes are optional release-confidence work, not gates.

## Configuration and safety

The server origin must be HTTPS. `GET /api/session` must return
`representation_contract=v2`, a canonical `write` scope, and a matching
`X-WebTag-Data-Namespace` before credentials become active. `POST /api/links`
sends only `{"url":"..."}` with the queue record's stable `Idempotency-Key`.
Authenticated requests never follow a cross-origin redirect and never bypass
system TLS validation. The API key is never written to the queue, logs,
analytics, or crash reports.

Queue, identity, retry, lease and storage invariants live in
[`ARCHITECTURE.md`](ARCHITECTURE.md). The frozen product and security decisions
live in [`docs/design-contract.md`](docs/design-contract.md).

## Build

Requires JDK 17 and an Android SDK (compileSdk 35).

```bash
./android/gradlew -p android --dependency-verification strict \
  testDebugUnitTest assembleDebug lintDebug
```

`--dependency-verification strict` is not optional: `android/gradle/verification-metadata.xml`
pins a SHA-256 for every dependency, so adding one means adding its checksum too.

The full gate, which is exactly what CI runs:

```bash
python3 shared/fixtures/validate.py
python3 shared/fixtures/compare.py
python3 scripts/mobile-x1-check.py
python3 scripts/mobile-wire-smoke.py
./android/gradlew -p android --dependency-verification strict \
  testDebugUnitTest assembleDebug lintDebug
```

`shared/fixtures/` is the cross-platform contract both platforms answer to —
URL extraction cases and the settings queue-state grouping table. `validate.py`
re-derives the expected answers independently, so a hand-edited expectation cannot
teach both suites the same wrong answer.

## Release

Releases are built and signed in CI. Signing deliberately lives **outside** Gradle:
`scripts/mobile-x1-check.py` forbids `signingConfigs` in `build.gradle.kts`, so no key
path or passphrase field can ever be committed. `assembleRelease` therefore produces an
unsigned APK, and `.github/workflows/release.yml` signs it with `apksigner` using
repository secrets. That workflow is the only one allowed to read those secrets — the
same gate forbids `secrets.` in `android.yml`, so ordinary pull requests, including ones
from forks, cannot reach them.

### One-time key setup

Generate the key **locally** and keep the `.jks` somewhere safe and backed up. Losing it
means you can never ship an upgrade to anyone who installed a previous build; they would
have to uninstall first, losing their queue.

```bash
keytool -genkeypair -v \
  -keystore webtag-share.jks \
  -alias webtag-share \
  -keyalg RSA -keysize 4096 -validity 10000
```

Then add four repository secrets under **Settings → Secrets and variables → Actions**:

| Secret | Value |
| --- | --- |
| `ANDROID_KEYSTORE_BASE64` | `base64 -w0 webtag-share.jks` |
| `ANDROID_KEYSTORE_PASSWORD` | the keystore password |
| `ANDROID_KEY_ALIAS` | `webtag-share` |
| `ANDROID_KEY_PASSWORD` | the key password |

Never commit the `.jks`; `.gitignore` already excludes `*.jks` and `*.keystore`, and CI
fails if one appears in the tree or in the build output.

### Cutting a release

Bump `versionCode` and `versionName` in `android/app/build.gradle.kts`, then tag. The
tag must match `versionName` exactly — CI refuses to publish otherwise, because a package
whose filename and internal version disagree will silently fail to install as an upgrade.

```bash
git tag v0.2.0
git push origin v0.2.0
```

The workflow re-runs the whole gate, builds, signs, verifies the signature, publishes the
APK and `SHA256SUMS`, and records the certificate fingerprint in the release notes.

To rehearse without publishing, dispatch `release` from a branch: it builds, signs and
verifies, uploads the APK as a workflow artifact, and creates no release.
