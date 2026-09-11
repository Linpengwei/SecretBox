**English** · [简体中文](ROADMAP.zh-CN.md)

# SecretBox Roadmap

**English** · [简体中文](ROADMAP.zh-CN.md)

Current priority: **iOS first**. macOS features and backend capabilities are held at status quo (regression only); new phases focus on making the iOS target buildable, usable, and integration-testable.

Baseline (verified 2026-08-29):

- iOS build was failing: `RecordVaultView.swift` imported AppKit; `SecretBoxApp.swift` used the macOS-only `MenuBarExtra`.
- Xcode had the iOS 26.2 SDK but no iOS simulator runtime (no usable simulators).
- Server and macOS client feature-complete (see `server/README.md`, `TESTING.md`); auth was a fake login, keys in dev mode.

Baseline update (2026-09-08, verified at the close of phase MP):

- Phase 0 substantially complete: `scripts/test-ios.sh` exists and is green (iOS 26.3 runtime + iPhone 17 simulator).
- Snapshot infrastructure (`SnapshotLite.swift` / `ViewSnapshotTests.swift`) is gated with `#if canImport(AppKit)`, so the SecretBoxTests target builds on iOS.

## Phase 0: iOS compilation (complete)

1. Platform conditional compilation:
   - `SecretBoxApp.swift`: `MenuBarExtra` scene wrapped in `#if os(macOS)`; iOS uses the main window as the only entry.
   - `NSApp.activate(ignoringOtherApps:)` in `RecordVaultView.swift` guarded with `#if os(macOS)`.
   - `NSPasteboard.general` usage in `SecretBoxAppModel.swift` extracted into a cross-platform wrapper (`UIPasteboard` on iOS).
2. iOS simulator runtime installed.
3. `scripts/test-ios.sh`: unit tests plus the 50-sample classifier regression on the iOS Simulator destination.

Acceptance: `test-ios.sh` fully green; the three macOS scripts stay green.

## Phase MP: seamless MFA + Bitwarden-style permissions (complete)

Modeled on Bitwarden's Integrated Authenticator and granular access controls, delivered as one merged phase:

**MFA (per-item TOTP)**:

1. `TOTPEngine.swift`: RFC 6238 + RFC 4648 base32 + `otpauth://` Key URI parsing (SHA1/256/512, 6–8 digits, 15–120 s), injectable clock. Codes are generated entirely client-side; the server only stores/retrieves the seed.
2. Editor "两步验证" section: paste a base32 seed or a full URI (live parse preview; invalid input blocks saving); iOS camera scanning (macOS keeps manual entry); the seed is never echoed after saving.
3. Detail page live code: `TimelineView`-driven 30-second rotating code + countdown ring (the ring is the copy button, turns red under 5 s), placed right next to Copy Password; masked under `hideSecret`.
4. Quick-capture auto-detection: `otpauth://` in pasted text is extracted and attached (Smart Preview badges it); a URI-only paste creates an account-type authenticator entry.
5. Server sync: new `totp_encrypted` (Fernet ciphertext) column + migration branch; round-trips through create/update/search; request-level base32/parameter validation (invalid → 422); Key URIs in `pasted_text` are forcibly scrubbed server-side and routed to the encrypted column.

**Permissions (per-item matrix; multi-user lands in phase 2)**:

1. `RecordPermissions`: `readOnly` (lock), `hideSecret` (usable but never visible — Bitwarden Hide Passwords), `requireReauth` (biometric re-prompt — master-password re-prompt equivalent), `aiAccess` three levels (none/metadata/metadata_and_tools), plus a reserved `subjects` structure.
2. `aiReadable` boolean upgraded smoothly to three levels (`effectivePermissions` maps legacy data; saves write back a boolean mirror); editor permission section (toggles + AI segmented picker); detail page three-level AI Access menu.
3. Enforcement: readOnly locks edit/delete (unchecking it in the editor is the only unlock path); hideSecret zero plaintext echo; requireReauth gates password/code copying through `LAContext` (injectable `ReauthGate`).
4. MCP: three levels effective (none = indistinguishable from missing; metadata = redacted details only; metadata_and_tools = + `copy_password` / new `copy_totp`); pure-stdlib RFC 6238; the seed never enters agent context.
5. Server `permissions_json` sync (non-secret metadata, on par with fields_json); server-side enforcement waits for real auth in phase 2.

Security invariants (all test-covered): seed stored only as ciphertext, never in AI context / MCP output / fields_json; code generation client-only; `aiAccess=none` indistinguishable from missing; hideSecret zero echo; migrations preserve existing data.

## Phase 1: iOS usability (complete)

1. Compact-width layouts:
   - `VaultItemEditorView` restructured as scrollable form + pinned bottom action bar (VStack tail + keyboard avoidance + ultraThinMaterial); title/username/password stack on compact widths; `scrollDismissesKeyboard(.immediately)`; macOS keeps 760×560 with the row layout.
   - `SettingsView` adaptive width (520 fixed on macOS / `maxWidth: 560` on iOS) + ScrollView.
   - `SearchVaultView` on iOS: pushed detail gets a `navigationTitle`; results/detail dismiss the keyboard on scroll; status line became a floating bottom capsule (`ToolbarItem(placement: .status)` does not render on iPhone — a real usability defect).
   - `RecordVaultView` is a macOS menu-bar-only surface (referenced only by the UI-test panel on iOS) — no adaptation needed.
   - Fixed latent defects along the way: the keyboard-attached programmatic sheet-dismissal race (`dismissEditor` resigns first responder first); a self-recursion in the UI-test `activate` helper's macOS branch.
2. iOS UI smoke tests: step 4 added to `scripts/test-ios.sh`, 7 chains total (login / seeded search / capture sheet open / **capture→save→search→detail→copy-password full chain** / **otpauth capture→live code→copy** / **read-only lock blocks edit & delete** / settings sheet); the 4 menu-bar tests skip on iOS via `XCTSkip`.
3. Local mode (Keychain persistence) fully usable on iOS without a server.

Acceptance: the "paste capture → Smart Preview → save → search → copy" flow on an iPhone simulator — automated by `testCaptureSaveSearchDetailCopyFlow`.

## Phase 2: server integration & sync (next)

1. iOS networking: `NSLocalNetworkUsageDescription`, an ATS exception for local HTTP debugging, server URL in Settings.
2. Server `GET /api/records` (list pull); client-side local/remote sync and conflict strategy.
3. Real server authentication (login + token), replacing the fake login; client integration.
4. Multi-user permissions: Bitwarden-style collections/groups/roles (Owner/Admin/Manager/User) and per-collection grants (read-only / hide-password / edit) on top of the reserved `permissions.subjects` structure; the server starts enforcing permissions.

## Phase 3: productionization

1. Key governance: `ENCRYPTION_KEY` / `FINGERPRINT_KEY` env-only with rotation; move `server/secretbox.db` and the compose dev keys out of git.
2. Server `DELETE /api/records/{id}` + client delete UI.
3. iOS release prep: icon, launch screen, permission copy, TestFlight.

## Backlog

- Automating the `manual` samples from `server/docs/FREEFORM_SAMPLE_LIBRARY.md`.
- More parsers: JDBC, Oracle, SQLServer, redis sentinel, DigitalOcean Spaces, etc.
- HOTP (counter-based), Steam TOTP, macOS QR scanning.
- macOS-specific enhancements, visionOS.
