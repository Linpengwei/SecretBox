**English** · [简体中文](../README.zh-CN.md)

# SecretBox Server

## Security model

- Plaintext passwords are never sent to AI.
- The server stores everything in SQLite.
- The sensitive password field is stored as:
  - `encrypted_password`: reversible ciphertext for authorized retrieval.
  - `password_hash`: Argon2id hash for industry-standard slow hashing.
  - `password_fingerprint`: keyed HMAC-SHA256 fingerprint for exact-match lookup without exposing the original secret.
- TOTP seeds (two-step verification, phase MP) are secret-class data:
  - stored only as `totp_encrypted` (Fernet ciphertext of the seed payload); no hash or fingerprint is kept because the server never verifies TOTP codes and never searches by seed;
  - never enter `fields_json`, notes, or any redacted context;
  - `pasted_text` is scrubbed of `otpauth://` Key URIs before parsing — the URI is routed to the encrypted column (and stored as the record seed) instead of flowing toward the AI service.
- `permissions_json` holds the per-record permission matrix (read-only / hide-secret / re-auth / AI access level). It is non-secret metadata on par with `tags`, synchronized through the API; enforcement lives in the clients and the MCP server until the API gains real authentication (roadmap phase 2).
- AI receives only redacted context such as URL, username, note, storage snapshot, and password shape metadata.
- Search works in two modes:
  - semantic match over `description` and tags
  - exact keyed-hash match when the query string is the original password

## Run locally with Docker

```bash
cd server
docker compose up --build
```

The stack starts:

- FastAPI on `http://127.0.0.1:8000`
- SQLite database at `server/data/secretbox.db`

## API overview

- `GET /health`
- `GET /api/provider`
- `PUT /api/provider`
- `POST /api/records`
- `PUT /api/records/{record_id}` (supports `totp`, `remove_totp`, `permissions`)
- `POST /api/search`
- `GET /api/records` — inventory with per-record strength verdict (weak/fair/strong), reuse flags and TOTP status; never returns plaintext
- `PUT /api/records/{record_id}/permissions` — update the per-record permission matrix
- `GET /api/dashboard/overview` · `GET /api/dashboard/security` · `GET /api/dashboard/organization` — dashboard aggregates and the security-risk review (weak/reused/stale findings)
- `GET /api/audit` · `GET /api/audit/stats` · `POST /api/audit` — server-side audit trail; the ingest endpoint receives agent reports (e.g. MCP tool calls). Secret-shaped detail keys are redacted at ingest, and search queries are never stored (in exact-match mode the query IS the password)
- `GET /api/ai/status` — what clients probe to offer the "use server AI" option
- `POST /ai/v1/chat/completions` — OpenAI-compatible AI gateway passthrough; the server attaches its own upstream key and enforces the server-configured model. No streaming

Record payloads accept `totp` (`secret` base32 + `digits` 6–8 + `period` 15–120 + `algorithm` SHA1/SHA256/SHA512; invalid → 422) and `permissions`. On update, an absent `totp` keeps the stored seed and `remove_totp: true` clears it; search/create/update responses include the decrypted seed payload and permissions so clients can generate codes locally.

## Ops dashboard

Visit `http://127.0.0.1:8000/dashboard` (the root path redirects there). Single-file UI, no external assets, five tabs:

- **Overview** — record/AI/audit stats, type & template distribution, top tags, 24h activity sparkline
- **Records & Permissions** — inventory with strength badges and a per-record permission-matrix editor (read-only / hide-secret / re-auth / AI access level)
- **Security Review** — heuristic strength scoring (length, charset, common passwords, keyboard runs, dates), reuse groups via password fingerprints, stale-password detection, TOTP coverage findings. Plaintext is decrypted in server memory to compute verdicts and never leaves the process
- **Agent Audit** — event stream from the server itself and from agents (`POST /api/audit`), with action/actor filters and hourly stats
- **AI Gateway** — provider configuration (upstream base URL / key / model), gateway status, and a live test prompt

## AI gateway

Clients (macOS/iOS app, scripts) send OpenAI-compatible chat requests to `POST /ai/v1/chat/completions`; the server forwards them to its configured upstream with the stored key. The key never leaves the server, and the server-side model is enforced for every call (clients cannot pick an arbitrary or costlier model). Each call is audit-logged with token usage. In the app this surfaces as the "Use server AI gateway" option in Settings → OpenAI-compatible provider, available once `GET /api/ai/status` reports `enabled`.

## Agent audit reporting (MCP)

The MCP server can forward every tool call to the server audit trail. Opt in via env (off by default):

```bash
SECRETBOX_SERVER_URL=http://127.0.0.1:8000
SECRETBOX_AGENT_NAME=claude-code
```

Reports are fire-and-forget (daemon thread, 2s timeout), carry no secrets (action, record id, outcome), and the URL is hardened (http/https only, link-local/cloud-metadata IPs refused, redirects refused).

## Seed demo data

```bash
cd server
python3 scripts/seed_demo.py
```

This creates demo records for:

- `redis`
- `s3`
- `database`
- `kafka`
- `account`

## Record intent

The app manages credentials of all kinds — ops templates such as those below, plus everyday accounts:

- `redis`
- `s3`
- `database`
- `kafka`
- `custom`

## Freeform sample library

- Hand-test samples: `docs/FREEFORM_SAMPLE_LIBRARY.md`
