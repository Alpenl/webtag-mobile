#!/usr/bin/env python3
"""Run deterministic, dependency-free Mobile X1 contract and security checks."""

from __future__ import annotations

import os
import re
import sys
from pathlib import Path


REPOSITORY = Path(__file__).resolve().parents[1]
# 这个仓库本身就是 Mobile 交付面，不再有 mobile/ 前缀。
MOBILE = REPOSITORY
ANDROID = MOBILE / "android"
IOS = MOBILE / "ios"
FIXTURES = MOBILE / "shared" / "fixtures"
ANDROID_WORKFLOW = REPOSITORY / ".github/workflows/android.yml"
ANDROID_DEVICE_WORKFLOW = REPOSITORY / ".github/workflows/android-device.yml"
IOS_WORKFLOW = REPOSITORY / ".github/workflows/ios.yml"

QUEUE_STATES = {
    "pending_submit",
    "retry_wait",
    "blocked_auth",
    "blocked_scope",
    "blocked_quota",
    "blocked_identity",
    "failed_permanent",
    "expired",
}

SKIPPED_DIRECTORIES = {
    ".git",
    ".github",
    ".gradle",
    "build",
    "DerivedData",
    "artifacts",
    "node_modules",
}


class Gate:
    def __init__(self) -> None:
        self.errors: list[str] = []

    def require(self, condition: bool, message: str) -> None:
        if not condition:
            self.errors.append(message)

    def file(self, path: Path) -> str:
        try:
            return path.read_text(encoding="utf-8")
        except OSError as error:
            self.errors.append(f"cannot read {path.relative_to(REPOSITORY)}: {error}")
            return ""


def iter_mobile_files() -> list[Path]:
    files: list[Path] = []
    for directory, child_directories, child_files in os.walk(MOBILE):
        child_directories[:] = [
            name for name in child_directories if name not in SKIPPED_DIRECTORIES
        ]
        root = Path(directory)
        files.extend(root / name for name in child_files)
    return files


def check_fixture_wiring(gate: Gate) -> None:
    android_test = gate.file(
        ANDROID / "app/src/test/java/com/alpenl/webtag/share/UrlCandidateExtractorTest.kt"
    )
    ios_test = gate.file(IOS / "WebTagShareTests/WebTagShareTests.swift")
    compare = gate.file(FIXTURES / "compare.py")
    validator = gate.file(FIXTURES / "validate.py")

    gate.require(
        "MIN_CASES = 200" in validator,
        "fixture validator must retain the 200-case minimum",
    )
    gate.require(
        "reference_extract" in compare and "result_digest" in compare,
        "fixture comparator must calculate ordered reference results and a digest",
    )
    for platform, source, required in (
        (
            "Android",
            android_test,
            (
                "share-payloads.json",
                "for (index in 0 until cases.length())",
                "UrlCandidateExtractor.extract",
                "expected_candidates",
                "expected_outcome",
            ),
        ),
        (
            "iOS",
            ios_test,
            (
                "share-payloads.json",
                "for fixture in cases",
                "URLCandidateExtractor.extract",
                "expected_candidates",
                "expected_outcome",
            ),
        ),
    ):
        for token in required:
            gate.require(
                token in source,
                f"{platform} fixture test is missing {token!r}",
            )


def check_queue_and_retry_contract(gate: Gate) -> None:
    android_contract = gate.file(
        ANDROID / "app/src/main/java/com/alpenl/webtag/share/contract/MobileContract.kt"
    )
    android_retry = gate.file(
        ANDROID / "app/src/main/java/com/alpenl/webtag/share/contract/RetryPolicy.kt"
    )
    android_queue = gate.file(
        ANDROID / "app/src/main/java/com/alpenl/webtag/share/data/QueueDatabase.kt"
    )
    android_tests = "\n".join(
        gate.file(path)
        for path in (ANDROID / "app/src/test", ANDROID / "app/src/androidTest")
        for path in sorted(path.rglob("*.kt"))
    )
    ios_core = gate.file(IOS / "WebTagShare/Shared/WebTagShareCore.swift")
    ios_tests = gate.file(IOS / "WebTagShareTests/WebTagShareTests.swift")

    for state in QUEUE_STATES:
        gate.require(
            f'"{state}"' in android_contract,
            f"Android QueueState is missing {state}",
        )
        gate.require(
            state in android_queue or state.upper() in android_queue,
            f"Android Room contract is missing {state}",
        )
    swift_cases = {
        "pendingSubmit": "pending_submit",
        "retryWait": "retry_wait",
        "blockedAuth": "blocked_auth",
        "blockedScope": "blocked_scope",
        "blockedQuota": "blocked_quota",
        "blockedIdentity": "blocked_identity",
        "failedPermanent": "failed_permanent",
        "expired": "expired",
    }
    for case_name, wire_value in swift_cases.items():
        pattern = rf"case\s+{case_name}(?:\s*=\s*\"{wire_value}\")?"
        gate.require(
            re.search(pattern, ios_core) is not None,
            f"iOS QueueState is missing {case_name}={wire_value}",
        )

    gate.require(
        re.search(r"SEVEN_DAYS_MILLIS\s*=\s*7L\s*\*\s*24", android_retry)
        is not None,
        "Android retry policy must retain the seven-day expiry boundary",
    )
    gate.require(
        re.search(r"SIX_HOURS_MILLIS\s*=\s*6L\s*\*\s*60", android_retry)
        is not None,
        "Android retry policy must retain the six-hour cap",
    )
    gate.require(
        re.search(r"MIN_RETRY_AFTER_MILLIS\s*=\s*60L\s*\*\s*1000", android_retry)
        is not None,
        "Android retry policy must retain the 60-second Retry-After floor",
    )
    for token, message in (
        ("static let sevenDays", "iOS retry policy must retain seven-day expiry"),
        ("static let sixHours", "iOS retry policy must retain six-hour cap"),
        ("static let minimumRetryAfter", "iOS retry policy must retain Retry-After floor"),
    ):
        gate.require(token in ios_core, message)
    for source, platform in ((android_retry, "Android"), (ios_core, "iOS")):
        gate.require(
            "retryAfter" in source or "retryAfterMillis" in source,
            f"{platform} retry policy must parse Retry-After",
        )
        gate.require(
            "shouldExpire" in source,
            f"{platform} retry policy must enforce the expiry boundary",
        )
    for source, platform in ((android_tests, "Android"), (ios_tests, "iOS")):
        gate.require(
            "Retry-After" in source or "retryAfter" in source,
            f"{platform} tests must cover Retry-After",
        )
        gate.require(
            "SEVEN_DAYS" in source or "sevenDays" in source,
            f"{platform} tests must cover the seven-day boundary",
        )
        gate.require(
            "blockedIdentity" in source or "BLOCKED_IDENTITY" in source,
            f"{platform} tests must cover identity blocking",
        )


def check_status_identity_and_refresh(gate: Gate) -> None:
    android_api = gate.file(
        ANDROID / "app/src/main/java/com/alpenl/webtag/share/network/WebTagApiClient.kt"
    )
    android_runtime = gate.file(
        ANDROID / "app/src/main/java/com/alpenl/webtag/share/queue/QueueRuntime.kt"
    )
    android_tests = "\n".join(
        gate.file(path)
        for path in sorted((ANDROID / "app/src").rglob("*.kt"))
        if "build" not in path.parts
    )
    ios_core = gate.file(IOS / "WebTagShare/Shared/WebTagShareCore.swift")
    ios_content = gate.file(IOS / "WebTagShare/App/ContentView.swift")
    ios_tests = gate.file(IOS / "WebTagShareTests/WebTagShareTests.swift")

    for platform, source in (
        ("Android API", android_api),
        ("Android queue", android_runtime + android_api),
        ("iOS core", ios_core),
    ):
        gate.require(
            "X-WebTag-Data-Namespace" in source or "clientDataNamespace" in source,
            f"{platform} must enforce the namespace identity gate",
        )
        gate.require(
            "OriginNormalizer" in source or "OriginNormalizer.normalize" in source,
            f"{platform} must use canonical HTTPS origin validation",
        )
    for platform, source in (("Android", android_api), ("iOS", ios_core)):
        gate.require("refresh" in source, f"{platform} API client is missing refresh")
        gate.require(
            "responseLinkId" in source or "sameUUID" in source,
            f"{platform} refresh must validate the response link identifier",
        )
    gate.require(
        "failedSubmitIsACompletedResultAndDoesNotTriggerRefresh" in android_tests,
        "Android must cover failed submit as a terminal recent result",
    )
    gate.require(
        'recent.status == "failed"' in ios_content,
        "iOS settings must expose failed submit as an explicit refresh action",
    )
    gate.require(
        "status: \"failed\"" in ios_tests or 'status: "failed"' in ios_tests,
        "iOS tests must cover the failed submit status",
    )
    gate.require(
        "testFailedSubmitDoesNotImplicitlyRefresh" in ios_tests,
        "iOS must prove failed submit does not issue an implicit refresh",
    )
    for platform, source in (("Android", android_tests), ("iOS", ios_tests)):
        source_lower = source.lower()
        gate.require(
            "identityMigration" in source or "migrateIdentity" in source,
            f"{platform} tests must cover identity migration/key rotation",
        )
        gate.require(
            "refreshrejects" in source_lower or "refreshuses" in source_lower,
            f"{platform} tests must cover explicit refresh validation",
        )


def check_network_storage_and_release_security(gate: Gate) -> None:
    manifest = gate.file(ANDROID / "app/src/main/AndroidManifest.xml")
    backup_rules = gate.file(ANDROID / "app/src/main/res/xml/backup_rules.xml")
    extraction_rules = gate.file(
        ANDROID / "app/src/main/res/xml/data_extraction_rules.xml"
    )
    android_api = gate.file(
        ANDROID / "app/src/main/java/com/alpenl/webtag/share/network/WebTagApiClient.kt"
    )
    android_build = gate.file(ANDROID / "app/build.gradle.kts")
    android_queue = gate.file(
        ANDROID / "app/src/main/java/com/alpenl/webtag/share/data/QueueDatabase.kt"
    )
    ios_core = gate.file(IOS / "WebTagShare/Shared/WebTagShareCore.swift")
    ios_config = gate.file(IOS / "Config/Shared.xcconfig")
    ios_project = gate.file(IOS / "WebTagShare.xcodeproj/project.pbxproj")

    gate.require('android:allowBackup="false"' in manifest, "Android backups must be disabled")
    gate.require(
        'android:dataExtractionRules="@xml/data_extraction_rules"' in manifest,
        "Android data extraction rules must be wired",
    )
    for name, source in (
        ("Android legacy backup rules", backup_rules),
        ("Android data extraction rules", extraction_rules),
    ):
        gate.require(
            source.count('<exclude domain="') >= 5,
            f"{name} must exclude all app storage domains",
        )
    gate.require("AndroidKeystoreCipher" in android_queue, "Android queue must use Keystore-backed URL encryption")
    gate.require("apiKey" not in android_queue, "Android queue source must not contain API-key fields")
    gate.require(".followRedirects(false)" in android_api, "Android must reject HTTP redirects")
    gate.require(".followSslRedirects(false)" in android_api, "Android must reject HTTPS redirects")
    gate.require("willPerformHTTPRedirection" in ios_core, "iOS must implement redirect cancellation")
    gate.require("completionHandler(nil)" in ios_core, "iOS redirect delegate must cancel redirects")
    gate.require("FileProtectionType.completeUntilFirstUserAuthentication" in ios_core, "iOS queue must use file protection")
    gate.require("isExcludedFromBackup = true" in ios_core, "iOS queue must be excluded from backup")
    gate.require("CODE_SIGN_STYLE = Automatic" in ios_config, "iOS signing must remain Xcode-configured")
    for forbidden in (
        "DEVELOPMENT_TEAM =",
        "PROVISIONING_PROFILE_SPECIFIER =",
        "signingConfigs",
        "NSAllowsArbitraryLoads",
    ):
        gate.require(
            forbidden not in ios_project and forbidden not in android_build,
            f"release configuration must not commit {forbidden}",
        )

    production_sources = [
        android_api,
        android_queue,
        gate.file(ANDROID / "app/src/main/java/com/alpenl/webtag/share/ShareActivity.kt"),
        ios_core,
        gate.file(IOS / "WebTagShare/ShareExtension/ShareViewController.swift"),
    ]
    forbidden_patterns = (
        r"usesCleartextTraffic\s*=\s*\"true\"",
        r"NSAllowsArbitraryLoads[^\n]*true",
        r"HostnameVerifier\s*\{[^}]*->\s*true",
        r"trustAll(?:Certificates|Hosts)?",
        r"(?:Log\.[A-Za-z]+|println|print|NSLog)\s*\([^\n]*(?:apiKey|Authorization|Bearer)",
    )
    for pattern in forbidden_patterns:
        for source in production_sources:
            gate.require(
                re.search(pattern, source, flags=re.IGNORECASE | re.DOTALL) is None,
                f"production Mobile source matches forbidden security pattern {pattern!r}",
            )

    sensitive_suffixes = {
        ".p12",
        ".mobileprovision",
        ".jks",
        ".keystore",
        ".ipa",
        ".aab",
        ".xcarchive",
        ".xcuserstate",
    }
    sensitive_names = {"local.properties"}
    hits = []
    for path in iter_mobile_files():
        if path.name in sensitive_names or path.suffix.lower() in sensitive_suffixes:
            hits.append(str(path.relative_to(REPOSITORY)))
    gate.require(not hits, f"sensitive or signed Mobile files are present: {hits}")


def check_workflows(gate: Gate) -> None:
    android_workflow = gate.file(ANDROID_WORKFLOW)
    android_device_workflow = gate.file(ANDROID_DEVICE_WORKFLOW)
    ios_workflow = gate.file(IOS_WORKFLOW)
    for path, source in (
        (ANDROID_WORKFLOW, android_workflow),
        (ANDROID_DEVICE_WORKFLOW, android_device_workflow),
        (IOS_WORKFLOW, ios_workflow),
    ):
        label = str(path.relative_to(REPOSITORY))
        gate.require("secrets." not in source, f"{label} must not read release secrets")
        gate.require("environment:" not in source, f"{label} must not attach a release environment")
        for line in source.splitlines():
            match = re.search(r"\buses:\s*(\S+)", line)
            if not match or match.group(1).startswith("./"):
                continue
            action = match.group(1).split("#", 1)[0]
            gate.require(
                re.search(r"@[0-9a-fA-F]{40}$", action) is not None,
                f"{label} action is not pinned to a commit: {action}",
            )
        for forbidden in (
            "pnpm install",
            "pnpm audit",
            "pnpm api:check",
            "pnpm api:typecheck",
        ):
            gate.require(
                forbidden not in source,
                f"{label} must not run heavyweight gate {forbidden}",
            )

    # 改 X1 / wire-smoke 脚本必须重跑本 workflow，否则改坏门禁的那次改动
    # 恰好是唯一不受门禁检查的改动。主仓里这条由 ci.yml 的路径过滤承担，
    # 这里没有调度层，所以回到由 workflow 自己的 paths 保证。
    for script in ("scripts/mobile-x1-check.py", "scripts/mobile-wire-smoke.py"):
        gate.require(
            f'"{script}"' in android_workflow,
            f"Android workflow must trigger on changes to {script}",
        )
    gate.require('java-version: "17"' in android_workflow, "Android CI must use JDK 17")
    for token in (
        "--dependency-verification strict",
        "testDebugUnitTest",
        "assembleDebug",
        "lintDebug",
        "actions/upload-artifact@",
        "android/app/build/outputs/apk/debug/*.apk",
    ):
        gate.require(token in android_workflow, f"Android workflow is missing {token}")
    gate.require(
        android_workflow.count("runs-on: ubuntu-24.04") == 1,
        "Android workflow must use one Ubuntu job",
    )
    for forbidden in (
        "assembleRelease",
        "connectedDebugAndroidTest",
        "api-level:",
        "sdkmanager",
        "avdmanager",
        "emulator",
    ):
        gate.require(
            forbidden not in android_workflow,
            f"Android workflow must not run {forbidden}",
        )

    for token in (
        "api-level: 26",
        "connectedDebugAndroidTest",
        "ReactiveCircus/android-emulator-runner@",
        "actions/upload-artifact@",
    ):
        gate.require(token in android_device_workflow, f"Android device workflow is missing {token}")
    for token in (
        "runs-on: macos-15",
        "xcodebuild",
        "-project ios/WebTagShare.xcodeproj",
        "-scheme WebTagShare",
        "CODE_SIGNING_ALLOWED=NO",
        "test",
    ):
        gate.require(token in ios_workflow, f"iOS workflow is missing {token}")



def main() -> int:
    gate = Gate()
    check_fixture_wiring(gate)
    check_queue_and_retry_contract(gate)
    check_status_identity_and_refresh(gate)
    check_network_storage_and_release_security(gate)
    check_workflows(gate)
    if gate.errors:
        for error in gate.errors:
            print(f"mobile X1 gate: {error}", file=sys.stderr)
        return 1
    print(
        "mobile X1 static gate passed: fixture wiring, eight queue states, "
        "retry/identity/refresh contracts, storage/network security, "
        "signing-file scans, and lightweight pinned workflow isolation"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
