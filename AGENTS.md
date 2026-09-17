**English** · [简体中文](AGENTS.zh-CN.md)

# SecretBox

AI-native password manager for teams and individuals — the vault between humans/AI agents and secrets (plaintext never enters agent context). Ops-native templates (redis, s3, database, kafka, custom) plus everyday accounts. Two components:

- `SecretBox/` — SwiftUI app (SwiftUI AppKit menu-bar + windows, macOS destination), Xcode project at `SecretBox/SecretBox.xcodeproj`. App sources in `SecretBox/SecretBox/`, UI theme in `SecretBox/SecretBox/Docs/AppTheme.swift`.
- `server/` — FastAPI + SQLAlchemy + SQLite backend (`server/app/`), tests in `server/tests/`.

## Tests / build

- `./scripts/test.sh` — everything: macOS app tests + server pytest.
- `./scripts/test-macos.sh` — app regression suite (xcodebuild, scheme `SecretBox`, `platform=macOS`, derived data in `.derived/`).
- `./scripts/test-sample-set-macos.sh` — 50-sample classifier regression only.
- `./scripts/test-ios.sh` — iOS simulator unit tests + 50-sample regression (`platform=iOS Simulator,name=iPhone 17`, derived data in `.derived-ios/`).
- Server tests: `cd server && python3 -m pytest tests` (deps in `server/requirements.txt`).
- MCP tests: `cd mcp-server && python3 -m pytest test_secretbox_mcp.py`.
- Run server locally: `cd server && docker compose up --build` (FastAPI on 127.0.0.1:8000).
- Seed demo data: `cd server && python3 scripts/seed_demo.py`.

See `TESTING.md` for details; note macOS UI tests may fail with `Sandbox restriction` / `testmanagerd` errors when not run from a normal Terminal or Xcode.

## Security model (critical for edits)

Read `server/README.md` before touching `server/app/security.py`, `models.py`, or search logic. Invariants:

- Plaintext passwords are never sent to the AI service; AI only sees redacted metadata (URL, username, note, password shape).
- Passwords are stored three ways: `encrypted_password` (reversible ciphertext), `password_hash` (Argon2id), `password_fingerprint` (keyed HMAC-SHA256 for exact-match search).
- TOTP seeds (per-record two-step verification) are secret-class: server stores them only as `totp_encrypted` (Fernet ciphertext, no hash/fingerprint); they never enter `fields_json`, notes, AI context, or MCP output. Verification codes are generated client-side only — the server never generates or validates them. `pasted_text` is scrubbed of `otpauth://` URIs before parsing (server routes them to the encrypted column).
- `permissions_json` (per-record matrix: read-only / hide-secret / re-auth / AI access level `none|metadata|metadata_and_tools`) is non-secret metadata. Enforcement is client-side + MCP until the server has real auth; `aiAccess=none` must stay indistinguishable-from-missing in the MCP server.
- Search has two modes: semantic match over description/tags, and exact keyed-hash match when the query equals the original password.

Do not weaken or bypass these boundaries in either the Swift client (`SecretBoxAPI.swift`) or the server.

## Current priority

iOS first — see `ROADMAP.md` for phase plan (Phases 0, MP, 1, and the macOS menu-bar round MB done; next is Phase 2: server integration & sync).

## Conventions

- Swift app uses a single xcodeproj; new source files must be added to the project/targets (no SPM for app code).
- Server is Python 3, `from __future__ import annotations` style, FastAPI dependency-injection via `get_db`.
- Sample data / classifier fixtures: `server/docs/diverse_fifty_samples.json` (used by the macOS sample-set regression test).
- License: AGPL-3.0 + commercial dual licensing (see `README.md`). Submitting a contribution grants the project the right to publish it under both the AGPL-3.0 and the project's commercial license.
