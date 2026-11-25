**English** · [简体中文](README.zh-CN.md)

# SecretBox Server

## Development state — read this first

The server has **no authentication**. Every endpoint is open to whoever can reach it, and `/api/search` returns plaintext. Until the auth phase of `ROADMAP.md` lands, three things keep the default deployment from being an open relay:

- It is published on `127.0.0.1:8000` only (`docker-compose.yml`). Do not rebind it to another interface on a network you do not control.
- It refuses to start on the built-in development keys unless `SECRETBOX_DEV=1` says you know.
- Cross-origin browser reads are refused by default, so no web page in the operator's browser can read its responses. `SECRETBOX_CORS_ORIGINS` is an explicit allowlist.

## Security model

**AI egress is a whitelist, not a redaction.** The model only ever receives fields whose key is in `AI_METADATA_FIELD_KEYS` (`app/redaction.py`; a test keeps it identical to the MCP server's `METADATA_FIELD_KEYS`), plus scrubbed name, notes and tags. Raw `pasted_text`, `source_excerpt`, and fields under any other key never enter a prompt. Model output is untrusted too: a secret-class key it proposes is dropped, and every value it returns is scrubbed.

**Free text derived from a paste is scrubbed before it is stored** (`AIService.sanitize_free_text`): URI userinfo is removed structurally, secret-class `key: value` pairs (ASCII and Chinese keys, half- and full-width separators) and natural-language secret phrases lose their value, and known secrets are removed in every encoded form (raw, percent-encoded, decoded). The scrub is name-based and therefore best-effort. Never make a guarantee depend on it — the whitelist is the hard boundary.

The scrubbed excerpt is kept because search depends on it: on the 200-scenario corpus, removing it takes semantic recall from 166 to 85 hits. Replacing it with structured context is the capture-engine phase of the roadmap.

**URL-type fields never carry credentials.** Userinfo is stripped from every URL field, and no field may echo the primary secret in any encoded form. A field whose key is secret-class (a `client_secret`, an `sk`, a PIN…) is flagged `hidden`: clients conceal it and the AI whitelist drops it. Its value is still stored as sent — the record model has one protected secret slot until the end-to-end-encryption phase.

**Search** has two modes: semantic match over `description`, title, tags and fields, and exact keyed-hash match when the query equals the original password. There is deliberately no "return something anyway" fallback — results carry plaintext, so a query that matches nothing returns nothing. A query shaped like a pasted credential (one long token mixing character classes) is ranked locally and never sent to the model.

**Storage.** Passwords are stored three ways: `encrypted_password` (reversible ciphertext), `password_hash` (Argon2id), `password_fingerprint` (keyed HMAC-SHA256 for exact-match search and reuse detection). API views never include the hash or the fingerprint; nothing reads the Argon2 column.

**TOTP seeds** (per-record two-step verification) are secret-class: stored only as `totp_encrypted` (Fernet ciphertext of the seed payload; no hash or fingerprint, because the server never verifies codes and never searches by seed). They never enter `fields_json`, notes, any redacted context, or MCP output. `pasted_text` is scrubbed of `otpauth://` Key URIs before parsing — the URI is routed to the encrypted column instead of flowing toward the AI service. Verification codes are generated client-side only.

**`permissions_json`** holds the per-record permission matrix (read-only / hide-secret / re-auth / AI access level). It is non-secret metadata, enforced by the clients and the MCP server until the API has authentication.

**Request-path guards** (`app/hardening.py`):

- Development keys: startup fails unless `SECRETBOX_DEV=1` or both keys are set.
- Upstream URL: `PUT /api/provider` refuses anything that is not an `http`/`https` URL without embedded credentials, and any target that resolves to link-local, metadata, unspecified, multicast or reserved space (IPv4-mapped and 6to4 spellings included). Loopback and private networks stay allowed: self-hosted model servers are a supported upstream. The gateway re-checks the stored URL (literals only) before every forward.
- Rate limits, per client: 60 requests per minute on `POST /ai/v1/chat/completions` (it spends the operator's upstream budget), 600 on `POST /api/audit` (it can flood the audit trail). `SECRETBOX_RATE_LIMIT=0` disables them.
- Request bodies above 1 MiB are refused with `413`.
- Every response carries a Content-Security-Policy (`default-src 'self'`; the dashboard's inline script is allowed by hash; `object-src`, `base-uri` and `frame-ancestors` locked down), `X-Content-Type-Options`, `X-Frame-Options` and `Referrer-Policy`.

**Startup maintenance** (`app/maintenance.py`): on every start, the write-path field rules are re-applied to stored records, so excerpts written before the structural scrub existed lose any secondary secret or percent-encoded URI password they still carried. Hand-written notes are never rewritten. The pass is idempotent.

**What this is not.** There are still no accounts, no tenancy and no transport security; non-secret-class fields are still plaintext at rest; the server can still decrypt every secret; and the scrub will not catch a secret hidden under a label nobody thought of. Those are the auth and end-to-end-encryption phases.

## Run locally

```bash
cd server
docker compose up --build
```

The stack starts:

- FastAPI on `http://127.0.0.1:8000`, published on loopback only, as an unprivileged user (uid 10001)
- SQLite database at `server/data/secretbox.db`

On Linux hosts, the bind-mounted `data/` directory must be writable by uid 10001 (`chown 10001:10001 data`); macOS file sharing does not enforce this.

Bare, without Docker:

```bash
cd server
pip install -r requirements.txt
SECRETBOX_DEV=1 python3 -m uvicorn app.main:app   # development keys; omit the variable once real keys are set
```

### Configuration

| Variable | Default | Purpose |
|---|---|---|
| `DATABASE_URL` | `sqlite:///./secretbox.db` | SQLite location (compose: `/app/data/secretbox.db`) |
| `ENCRYPTION_KEY` | built-in development key | Fernet key for `encrypted_password` and `totp_encrypted`. Records are bound to the key they were written with. |
| `FINGERPRINT_KEY` | built-in development key | Keyed HMAC for exact-match search and reuse detection. Changing it invalidates existing fingerprints. |
| `SECRETBOX_DEV` | unset | `1` accepts the built-in development keys. |
| `SECRETBOX_CORS_ORIGINS` | empty | Comma-separated origins allowed to make cross-origin browser requests. |
| `SECRETBOX_RATE_LIMIT` | `1` | `0` disables the per-client request limits. |
| `AI_TIMEOUT_SECONDS` | `20` | Upstream timeout for enrichment and reranking. |

The compose file carries its own development keys, which differ from the built-in ones: the same `data/` directory is not readable across the two setups. Do not change them on an existing `data/` directory.

## API overview

- `GET /health`
- `GET /api/provider`
- `PUT /api/provider` — `422` for an upstream URL that fails validation
- `POST /api/records`
- `PUT /api/records/{record_id}` (supports `totp`, `remove_totp`, `permissions`)
- `POST /api/search` — an empty `results` array when nothing matches
- `GET /api/records` — inventory with per-record strength verdict (weak/fair/strong), reuse flags and TOTP status; never returns plaintext
- `PUT /api/records/{record_id}/permissions` — update the per-record permission matrix
- `GET /api/dashboard/overview` · `GET /api/dashboard/security` · `GET /api/dashboard/organization` — dashboard aggregates and the security-risk review (weak/reused/stale findings)
- `GET /api/audit` · `GET /api/audit/stats` · `POST /api/audit` — server-side audit trail; the ingest endpoint receives agent reports (e.g. MCP tool calls). Secret-shaped detail keys are redacted at ingest, and search queries are never stored (in exact-match mode the query IS the password)
- `GET /api/ai/status` — what clients probe to offer the "use server AI" option
- `POST /ai/v1/chat/completions` — OpenAI-compatible AI gateway passthrough; the server attaches its own upstream key and enforces the server-configured model. No streaming; `429` when rate-limited

Record payloads accept `totp` (`secret` base32 + `digits` 6–8 + `period` 15–120 + `algorithm` SHA1/SHA256/SHA512; invalid → 422) and `permissions`. On update, an absent `totp` keeps the stored seed and `remove_totp: true` clears it; search/create/update responses include the decrypted seed payload and permissions so clients can generate codes locally. Item views carry `id`, `item_type`, `template_type`, `name`, `subtitle`, `notes`, `tags`, `fields`, `primary_secret` (when requested), `totp`, `permissions` — and no password hash or fingerprint.

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

## Tests

```bash
cd server && python3 -m pytest tests
```

The suite runs against a throwaway database (`tests/conftest.py`) and never touches `secretbox.db` — several tests delete whole tables. The red lines above are asserted in `tests/test_redaction.py` (stored free text and AI egress) and `tests/test_hardening.py` (startup guard, upstream validation, limits, headers).

Parser and search quality are measured by the persona-200 suite, which fails when a headline metric drops below its recorded floor:

```bash
python3 server/scripts/run_persona_suite.py            # writes testsets/persona200/results_200.json and report.md
```

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
