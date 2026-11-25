**English** · [简体中文](AGENTS.zh-CN.md)

# SecretBox

AI-native password manager for teams and individuals — the vault between humans/AI agents and secrets (plaintext never enters agent context). Ops-native templates (redis, s3, database, kafka, custom) plus everyday accounts. Components:

- `SecretBox/` — SwiftUI app (SwiftUI AppKit menu-bar + windows, macOS and iOS), Xcode project at `SecretBox/SecretBox.xcodeproj`. App sources in `SecretBox/SecretBox/`, UI theme in `SecretBox/SecretBox/Docs/AppTheme.swift`.
- `server/` — FastAPI + SQLAlchemy + SQLite backend (`server/app/`), tests in `server/tests/`.
- `mcp-server/` — zero-dependency stdio MCP server.
- `MAUI/` — experimental Windows/Android client, frozen (see its README). No new features there; only keep its security defaults in step with the SwiftUI app.
- `.github/workflows/` — CI (`ci.yml`, on every push and pull request) and the advisory nightly (`nightly.yml`, the full macOS and iOS scripts).

## Tests / build

- `./scripts/test.sh` — everything: macOS app tests, Python lint, server and MCP pytest, and the persona-200 quality floors.
- `./scripts/test-macos.sh` — macOS regression suite (xcodebuild, scheme `SecretBox`, `platform=macOS`, derived data in `.derived/`): unit tests (model — including the 50-sample classifier regression — TOTP engine, view snapshots) and every UI test, one at a time with a retry. It refuses to start when a UI test is missing from its list.
- `./scripts/test-sample-set-macos.sh` — 50-sample classifier regression only.
- `./scripts/test-ios.sh` — iOS simulator unit tests + 50-sample regression + 7 UI smoke chains (`platform=iOS Simulator,name=iPhone 17`, derived data in `.derived-ios/`).
- Server tests: `cd server && python3 -m pytest tests` (deps in `server/requirements.txt`). They run against a throwaway database (`tests/conftest.py`). Never point them at a database you care about — several tests delete whole tables.
- Lint: `ruff check .` (config in `ruff.toml`; CI enforces it).
- MCP tests: `cd mcp-server && python3 -m pytest test_secretbox_mcp.py`.
- Run server locally: `cd server && docker compose up --build` — published on `127.0.0.1:8000` only, as an unprivileged user. Bare: `SECRETBOX_DEV=1 python3 -m uvicorn app.main:app`; without that variable the server refuses to start on the built-in development keys.
- Seed demo data: `cd server && python3 scripts/seed_demo.py`.
- Keep a few GB of disk free before running the macOS suite. Every test run writes result bundles of tens of MB under `.derived/Logs/Test/`, and on a nearly full disk the run fails in misleading ways — `xcodebuild` dying with `Trace/BPT trap`, or tests failing that have nothing wrong with them.
- If the app "won't open" (clicks do nothing): a leftover Xcode debug session has likely suspended the app process (a zombie instance still owns the bundle ID, so macOS only "activates" it). `./scripts/kill-stale-secretbox.sh` reaps it; the app also reaps frozen siblings at launch (see `SecretBoxApp.reapFrozenSiblingInstances`). Stop debug sessions with ⌘. when done.

See `TESTING.md` for details; note macOS UI tests may fail with `Sandbox restriction` / `testmanagerd` errors when not run from a normal Terminal or Xcode.

## Security model (critical for edits)

Read `server/README.md` before touching `server/app/security.py`, `ai.py`, `redaction.py`, `models.py`, or search logic. Invariants:

- **AI egress is a whitelist, not a redaction.** The model only ever receives fields whose key is in `AI_METADATA_FIELD_KEYS` (`server/app/redaction.py`; a test keeps it identical to the MCP server's `METADATA_FIELD_KEYS`), plus scrubbed name / notes / tags. Raw `pasted_text`, `source_excerpt`, and fields under any other key never enter a prompt. Model output is untrusted as well: secret-class keys it proposes are dropped.
- Free text derived from a paste is scrubbed before it is stored (`AIService.sanitize_free_text`): URI userinfo is removed, secret-class `key: value` pairs and natural-language secret phrases lose their value, and known secrets are removed in every encoded form. The scrub is name-based and therefore best-effort — never make a guarantee depend on it; the whitelist is the hard boundary.
- URL-type fields never carry credentials. A field whose key is secret-class is flagged `hidden`, so clients conceal it and the AI whitelist drops it.
- Search never falls back to unrelated records (results carry plaintext), and a query shaped like a pasted credential is ranked locally instead of being sent to the model.
- API views never include `password_hash` or `password_fingerprint`. Passwords are still stored three ways server-side (`encrypted_password`, Argon2id `password_hash`, keyed-HMAC `password_fingerprint`); nothing reads the Argon2 column, and it goes away with the auth phase.
- TOTP seeds (per-record two-step verification) are secret-class: server stores them only as `totp_encrypted` (Fernet ciphertext, no hash/fingerprint); they never enter `fields_json`, notes, AI context, or MCP output. Verification codes are generated client-side only — the server never generates or validates them. `pasted_text` is scrubbed of `otpauth://` URIs before parsing (server routes them to the encrypted column).
- `permissions_json` (per-record matrix: read-only / hide-secret / re-auth / AI access level `none|metadata|metadata_and_tools`) is non-secret metadata. Enforcement is client-side + MCP until the server has real auth; `aiAccess=none` must stay indistinguishable-from-missing in the MCP server.
- Search has two modes: semantic match over description/tags, and exact keyed-hash match when the query equals the original password.
- In the client, passwords and hidden fields are masked until the user reveals them (`displayedSecret` / `toggleSecretReveal`; revealing is a secret use and honors `requireReauth`). Secrets written to the clipboard are marked concealed and removed after 30 seconds. The one-click "Copy AI reference" escalation grants metadata only; tool access is a separate, explicit choice.
- Test hooks (`SECRETBOX_UI_TEST*`) exist in Debug builds only and can never reach the user's data: a UI-test launch gets an in-memory vault and a private preferences suite.

Do not weaken or bypass these boundaries in either the Swift client (`SecretBoxAPI.swift`) or the server.

## Current priority

Phase 0 (stop the bleeding) is done. Phase 1, one capture engine, is next — see `ROADMAP.md` for the full plan and what each phase must hold.

## Conventions

- Swift app uses a single xcodeproj with file-system-synchronized groups: a file saved into `SecretBox/SecretBox/` (or one of the test folders) belongs to its target at once — there is nothing to add to the project (no SPM for app code).
- Server is Python 3.10+ in `from __future__ import annotations` style, FastAPI dependency-injection via `get_db`; the Docker image runs 3.12.
- Classifier fixtures: the 50-sample list lives in `SecretBoxTests/SecretBoxAppModelTests.swift` (macOS and iOS regression); the server parser and search are measured by `testsets/persona200/` against the floors in `testsets/persona200/floors.json`. Phase 1 replaces both with one shared golden corpus.
- Never run `mcp-server/fuzzy_eval.py` against your real Keychain account: it swaps the real vault for a test vault and restores it only in a `finally`. Point `SECRETBOX_KEYCHAIN_ACCOUNT` at a dedicated account for evaluations.
- Every document has a 简体中文 counterpart (`.zh-CN.md`); change both.
- License: AGPL-3.0 + commercial dual licensing (see `README.md`). Submitting a contribution grants the project the right to publish it under both the AGPL-3.0 and the project's commercial license.
