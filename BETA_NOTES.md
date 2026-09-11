**English** · [简体中文](BETA_NOTES.zh-CN.md)

# SecretBox macOS Beta Notes

**English** · [简体中文](BETA_NOTES.zh-CN.md)

## Beta 5 (2026-08-29)

- Build date: 2026-08-29; artifact `beta/SecretBox-v1.0-beta5-macos.zip` (Release, ad-hoc signed; not in the public repo)
- Source: main working tree including uncommitted fixes (see the Chinese notes for the full Beta 1→5 changelog)

### Manual acceptance checklist

1. Launch & login — any non-empty credentials (local demo login, no server auth yet)
2. Menu-bar quick capture — paste a credential snippet (samples in `server/docs/FREEFORM_SAMPLE_LIBRARY.md`), check the Smart Preview, save
3. Main-window search — keyword search, detail panes (Cluster Schema / Detected Context / Secret)
4. Copy password
5. Edit & re-cluster
6. Delete record (local only)
7. No plaintext under `~/Library/Containers/Hendrix.SecretBox/` (vault lives in the Keychain)
8. AI Organize wand
9. Settings — Server toggle (default off)

### Known limitations

- Login is a local demo; the server has no authentication
- Delete is local-only (no server DELETE endpoint yet)
- `ENCRYPTION_KEY` / `FINGERPRINT_KEY` are development defaults
- Keep Server mode off for beta testing; the server is not hardened

### Test status (2026-08-29)

| Suite | Result |
|---|---|
| Unit tests (SecretBoxAppModelTests) | 41/41 pass (macOS) |
| View snapshots (4 cases / 5 baselines) | pass |
| 50-sample classifier regression | pass (macOS + iOS simulator) |
| Release build + launch/quit | pass |
| UI automation (3 smoke chains) | blocked in sandboxed environments (testmanagerd timeout) — verify locally |

## Phase MP changes (2026-09-08, MFA + permissions, not yet packaged as a beta)

- **Per-item TOTP seamless MFA** (Bitwarden Integrated Authenticator equivalent): editor 两步验证 section (base32 seed / `otpauth://` URI / iOS QR scan; invalid input blocks saving; seed never echoed); detail-page live code with a 30-second countdown ring doubling as the copy button; quick-capture auto-detects `otpauth://` URIs; codes generated entirely client-side (RFC 6238 via CryptoKit).
- **Server TOTP sync**: new `totp_encrypted` (Fernet) column; create/update/search round-trips; Key URIs in `pasted_text` scrubbed server-side into the encrypted column (AI red line covered by a mocked-LLM test). Existing DBs migrate additively on startup.
- **Permission matrix** (Bitwarden-style granular access): read-only lock, hidden password, biometric re-prompt, three-level AI access; legacy `aiReadable` boolean auto-mapped with a mirror written back; MCP upgraded to five tools with levels + `copy_totp`; `permissions_json` synced (server-side enforcement awaits phase 2 auth).
- **iOS compilation fix**: snapshot infra gated with `#if canImport(AppKit)`; the test target now builds on iOS.
- **Test baselines**: server 38 pytest, MCP 29 pytest, macOS unit + snapshot (new `totp-code` / `totp-code-masked` baselines), iOS simulator unit + 50-sample regression all green.

## Phase 1 changes (2026-09-08, iOS usability)

- **Editor compact-layout rework**: scrollable form + pinned bottom action bar; stacked identity fields on compact widths; scroll-dismisses-keyboard; macOS unchanged (snapshot baselines untouched).
- **Settings adaptive width** (no more fixed 520 pt overflow on iPhone) + scrollable.
- **iOS detail page**: navigation title; status line as a floating bottom capsule (`.status` toolbar items never rendered on iPhone).
- **Latent-defect fixes**: keyboard-attached sheet-dismissal race (resign first responder first); the UI-test focus helper's macOS self-recursion.
- **iOS UI smoke suite**: step 4 added to `test-ios.sh` — 7 chains including the full capture→save→search→detail→copy flow; 4 menu-bar tests skip on iOS. All 11 macOS UI tests pass as well.

## Rollback

`git stash && git clean -fd beta/` returns to the initial state (removes untracked files — use with care).
