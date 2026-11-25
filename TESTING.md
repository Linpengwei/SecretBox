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
| macOS unit tests (model + TOTP engine) | ✓ | `./scripts/test-macos.sh` |
| macOS view snapshots | — (baselines are machine-specific) | `./scripts/test-macos.sh` |
| macOS UI tests | nightly, advisory | `./scripts/test-macos.sh` |
| iOS simulator (unit + 50-sample + 7 UI chains) | nightly, advisory | `./scripts/test-ios.sh` |

CI lives in `.github/workflows/` (`ci.yml`, `nightly.yml`). It was written in the phase 0 round and has not had a real run yet — the first push shows whether the hosted runners behave.

## macOS app

Run the macOS regression suite with:

```bash
./scripts/test-macos.sh
```

What it does:

- `build-for-testing`
- runs the unit suites: `SecretBoxAppModelTests` (which includes the 50-sample classifier regression), `TOTPEngineTests`, `ViewSnapshotTests`
- runs `testDiverseFiftySampleSetPersistAndClassify` on its own
- runs every UI test in `SecretBoxUITests` one by one
- retries a UI test once if macOS automation times out
- refuses to start if a test in `SecretBoxUITests.swift` is missing from its list (the list once held 3 of 14)

On macOS, 11 UI tests run and 3 are skipped: `testCaptureSaveSearchDetailCopyFlow`, `testCaptureWithOTPAuthShowsLiveCodeAndCopies` and `testReadOnlyPermissionLocksEditing` drive the iPhone navigation (back button, swipe scrolling) and run in the iOS script.

**Test isolation.** A UI-test launch (`SECRETBOX_UI_TEST=1`) gets an in-memory vault and a private preferences suite, and the test hooks are compiled out of release builds. Before phase 0, the UI-tested app opened the real Keychain item and cleared it on every launch — verified: the UI-tested process carries `SECRETBOX_UI_TEST=1` but not `XCTestConfigurationFilePath`, which is what the old store selection keyed on. After the change, some thirty UI-test launches left the real vault item and the real preferences byte-for-byte unchanged.

If you see `Sandbox restriction` or `testmanagerd.control was invalidated`, the app tests were blocked by the current execution environment. Run the script from a normal local Terminal or from Xcode.

Also quit any running SecretBox instance first: a second live instance of the same bundle ID (e.g. the Release app left open) confuses XCUITest's accessibility snapshots and makes the UI tests fail with element-matching errors.

**Keep a few GB of disk free.** Each test run writes a result bundle of tens of MB under `.derived/Logs/Test/`. On a nearly full disk the run fails in misleading ways: `xcodebuild` dies with `Trace/BPT trap`, the database-backed suites fail with disk errors, and tests fail that have nothing wrong with them.

### Known state of the macOS UI tests (2026-11-25)

Seven of the eleven fail — identically on the commit before phase 0 and after it, so phase 0 did not change their outcome:

- `testMenuBarPreviewCanEditAndSaveLocally`, `testMenuBarPreviewFieldOverrideCanSaveEditedHost`, `testMenuBarPreviewFieldsCanExpand` — they look for `menubar.preview` as a generic "other" element; the compact panel exposes it as a scroll view.
- `testMenuBarSearchCopiesSeededPasswordOnReturn`, `testMenuBarCaptureSavesWithCommandReturn` — the confirmation text after ↩ / ⌘↩ never appeared.
- `testSettingsSheetOpensAndCloses` — the Settings toolbar button was not found.

They were recorded as passing in September 2026. Whether they still pass from a normal Terminal or Xcode session was **not verified**: the session that produced these numbers could not keep the app under test frontmost. Run the script yourself before relying on these areas. If they fail for you too, they are regressions from the November UI changes and need fixing — start with the element types and labels the tests query.

`testMenuBarSmokeFlowCanSaveAndOpenDashboard` had a stale expectation (`"REDIS"`; the parser titles the record `"REDIS cache.internal"`) and failed on every run while being written off as flaky. The expectation is corrected.

**Snapshot tolerance is 2 % of pixels.** A changed caption or a masked password changes far less than that and passes unnoticed — `editor-capture` kept passing after its caption was rewritten. Treat snapshots as layout checks; behavior that matters is asserted at the model level (for example `displayedSecret` / `toggleSecretReveal` for password masking).

## iOS simulator

```bash
./scripts/test-ios.sh
```

Verifies an iOS simulator runtime exists, then on `iPhone 17`: `build-for-testing` → unit tests → 50-sample classifier regression → **7 UI smoke chains** (login / seeded search / capture sheet / capture→save→search→detail→copy-password / otpauth capture→live TOTP code→copy / read-only permission lock / settings sheet). Menu-bar tests skip on iOS via `XCTSkip`. The snapshot suite (`ViewSnapshotTests` + `SnapshotLite`) is macOS-only and compiles out on iOS via `#if canImport(AppKit)`.

The phase 0 round did not re-run this script: there was not enough free disk for a second build. The iOS-facing changes in it are small (clipboard expiration through `UIPasteboard.setItems`, the reveal toggle in the detail pane) and are covered by the shared model tests, but the simulator run is still owed.

UI-test notes: sheets that hold text input get their keyboard dismissed (scroll on `editor.scroll`) before tapping pinned action buttons — taps can silently drop while the keyboard-avoidance animation is live; `focusAndType` retries focus until the keyboard appears.

## Security coverage

- `SecretBoxTests/TOTPEngineTests.swift` — RFC 6238 Appendix B vectors (SHA1 8-digit set, SHA256, 6-digit truncation), base32 tolerance matrix, `otpauth://` parsing matrix (minimal/full/invalid/hotp-rejected), period boundary rotation, `secondsRemaining` invariants.
- `SecretBoxAppModelTests.swift` — TOTP round-trips, permission persistence, read-only lock, `ReauthGate` injection, AI access levels (the legacy `aiReadable` mirror is fail-closed: metadata-only does not set it), menu-bar quick access, and the phase 0 additions: zero-signal and tied pastes classify deterministically, an empty vault never surfaces demo records outside UI tests, secrets are masked until revealed and a denied gate keeps them masked, editing or deleting a record masks again, copied secrets are marked concealed and clear themselves without clobbering a later copy, vault blobs from older builds still decode.
- `server/tests/test_redaction.py` — the AI red line as a whitelist: six real leak shapes (multi-secret paste, percent-encoded URI password, `.env` block, natural-language handoff, JDBC URL, glued code) assert that no secret reaches storage or any prompt; model output cannot introduce secret-class fields; a credential-shaped query never reaches the model; no-match search returns nothing; API views carry no hash or fingerprint; startup re-scrub; the server and MCP allowlists are identical.
- `server/tests/test_hardening.py` — development keys need an explicit opt-in; unsafe upstream URLs are refused (metadata, link-local, tunnelled spellings); gateway and audit ingest rate limits; request body cap; CSP pins the dashboard's inline script by hash; cross-origin browser reads are refused by default.
- `server/tests/test_api.py`, `test_dashboard.py` — TOTP ciphertext-only storage, permission round-trips, dashboard endpoints, audit redaction, AI gateway contract.
- `mcp-server/test_secretbox_mcp.py` — three-level access resolution, RFC 6238 vector for the stdlib generator, `copy_totp` clipboard-only + seed red line, optional audit reporting.
- `testsets/persona200/` — 200 paste-and-search scenarios; `floors.json` holds the headline metrics the suite must not fall below.

## Snapshot baselines

`SecretBoxTests/__Snapshots__/ViewSnapshotTests/`: `login-light`, `login-dark`, `editor-capture`, `menu-bar-capture`, `menu-bar-search`, `search-seeded`, `totp-code`, `totp-code-masked`, and `detail-secret-masked` (the detail pane's masked password row). A missing baseline is recorded and the test fails once; rerun to compare.

## Documentation screenshots

`SecretBoxTests/DocsScreenshotsTests` renders `docs/screenshots/*.png` from deterministic demo data (InMemoryRecordStore, fake credentials only) when `SECRETBOX_DOCS_RENDER=1` is set. The committed images are real-app Retina captures, so the generator does not overwrite them by default.

After phase 0 two captures no longer match the app: `vault-main.png` shows the password in the clear (it is masked until revealed now), and `quick-capture.png` shows the old wording under "Open to AI reading". Re-capture them from the running app.

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
