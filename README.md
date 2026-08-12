# WebTag Mobile

[![Android](https://github.com/Alpenl/webtag-mobile/actions/workflows/android.yml/badge.svg)](https://github.com/Alpenl/webtag-mobile/actions/workflows/android.yml)
[![Android device](https://github.com/Alpenl/webtag-mobile/actions/workflows/android-device.yml/badge.svg)](https://github.com/Alpenl/webtag-mobile/actions/workflows/android-device.yml)
[![iOS](https://github.com/Alpenl/webtag-mobile/actions/workflows/ios.yml/badge.svg)](https://github.com/Alpenl/webtag-mobile/actions/workflows/ios.yml)

WebTag Mobile is the native Android and iOS action companion for a self-hosted
WebTag server. It combines reliable system-share capture with a focused mobile
surface for Today, TODOs, device transfers, and connection settings.

The app intentionally does not duplicate the complete Reader. Full-text
reading, annotations, long-form note editing, search, site/subscription
management, and AI chat remain Reader responsibilities. A projected TODO can
open its server-provided, same-origin Reader source.

## Features

- `Today`: overdue and due-today summaries, the next actionable TODOs, quick
  creation, and the current device's transfer summary.
- `Todos`: seven-day strip with Overdue, Today, Upcoming, No date, and
  Completed groups; standalone/projected filters and offline desired-state
  actions.
- `Transfers`: the durable local system-share queue, retry state, identity
  blocks, quota blocks, permanent failures, and explicit recovery actions.
- `Settings`: HTTPS WebTag origin, API key validation, identity migration,
  transfer recovery, and recent-result actions.
- System share targets on Android and iOS, with a stable `Idempotency-Key`
  persisted before the first network request.
- Deep links for `webtag://today`, `webtag://todos`,
  `webtag://transfers`, and `webtag://settings`.

TODO cache/outbox, capture transfers, Inbox review, and server parsing jobs are
separate domains. Completing a TODO cannot cancel a capture transfer, and a
failed device transfer is never presented as a checkable TODO.

## Repository Layout

```text
android/             Kotlin, Compose, Room v5, WorkManager, Keystore
ios/                 Swift, SwiftUI, Share Extension, Keychain, App Group
shared/fixtures/     cross-platform URL and queue-state contracts
scripts/             dependency-free security and wire-contract gates
.github/workflows/   Android, Android-device, iOS, and release automation
```

No server URL, API key, Apple certificate, provisioning profile, Android
keystore, or signing password is committed to this repository.

## Continuous Integration

Every change to the corresponding platform is verified by public GitHub
Actions:

- `android.yml`: shared contracts, security/wire gates, JVM tests, debug APK,
  and Android lint on Ubuntu.
- `android-device.yml`: all instrumentation tests on an API 26 emulator,
  including Compose navigation, Room migrations, encrypted persistence, TODO
  lease reclaim, and stale-owner rejection.
- `ios.yml`: fixture validation plus the app, Share Extension, XCTest, and UI
  test targets on an available iPhone simulator using Xcode on macOS.
- `release.yml`: the existing Android release path. It alone can read Android
  signing secrets and publishes signed APKs for version tags.

Third-party Actions are pinned to immutable commit SHAs. Ordinary build and
test workflows have read-only repository permissions and never receive signing
secrets.

## Local Android Build

Requires JDK 17 and Android SDK 35:

```bash
python3 shared/fixtures/validate.py
python3 shared/fixtures/compare.py
python3 scripts/mobile-x1-check.py
python3 scripts/mobile-wire-smoke.py
./android/gradlew -p android --dependency-verification strict \
  testDebugUnitTest assembleDebug lintDebug
./android/gradlew -p android --dependency-verification strict \
  connectedDebugAndroidTest
```

`connectedDebugAndroidTest` requires an emulator or physical device.
Dependency verification is strict; new dependencies must be added to
`android/gradle/verification-metadata.xml` with their checksums.

## Local iOS Build

Requires Xcode and an installed iOS Simulator runtime:

```bash
xcodebuild \
  -project ios/WebTagShare.xcodeproj \
  -scheme WebTagShare \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  CODE_SIGNING_ALLOWED=NO \
  test
```

The CI command dynamically selects an available iPhone simulator instead of
depending on one runner image's device name. Simulator testing does not prove
background-session behavior, production signing, App Store installation, or
physical-device compatibility; those remain release gates.

## Install And Connect

Android release APKs are available from [GitHub Releases](../../releases).
After installation, open Settings and enter:

1. the HTTPS origin of your WebTag API, for example
   `https://webtag.example.com`;
2. an API key with the `write` scope.

The app validates the session representation, namespace, and scope before it
activates the connection. Credentials are stored in platform security storage.

iOS currently ships as buildable source and CI-verified simulator tests. A
signed install requires your own Apple team, bundle identifiers, App Group,
Keychain access group, and provisioning profiles.

## Android Releases

The existing release workflow signs outside Gradle so ordinary build files
never contain keystore paths or password fields. Four repository secrets are
required for a release:

| Secret | Purpose |
| --- | --- |
| `ANDROID_KEYSTORE_BASE64` | base64-encoded release keystore |
| `ANDROID_KEYSTORE_PASSWORD` | keystore password |
| `ANDROID_KEY_ALIAS` | signing alias |
| `ANDROID_KEY_PASSWORD` | key password |

To release, update `versionCode` and `versionName`, then push a matching tag:

```bash
git tag v0.2.0
git push origin v0.2.0
```

The workflow re-runs the gates, signs and verifies the APK, publishes
`SHA256SUMS`, and records the signing certificate fingerprint in the release
notes. Losing or rotating the Android signing key prevents in-place upgrades
for existing installations.

## License

MIT. See [LICENSE](LICENSE).
