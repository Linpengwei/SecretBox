**English** · [简体中文](TESTING.zh-CN.md)

# Testing

**English** · [简体中文](TESTING.zh-CN.md)

## macOS app

Run the macOS app regression suite with:

```bash
./scripts/test-macos.sh
```

What it does:

- `build-for-testing`
- runs `SecretBoxTests/SecretBoxAppModelTests`
- runs `testDiverseFiftySampleSetPersistAndClassify`
- runs each UI smoke test one by one
- retries a UI test once if macOS automation times out

Run only the dedicated 50-sample classifier regression with:

```bash
./scripts/test-sample-set-macos.sh
```

If you see `Sandbox restriction` or `testmanagerd.control was invalidated`, the app tests were blocked by the current execution environment. Run the script from a normal local Terminal or from Xcode.

Also quit any running SecretBox instance first: a second live instance of the same bundle ID (e.g. the Release app left open) confuses XCUITest's accessibility snapshots and makes the UI tests fail with element-matching errors. The `testMenuBarSmokeFlowCanSaveAndOpenDashboard` MenuBarExtra test is additionally flaky in non-Xcode environments (e.g. `does not have a process ID`), independent of code changes.

## iOS simulator

```bash
./scripts/test-ios.sh
```

Verifies an iOS simulator runtime exists, then on `iPhone 17`: `build-for-testing` → unit tests → 50-sample classifier regression → **7 UI smoke chains** (login / seeded search / capture sheet / capture→save→search→detail→copy-password / otpauth capture→live TOTP code→copy / read-only permission lock / settings sheet). Menu-bar tests skip on iOS via `XCTSkip`. The snapshot suite (`ViewSnapshotTests` + `SnapshotLite`) is macOS-only and compiles out on iOS via `#if canImport(AppKit)`.

UI-test notes: sheets that hold text input get their keyboard dismissed (scroll on `editor.scroll`) before tapping pinned action buttons — taps can silently drop while the keyboard-avoidance animation is live; `focusAndType` retries focus until the keyboard appears.

## TOTP / permission coverage (phase MP)

- `SecretBoxTests/TOTPEngineTests.swift` — RFC 6238 Appendix B vectors (SHA1 8-digit set, SHA256, 6-digit truncation), base32 tolerance matrix, `otpauth://` parsing matrix (minimal/full/invalid/hotp-rejected), period boundary rotation, `secondsRemaining` invariants.
- `SecretBoxAppModelTests.swift` (TOTP/permissions sections) — editor seed entry round-trip through the Keychain store, keep-on-empty-input / replace / remove semantics, invalid-input save blocking, pasted `otpauth://` capture (mixed + URI-only), preview flag, `effectivePermissions` legacy mapping, permission persistence, read-only lock + unlock path, `ReauthGate` injection (denied/allowed/idle), `setAIAccess` levels + legacy mirror, `copyTOTPCode`.
- `server/tests/test_api.py` — `totp_encrypted` ciphertext-only storage, search/create/update payload round-trip, keep/replace/`remove_totp` semantics, invalid payload 422, pasted URI scrub-and-route, **AI red line** (a mocked `_chat_completion` captures every prompt; asserts the seed and `otpauth://` never appear), `permissions_json` round-trip, additive migration on a legacy-shaped SQLite DB.
- `server/tests/test_dashboard.py` — dashboard shell (`/` redirect + HTML), records inventory (strength verdicts, reuse flags, plaintext never echoed), dashboard permission updates + audit, security review (weak/reuse/stale findings without leaking secrets), organization report, audit ingest redaction (**query text must never reach the audit log**), `/api/ai/status` configuration states, AI gateway contract (503 unconfigured, 400 malformed/stream, server-model enforcement, usage audit, upstream failure → 502 + denied event).
- `mcp-server/test_secretbox_mcp.py` — three-level access resolution (matrix + legacy boolean), metadata-only records visible but clipboard tools refuse, matrix-denied invisible, RFC 6238 vector for the stdlib generator, `copy_totp` clipboard-only + seed red line, redaction never contains the seed, optional audit reporting (off by default, payload shape, per-tool-call events, agent-name allowlist, link-local endpoint refusal).

Snapshot baselines: `editor-capture.png` re-recorded (capture sheet), new `totp-code.png` / `totp-code-masked.png` (a fixed reference date keeps the digits and ring deterministic).

Documentation screenshots: `SecretBoxTests/DocsScreenshotsTests` regenerates `docs/screenshots/*.png` from deterministic demo data (InMemoryRecordStore, fake credentials only). Run it after visual changes:

```bash
xcodebuild test -project SecretBox/SecretBox.xcodeproj -scheme SecretBox \
  -destination "platform=macOS" -derivedDataPath .derived \
  -only-testing:SecretBoxTests/DocsScreenshotsTests
```

## persona-200 scenario suite (server)

200 synthetic password-usage scenarios across six personas (SRE / developer / PM / designer / novice / admin). Runs the server app in-process against a throwaway SQLite DB:

```bash
python3 server/scripts/run_persona_suite.py
```

Writes `testsets/persona200/results_200.json` and `testsets/persona200/report.md`. See `testsets/persona200/README.md` for the dataset schema, generator split, and the latest findings.

## full project

Run app tests plus server tests with:

```bash
./scripts/test.sh
```
