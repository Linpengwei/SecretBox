**English** · [简体中文](ROADMAP.zh-CN.md)

# SecretBox Roadmap

Replanned on 2026-11-25 after an architecture review. The review's verdict: the project kept adding surface — the dashboard, the AI gateway, the menu bar, a MAUI client — faster than it consolidated foundations. Three structural problems drive the plan:

1. **The path most users are on is the weakest one.** Local-only capture in the app is what runs by default, and it extracted the expected password for 32 % of the 200-scenario corpus (the server parser: 97 %). It also filed records into a cluster chosen by dictionary order, so the same paste landed in a different cluster on a different launch. The capture logic exists three times (Swift, Python, C#), and the server's parser fixes were never ported to the client.
2. **"Plaintext never reaches the AI service" held only for the inputs that had been tested.** A multi-secret paste, a percent-encoded URI password and a whole `.env` block all reached the model.
3. **The server has no authentication, and "server mode" is already a half-built sync** — write-through and server search, no pull, local-only delete.

The phases below fix the foundations first. The earlier phases (iOS compilation, MFA and permissions, iOS usability, menu bar) are kept at the end as history.

## Decisions (2026-11-25)

- **MAUI is frozen and marked experimental.** No new features; only its security defaults are kept in step with the SwiftUI app. Windows/Android is reconsidered once the local broker protocol of phase 5 is stable.
- **End-to-end encryption starts with secrets only.** Passwords, TOTP seeds and concealed fields are encrypted client-side; metadata stays readable by the server so semantic search and the dashboard do not have to be rebuilt. Full zero-knowledge is a later decision.
- **Agent secret use needs approval each time by default**, with a remember-per-agent-and-record option.
- **First audience: SREs and developers** with operations credentials. Everyday-account conveniences such as AutoFill come in phase 6.

## The plan

| Phase | Theme | One engineer, rough | Depends on |
|---|---|---|---|
| 0 | Stop the bleeding | ~1 week | — |
| 1 | One capture engine | ~2 weeks | — |
| 2 | Lock and local security baseline | ~1.5 weeks | can run alongside 1 |
| 3 | Accounts, tenancy, server hardening | ~2–3 weeks | 0 |
| 4 | End-to-end encryption and sync | ~3–4 weeks | 1, 2, 3 |
| 5 | Agent access 2.0 | ~2–3 weeks | 2, 3 |
| 6 | Ship | ongoing | 3 |

The old roadmap's "Phase 2" maps to phases 3 and 4 here; its "Phase 3" items move as follows: key governance and the `DELETE` endpoint to phase 3, iOS release preparation to phase 6.

## Phase 0 — stop the bleeding (done, 2026-11-25)

**Server**

- Search never falls back to unrelated records; a query that matches nothing returns nothing.
- AI egress is a whitelist (`AI_METADATA_FIELD_KEYS`, kept identical to the MCP server's list by a test). Raw `pasted_text` and `source_excerpt` never enter a prompt; model output is filtered on the way back.
- Free text derived from a paste is scrubbed before storage — URI userinfo, secret-class `key: value` pairs, natural-language secret phrases, known secrets in every encoded form — and URL fields never carry credentials. A secret-class field key is flagged `hidden`.
- A query shaped like a pasted credential is ranked locally, never sent to the model.
- API views no longer include `password_hash` or `password_fingerprint`.
- Compose publishes on `127.0.0.1` only; the container runs as an unprivileged user with a health check.
- Startup refuses the built-in development keys without `SECRETBOX_DEV=1`; stored records are re-scrubbed with the current field rules on every start.
- Cross-origin browser reads are refused by default (with `allow_origins=["*"]` any web page could read `/api/search`, which returns plaintext).
- Upstream URLs are validated (metadata, link-local and tunnelled targets refused); the AI gateway and audit ingest are rate-limited; request bodies are capped at 1 MiB; the dashboard is served with a CSP that pins its own inline script by hash.

**Client**

- UI tests no longer touch the real vault or preferences: a UI-test launch gets an in-memory vault and a private preferences suite, and the test hooks exist in Debug builds only. Before, every UI-test launch cleared the real Keychain item.
- Cluster assignment is deterministic: ties go to the more specific cluster in a fixed order, and a paste with no recognizable signal stays unclassified.
- Demo records are visible in UI tests only — a real user with an empty vault no longer sees a fake "Prod S3 Bucket".
- The one-click "Copy AI reference" escalation and the capture sheet's "Open to AI reading" grant metadata only; the legacy `aiReadable` mirror is fail-closed.
- Passwords and hidden fields are masked until the user reveals them; revealing honors `requireReauth`, and saving or deleting a record masks again.
- A copied password or verification code is marked concealed and removed from the clipboard after 30 seconds, unless something else was copied in the meantime.
- The client no longer requires the server's hash and fingerprint fields.

**Engineering**

- CI (`.github/workflows/ci.yml`): server and MCP pytest, lint, persona-200 floors and an advisory dependency audit on Linux; macOS unit tests on every push. A nightly job runs the full macOS and iOS scripts, advisory.
- `scripts/test-macos.sh` runs every UI test and refuses to start when one is missing from its list; `scripts/test.sh` also runs lint, the MCP tests and the persona floors.
- `ruff` is configured (`ruff.toml`) and the Python side is clean.
- Server tests run against a throwaway database (`tests/conftest.py`).
- The persona-200 suite has quality floors (`testsets/persona200/floors.json`).

**How it was verified**

- Server pytest: 124 pass (38 before; one of those was already failing on the previous commit because the dashboard had been redesigned). MCP pytest: 34 pass.
- persona-200, heuristic path, unchanged apart from one corrected false positive: paste-parse 186, secret round-trip 194, template 183, semantic 166 (all equal to the previous run); exact search 194 instead of 195 — the missing hit was a record the removed fallback had returned for a query that matched nothing.
- The container was built and run: unprivileged user, loopback-only publication (the LAN address refused connections), writable data directory, health check passing, startup refusing the development keys without the opt-in.
- The CSP was checked in a real browser: the dashboard loads, and injected inline handlers, inline scripts, remote scripts and cross-origin fetches are all blocked.
- macOS unit tests: 76 model (including the 50-sample regression, run five times in separate processes to rule out ordering flakiness) and 10 TOTP; 8 view snapshots.
- UI tests were run against both this tree and the previous commit in the same session. Every test has the same outcome on both, except `testMenuBarSmokeFlowCanSaveAndOpenDashboard`, whose stale expectation was corrected and which now passes. Seven of the eleven macOS UI tests fail on both; see `TESTING.md`.

**What phase 0 deliberately left alone**

- Parser behavior. Thirteen corpus scenarios still extract no secret or the wrong one on a pure paste (a value glued to the rest of the sentence after a full-width comma, truncation at `!`, unrecognized labels such as `redis_auth`, `pass`, `序列号`, `secret_access_key`). That is phase 1's work, measured against the same corpus.
- Authentication. The server is still open to whoever can reach it; loopback binding is containment, not a fix. An optional shared token was considered and dropped: behind Docker's port publishing the server cannot tell loopback from LAN, and a token enforced only on the server would break the dashboard and the app.
- The dependency baseline. `pip-audit` reports no known vulnerabilities in the project's dependencies. The newest FastAPI and SQLAlchemy require Python 3.11, and the local default interpreter is 3.10 — the upgrade belongs with the server rework of phase 3.
- The MCP server's own clipboard writes (`pbcopy` without concealment or clearing) and its direct Keychain access. Both are replaced by the broker in phase 5.

**Carried over, by phase**

- Phase 1: `mcp-server/fuzzy_eval.py` now defaults to the dedicated `secretbox-fuzzy-eval` Keychain account and refuses `localVault`; the backup/restore remains in a `finally`. The app uploads structured captures in server mode and applies Smart Preview corrections through the same parse used for display and storage.
- Phase 1/2: resolved — all 11 macOS UI tests pass and the three iPhone navigation flows are covered by the seven passing iOS UI smoke chains. The macOS script now selects the native architecture explicitly.
- Phase 2: the record model has one protected secret slot; a `hidden` field is concealed in the app but still stored in plaintext.
- Phase 3: the dashboard renders through 16 `innerHTML` sinks with an escape helper — audit them and add tests before accounts exist; the Argon2 `password_hash` column is written and never read.
- Any time: the two documentation screenshots (`vault-main.png`, `quick-capture.png`) were regenerated from isolated demo data on 2026-11-26 and now match the masked-secret and current Smart Preview UI. The snapshot tolerance of 2 % still cannot see text-level changes.

## Phase 1 — one capture engine (complete, 2026-11-26)

**Goal.** The app captures what the server parser captures, every launch the same way, and there is one implementation to change.

- Extract parsing and classification out of `SecretBoxAppModel` into pure, deterministic, non-main-actor code: `CaptureParser` (text → structured record), with an explicit "unclassified" outcome.
- Port what the server parser already does and the client lacks: Chinese keys, full-width punctuation, natural-language phrases, bare passwords, percent-decoding of URI passwords, empty-username URIs, JDBC URLs, and values that must stop at sentence punctuation.
- Produce structured records instead of one secret plus free text: several secret slots per record, and context made of labeled fields rather than an excerpt.
- Replace both fixtures with one shared golden corpus (`testsets/capture_golden.json`: the 200 scenarios plus the 50 samples, authored shapes, and held-out/adversarial cases) that XCTest, pytest and the xUnit suite all read.
- In server mode the app uploads structured records and never raw paste text; the server's parser stops being on the write path.
- The scrubbed excerpt stays only as long as search needs it; recall is measured before it is removed.
- Point `fuzzy_eval.py` and any other evaluation at a dedicated Keychain account.

**Acceptance.** On the golden corpus the macOS and iOS app reach at least the server parser's numbers — paste-parse ≥ 93 %, correct secret ≥ 97 % — and twenty runs produce byte-identical output. The server's persona floors do not drop.

**Must hold.** Nothing a user corrects in the preview is discarded; a secret under any label is never stored as an ordinary field or sent to the model.

**Delivered.** `CaptureRules`, `CaptureExtraction`, `CaptureClassification` and `CaptureParser` are the single app engine, called by preview, local save, editor reclassification and organization. The shared corpus now has 341 cases: 303 positive and 38 negative (200 persona + 50 classifier + 13 authored + 78 held-out/adversarial). The app reaches 303/303 primary secrets, 302/303 templates, 8/8 secondary-secret cases, zero leaks and zero false positives; twenty complete structured-output runs are byte-identical on macOS and iOS. `CaptureParserGoldenTests` runs the corpus off the main actor. The server keeps a frozen parser for compatibility, with extraction floors 279/267/291; its scrub passes all 341 cases and is idempotent. One template miss remains: NOVI-037 is an access-account/secret-key paste whose S3-vs-account label is ambiguous.

Excerpt removal was measured against 1,676 real corpus queries: dropping `source_excerpt` loses 371 hits (22.1%), including 371 of 396 excerpt-only queries. It is therefore retained deliberately, with `testSourceExcerptKeepsFreeTextSearchRecall` guarding the behavior. All 11 macOS UI tests pass (3 iPhone-navigation tests are skipped) and all seven iOS UI smoke chains pass. The two documentation screenshots have been regenerated from isolated demo data. Full server tests (144), MCP tests (34), Ruff, and the persona-200 floors pass.

## Phase 2 — lock and local security baseline

- Unlock on launch with the device credential (Touch ID, Apple Watch, passcode) guarding the vault key through Keychain access control; an optional master password for multi-device use later; auto-lock, redaction in the app switcher, sign-out.
- Encrypt the vault at rest with a random key and AES-GCM, replacing the single plaintext Keychain blob; migrate existing data transparently.
- Move from one blob to SQLite with one row per record, as the sync engine's substrate.
- Concealed custom fields and a password generator.

**Acceptance.** A cold launch requires unlock; no plaintext secret is findable on disk or in Keychain; existing users migrate without loss.

## Phase 3 — accounts, tenancy, server hardening

- Users, sessions, organizations and memberships; sign-in (Argon2 + TOTP, OIDC and passkeys later); API tokens that are hashed at rest, revocable and scoped.
- Every record belongs to an owner or an organization, and permissions are enforced by the server.
- `DELETE` with trash and tombstones; incremental record pull; Alembic migrations; structured logs that never contain secrets; audit actors taken from the session instead of a forgeable header.
- A real sign-in in the app, replacing the demo login.
- A written threat model: what is guaranteed, against whom, and what is not.
- The dependency refresh and the Python 3.11 baseline, and the dashboard rendering audit.

**Acceptance.** Anonymous requests get `401`; the authorization matrix has integration tests; the dashboard requires a session.

## Phase 4 — end-to-end encryption and sync

- Passwords, TOTP seeds and concealed fields are encrypted client-side with a per-record key; fingerprints are computed client-side with a user-held key (today, typing a password into search sends it to the server in plaintext just to compute the fingerprint).
- A sync engine: outbox, cursor-based pull, per-record versions, tombstones, a deterministic conflict policy.
- Strength verdicts and reuse groups are computed on the client and synced as conclusions.
- Existing server records are re-uploaded encrypted once, after which the plaintext columns are dropped.

**Acceptance.** A scan of the server database finds no known plaintext secret; two devices converge; offline edits are not lost.

## Phase 5 — agent access 2.0

- A broker inside the app (XPC or a Unix socket) owns the vault and the keys; the MCP server becomes a thin client with an agent identity.
- Each secret use is approved by the user by default, rememberable per agent and record; the broker writes the clipboard and clears it.
- A transcript-leak test: a scripted agent exercises every MCP tool, and the test asserts that no secret substring appears in its output.
- The app runs sandboxed, which makes the App Store possible; `secretbox run -- <cmd>` injects a secret into a child process's environment for terminal agents.

**Acceptance.** `security find-generic-password` can no longer read any plaintext; an unapproved agent obtains no bytes.

## Phase 6 — ship

Developer ID signing and notarization, TestFlight, importers (1Password / Bitwarden / KeePass), AutoFill, breach detection, the sharing interface, item history.

## On hold

- MAUI features; only security-default parity.
- Dashboard and AI gateway features.
- New templates and new parsers outside the one capture engine.
- Full zero-knowledge (encrypting metadata as well).
- Sync ahead of authentication and encryption.

## History — completed phases (kept for reference)

### Old phase 0: iOS compilation (complete)

1. Platform conditional compilation:
   - `SecretBoxApp.swift`: `MenuBarExtra` scene wrapped in `#if os(macOS)`; iOS uses the main window as the only entry.
   - `NSApp.activate(ignoringOtherApps:)` in `RecordVaultView.swift` guarded with `#if os(macOS)`.
   - `NSPasteboard.general` usage in `SecretBoxAppModel.swift` extracted into a cross-platform wrapper (`UIPasteboard` on iOS).
2. iOS simulator runtime installed.
3. `scripts/test-ios.sh`: unit tests plus the 50-sample classifier regression on the iOS Simulator destination.

Acceptance: `test-ios.sh` fully green; the three macOS scripts stay green.

### Phase MP: seamless MFA + Bitwarden-style permissions (complete)

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

### Old phase 1: iOS usability (complete)

1. Compact-width layouts:
   - `VaultItemEditorView` restructured as scrollable form + pinned bottom action bar (VStack tail + keyboard avoidance + ultraThinMaterial); title/username/password stack on compact widths; `scrollDismissesKeyboard(.immediately)`; macOS keeps 760×560 with the row layout.
   - `SettingsView` adaptive width (520 fixed on macOS / `maxWidth: 560` on iOS) + ScrollView.
   - `SearchVaultView` on iOS: pushed detail gets a `navigationTitle`; results/detail dismiss the keyboard on scroll; status line became a floating bottom capsule (`ToolbarItem(placement: .status)` does not render on iPhone — a real usability defect).
   - `RecordVaultView` is a macOS menu-bar-only surface (referenced only by the UI-test panel on iOS) — no adaptation needed.
   - Fixed latent defects along the way: the keyboard-attached programmatic sheet-dismissal race (`dismissEditor` resigns first responder first); a self-recursion in the UI-test `activate` helper's macOS branch.
2. iOS UI smoke tests: step 4 added to `scripts/test-ios.sh`, 7 chains total (login / seeded search / capture sheet open / **capture→save→search→detail→copy-password full chain** / **otpauth capture→live code→copy** / **read-only lock blocks edit & delete** / settings sheet); the 4 menu-bar tests skip on iOS via `XCTSkip`.
3. Local mode (Keychain persistence) fully usable on iOS without a server.

Acceptance: the "paste capture → Smart Preview → save → search → copy" flow on an iPhone simulator — automated by `testCaptureSaveSearchDetailCopyFlow`.

### Phase MB: macOS menu bar display & interaction (complete)

A focused macOS round (2026-09-12), the one deliberate detour from the iOS-first priority:

1. Panel restructure (`RecordVaultView` compact card): compact header (app identity + record count + icon button opening the Dashboard, replacing the full-width button), a 捕获/检索 segmented mode switch (persisted via AppStorage; UI-test runs pin it through `SECRETBOX_UI_TEST_MENU_BAR_MODE` so the suite stays hermetic), width 290 → 320 with adaptive height.
2. Quick access (检索) mode: auto-focused search field reusing the local ranked scorer (`quickAccessResults`, capped at 8); ↑/↓ selection with scroll-into-view; ↩ runs the primary action — copy the password, or the TOTP code for authenticator-only items; ⌘↩ reveals the record in the main window (`revealRecordInDashboard`). Row hover actions: copy password / copy TOTP / copy AI reference (offered only for agent-visible records) / open in Dashboard. Empty query shows the recent list (last 5 uses, record ids persisted in UserDefaults); a transient capsule confirms every copy/save.
3. Capture mode: 保存 stays disabled until a secret or `otpauth://` URI is detected (with an inline hint); ⌘↩ / ⌘S save; "Saved · {title}" feedback; Smart Preview capped at 250 pt with its own scroll.
4. Security invariants unchanged: every quick copy passes `requestSecretUse` (requireReauth → LAContext); hideSecret records copy but never display; `aiAccess=none` records expose no AI-reference action; recents persist ids only.

Tests: model unit tests (ranking + cap, recent dedupe/eviction/reload, reauth gating, TOTP copy, save enablement, reveal); two new snapshot baselines (`menu-bar-capture`, `menu-bar-search`); three new macOS UI chains (search → ↩ copy with clipboard assertion, search → ⌘↩ reveal, capture → ⌘↩ save) alongside the four existing menu-bar tests.

## Backlog

- Automating the `manual` samples from `server/docs/FREEFORM_SAMPLE_LIBRARY.md` into the golden corpus.
- More parsers: Oracle, SQLServer, redis sentinel, DigitalOcean Spaces, JDBC — all inside the one capture engine.
- HOTP (counter-based), Steam TOTP, macOS QR scanning.
- Adapting the three iPhone navigation flows to the macOS layout.
- visionOS.
