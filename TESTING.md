**English** · [简体中文](TESTING.zh-CN.md)

# Testing

## Where each suite runs

| Suite | On every push (CI) | Locally |
|---|---|---|
| Server pytest | ✓ | `cd server && python3 -m pytest tests` |
| MCP server pytest | ✓ | `cd mcp-server && python3 -m pytest test_secretbox_mcp.py` |
| Lint (`ruff check .`) | ✓ | via `./scripts/test.sh` |
| persona-200 with quality floors | ✓ | `python3 server/scripts/run_persona_suite.py` |
| Dependency audit (pip-audit, advisory) | ✓ | — |
| macOS unit tests (model + capture golden + TOTP engine) | ✓ | `./scripts/test-macos.sh` |
| macOS view snapshots | — (baselines are machine-specific) | `./scripts/test-macos.sh` |
| macOS UI tests | nightly, advisory | `./scripts/test-macos.sh` |
| iOS simulator (unit + capture golden + 50-sample + 7 UI chains) | nightly, advisory | `./scripts/test-ios.sh` |

CI lives in `.github/workflows/` (`ci.yml`, `nightly.yml`). It was written in the phase 0 round and has not had a real run yet — the first push shows whether the hosted runners behave.

## macOS app

Run the macOS regression suite with:

```bash
./scripts/test-macos.sh
```

What it does:

- `build-for-testing`
- runs the unit suites: `SecretBoxAppModelTests` (which includes the 50-sample classifier regression), `CaptureParserGoldenTests`, `TOTPEngineTests`, `ViewSnapshotTests`
- runs `testDiverseFiftySampleSetPersistAndClassify` on its own
- runs every UI test in `SecretBoxUITests` one by one
- retries a UI test once if macOS automation times out
- refuses to start if a test in `SecretBoxUITests.swift` is missing from its list (the list once held 3 of 14)

On macOS, 11 UI tests run and 3 are skipped: `testCaptureSaveSearchDetailCopyFlow`, `testCaptureWithOTPAuthShowsLiveCodeAndCopies` and `testReadOnlyPermissionLocksEditing` drive the iPhone navigation (back button, swipe scrolling) and run in the iOS script.

**Test isolation.** A UI-test launch (`SECRETBOX_UI_TEST=1`) gets an in-memory vault and a private preferences suite, and the test hooks are compiled out of release builds. Before phase 0, the UI-tested app opened the real Keychain item and cleared it on every launch — verified: the UI-tested process carries `SECRETBOX_UI_TEST=1` but not `XCTestConfigurationFilePath`, which is what the old store selection keyed on. After the change, some thirty UI-test launches left the real vault item and the real preferences byte-for-byte unchanged.

If you see `Sandbox restriction` or `testmanagerd.control was invalidated`, the app tests were blocked by the current execution environment. Run the script from a normal local Terminal or from Xcode.

Also quit any running SecretBox instance first: a second live instance of the same bundle ID (e.g. the Release app left open) confuses XCUITest's accessibility snapshots and makes the UI tests fail with element-matching errors.

**Keep a few GB of disk free.** Each test run writes a result bundle of tens of MB under `.derived/Logs/Test/`. On a nearly full disk the run fails in misleading ways: `xcodebuild` dies with `Trace/BPT trap`, the database-backed suites fail with disk errors, and tests fail that have nothing wrong with them.

### Current state of the macOS UI tests (2026-11-26)

The complete `./scripts/test-macos.sh` passes: **11 macOS UI tests pass and 3 iPhone-navigation tests are skipped**, alongside the build, all unit/golden/TOTP/snapshot suites and the 50-sample regression. The UI phase now uses an explicit native-architecture destination (`platform=macOS,arch=$(uname -m)`), avoiding the earlier multiple-destination automation initialization timeout.

The earlier failures were fixed at their actual boundaries: preview queries use `menubar.preview` as a `ScrollView`; the preview model no longer truncates fields before the view's expand/collapse logic; status text checks both accessibility `label` and `value`; the macOS Settings button exposes `toolbar.settings` and the test handles its nested match; the quick-capture presentation wait is 15 seconds. `testMenuBarSmokeFlowCanSaveAndOpenDashboard`'s stale title expectation was corrected earlier.

**Snapshot tolerance is 2 % of pixels.** A changed caption or a masked password changes far less than that and passes unnoticed — `editor-capture` kept passing after its caption was rewritten. Treat snapshots as layout checks; behavior that matters is asserted at the model level (for example `displayedSecret` / `toggleSecretReveal` for password masking).

## iOS simulator

```bash
./scripts/test-ios.sh
```

Verifies an iOS simulator runtime exists, then on `iPhone 17`: `build-for-testing` → unit tests → 50-sample classifier regression → **7 UI smoke chains** (login / seeded search / capture sheet / capture→save→search→detail→copy-password / otpauth capture→live TOTP code→copy / read-only permission lock / settings sheet). Menu-bar tests skip on iOS via `XCTSkip`. The snapshot suite (`ViewSnapshotTests` + `SnapshotLite`) is macOS-only and compiles out on iOS via `#if canImport(AppKit)`.

The capture/model unit suites and `CaptureParserGoldenTests` have now run on the iOS simulator and pass. All seven UI smoke chains also pass in this round. The quick-capture test waits up to 15 seconds for the sheet to appear because the 5-second wait raced presentation; an accessibility-hierarchy check confirmed the sheet and fields were present. The iOS-only AppKit import and `Duration` conversion issues found by the build are fixed; macOS behavior is unchanged.

UI-test notes: sheets that hold text input get their keyboard dismissed (scroll on `editor.scroll`) before tapping pinned action buttons — taps can silently drop while the keyboard-avoidance animation is live; `focusAndType` retries focus until the keyboard appears.

## Security coverage

- `SecretBoxTests/CaptureParserGoldenTests.swift` — the shared 341-case corpus (303 positive, 38 negative): primary and secondary secrets, templates, zero leaks/false positives, and twenty byte-identical structured-output runs, all executed in detached tasks off the main actor. Regenerate the JSON with `python3 testsets/build_capture_golden.py`; add new edge cases to `testsets/capture_edge_cases.json`, not directly to the generated file.
- `SecretBoxTests/TOTPEngineTests.swift` — RFC 6238 Appendix B vectors (SHA1 8-digit set, SHA256, 6-digit truncation), base32 tolerance matrix, `otpauth://` parsing matrix (minimal/full/invalid/hotp-rejected), period boundary rotation, `secondsRemaining` invariants.
- `SecretBoxAppModelTests.swift` — TOTP round-trips, permission persistence, read-only lock, `ReauthGate` injection, AI access levels (the legacy `aiReadable` mirror is fail-closed: metadata-only does not set it), menu-bar quick access, and the phase 0 additions: zero-signal and tied pastes classify deterministically, an empty vault never surfaces demo records outside UI tests, secrets are masked until revealed and a denied gate keeps them masked, editing or deleting a record masks again, copied secrets are marked concealed and clear themselves without clobbering a later copy, vault blobs from older builds still decode.
- `server/tests/test_redaction.py` — the AI red line as a whitelist: six real leak shapes (multi-secret paste, percent-encoded URI password, `.env` block, natural-language handoff, JDBC URL, glued code) assert that no secret reaches storage or any prompt; model output cannot introduce secret-class fields; a credential-shaped query never reaches the model; no-match search returns nothing; API views carry no hash or fingerprint; startup re-scrub; the server and MCP allowlists are identical.
- `server/tests/test_hardening.py` — development keys need an explicit opt-in; unsafe upstream URLs are refused (metadata, link-local, tunnelled spellings); gateway and audit ingest rate limits; request body cap; CSP pins the dashboard's inline script by hash; cross-origin browser reads are refused by default.
- `server/tests/test_api.py`, `test_dashboard.py` — TOTP ciphertext-only storage, permission round-trips, dashboard endpoints, audit redaction, AI gateway contract.
- `mcp-server/test_secretbox_mcp.py` — three-level access resolution, RFC 6238 vector for the stdlib generator, `copy_totp` clipboard-only + seed red line, optional audit reporting.
- `mcp-server/fuzzy_eval.py` — five real-agent fuzzy scenarios against a dedicated synthetic Keychain account: 5/5 passed, including denied-record invisibility, clipboard correctness and no transcript secret leakage. The account was restored after the run.
- `testsets/persona200/` — 200 paste-and-search scenarios; `floors.json` holds the headline metrics the suite must not fall below.
- `server/tests/test_capture_golden.py` — frozen server extraction floors plus the absolute scrub and idempotence invariants over the same 341-case corpus. Negative cases are excluded from the frozen parser's extraction counts; the app engine owns the zero-false-positive requirement.

## Snapshot baselines

`SecretBoxTests/__Snapshots__/ViewSnapshotTests/`: `login-light`, `login-dark`, `editor-capture`, `menu-bar-capture`, `menu-bar-search`, `search-seeded`, `totp-code`, `totp-code-masked`, and `detail-secret-masked` (the detail pane's masked password row). A missing baseline is recorded and the test fails once; rerun to compare.

## Documentation screenshots

`SecretBoxTests/DocsScreenshotsTests` renders `docs/screenshots/*.png` from deterministic demo data (InMemoryRecordStore, fake credentials only) when `SECRETBOX_DOCS_RENDER=1` is set. The committed images are real-app Retina captures, so the generator does not overwrite them by default.

On 2026-11-26 `vault-main.png` and `quick-capture.png` were regenerated from isolated demo data. The password is masked until revealed and the capture preview uses the current wording. The other pre-existing captures were restored; only these two files changed.

## persona-200 scenario suite (server)

200 synthetic password-usage scenarios across six personas (SRE / developer / PM / designer / novice / admin). Runs the server app in-process against a throwaway SQLite DB:

```bash
python3 server/scripts/run_persona_suite.py
```

Writes `testsets/persona200/results_200.json` and `report.md`, and fails when a headline metric is below `testsets/persona200/floors.json` (`--no-floors` skips the check). See `testsets/persona200/README.md` for the dataset schema, generator split, and the latest findings.

## Server tests and your database

`server/tests/conftest.py` points the suite at a throwaway database and accepts the development keys. Several tests delete whole tables; before phase 0 they did that to `server/secretbox.db`. Do not override `DATABASE_URL` with a database you care about.

## Full project

```bash
./scripts/test.sh
```

macOS suite, lint, server and MCP pytest, and the persona-200 floors.
