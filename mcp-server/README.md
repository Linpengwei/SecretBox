**English** · [简体中文](../README.zh-CN.md)

# SecretBox MCP Server

**English** · [简体中文](README.zh-CN.md)

Exposes SecretBox vault queries to MCP (Model Context Protocol) agent CLIs: Claude Code / Claude Desktop, OpenAI Codex CLI, OpenCode.

## Security model (core promise)

**Plaintext passwords never enter the AI agent's context. TOTP seeds never do either (verification codes also go to the clipboard only).**

**Access control (set in the app, enforced by this server)**: every record carries an AI access level (detail-page AI Access menu / editor permission section), three levels, default **denied**:

- `none` — the record is completely invisible to agents: absent from search/list; id and copy lookups return exactly the same error as a missing record (no existence leak).
- `metadata` — agents may query redacted metadata, but `copy_password` / `copy_totp` refuse to serve.
- `metadata_and_tools` — full capability including clipboard copies.

The legacy boolean `aiReadable == true` maps automatically to `metadata_and_tools` (compatible with existing vault data). In-app changes take effect immediately.

| Tool | What the agent gets |
|---|---|
| `search_credentials(query)` | Redacted metadata of matching records (name/type/cluster/username/host/env/tags) |
| `list_credentials(limit)` | Redacted metadata list of the whole vault |
| `get_credential(record_id)` | Redacted metadata + password shape (length, character classes — never content) + the `ai_access` level |
| `copy_password(record_id)` | Only `{copied: true, record: ...}` (requires `metadata_and_tools`) |
| `copy_totp(record_id)` | Only `{copied: true, record: ...}` — the current 30-second verification code goes to the clipboard, the seed never appears (requires `metadata_and_tools` and a configured seed) |

## Reference-paste flow ("复制 AI 引用" button)

Every record's detail page has a **"复制 AI 引用"** button (next to Copy Password). The clipboard receives a *reference* instead of the plaintext, ready to paste into an agent chat:

```
<secretbox-credential id="…" name="Redis Production" type="redis" username="default" host="r-xx.internal:6379">
Resolve with the SecretBox MCP server: get_credential(record_id="…") for redacted details, copy_password(record_id="…") to place the secret on the clipboard. The plaintext secret is intentionally not included — never ask me to paste it.
</secretbox-credential>
```

- The reference carries only the `record_id` + redacted metadata; plaintext and secret-class fields are never written.
- The agent resolves by `record_id` directly — faster and more precise than fuzzy search.
- If the record's AI access is still "denied", the button offers a confirmation dialog first (enabling grants `metadata_and_tools`); otherwise the agent cannot see the record and the reference is unresolvable.
- Unit-tested: the reference never contains plaintext (`testAIReferenceIdentifiesRecordWithoutPlaintext` in SecretBoxAppModelTests).

- All responses pass through a unified redaction exit: secret-class field whitelist filtering + **embedded-credential URL scrubbing** (`redis://user:pass@host` → `redis://user:[REDACTED]@host`).
- Plaintext only ever transits two places: this process's memory and the macOS system clipboard. Humans obtain the password by pasting — "never in context, still accessible".
- `passwordHash` / `passwordFingerprint` / `source_excerpt` / secret-class signals never appear in responses.

## Data source

The SecretBox macOS app (non-sandboxed since Beta 3) stores the vault as a JSON blob in the **login Keychain** (service/account configurable via env). Reading it may prompt once for keychain access — choose "Always Allow".

Env overrides (strictly allowlisted):

- `SECRETBOX_KEYCHAIN_SERVICE` (default `Hendrix.SecretBox`)
- `SECRETBOX_KEYCHAIN_ACCOUNT` (default `localVault`)

## Setup

Run the registrar to configure Claude Code / Claude Desktop / Codex / OpenCode (backs up existing configs):

```bash
./scripts/setup-mcp.sh
```

## Tests & benchmarks

```bash
python3 -m pytest test_secretbox_mcp.py   # 29 tests incl. the security red lines
python3 bench_tools.py --real             # latency benchmarks
```
