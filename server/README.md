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

Record payloads accept `totp` (`secret` base32 + `digits` 6–8 + `period` 15–120 + `algorithm` SHA1/SHA256/SHA512; invalid → 422) and `permissions`. On update, an absent `totp` keeps the stored seed and `remove_totp: true` clears it; search/create/update responses include the decrypted seed payload and permissions so clients can generate codes locally.

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

The app is for storing ops credentials such as:

- `redis`
- `s3`
- `database`
- `kafka`
- `custom`

## Freeform sample library

- Hand-test samples: `docs/FREEFORM_SAMPLE_LIBRARY.md`
