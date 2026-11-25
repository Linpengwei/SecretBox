"""Secret redaction helpers shared by the parser, the storage path and the AI
egress boundary.

Two independent guards keep plaintext out of stored free text and out of AI
context:

- `AIService.sanitize_free_text` scrubs text derived from a paste: URI userinfo
  is removed structurally, secret-class `key: value` pairs and natural-language
  secret phrases lose their value, and known secrets are removed in every
  encoded form.
- `AI_METADATA_FIELD_KEYS` is the only set of field keys the AI service may
  ever see. Everything else is dropped before a prompt is built, whatever a
  client or the parser put into `fields`.

The scrub is name-based and therefore best-effort; the whitelist is the hard
boundary. Anything that must never leak relies on the whitelist, never on the
scrub alone.
"""
from __future__ import annotations

import re
from urllib.parse import quote, quote_plus, unquote

REDACTED = "[REDACTED]"

# Field keys the AI service may see. Mirrors METADATA_FIELD_KEYS in
# mcp-server/secretbox_mcp.py — test_ai_metadata_whitelist_matches_mcp_server
# keeps the two lists in step.
AI_METADATA_FIELD_KEYS = frozenset(
    {
        "host", "hostname", "port", "url", "endpoint", "s3_endpoint", "brokers",
        "database", "dbname", "db", "bucket", "topic", "queue", "vhost",
        "scope", "project", "tenant", "env", "environment", "namespace", "stage",
        "region", "aws_default_region", "provider", "cloud", "engine", "driver",
        "mechanism", "sasl_mechanism", "service", "label", "site", "app",
        "cluster", "username", "user", "login", "account", "email",
        "sasl_username", "access_key", "ak", "aws_access_key_id",
    }
)

# A `_`-separated token of a field key that marks the value as secret-class.
_SECRET_KEY_TOKENS = frozenset(
    {
        "password", "passwd", "passphrase", "passcode", "pwd", "secret",
        "token", "credential", "apikey", "seed", "otp", "cvv", "cvc", "pin",
        "salt", "signature", "auth", "private", "license", "cookie",
    }
)
# "...key" is secret-class unless the name says it identifies a key rather than
# carrying one (access keys are identifiers and stay visible metadata).
_KEY_IDENTIFIER_TOKENS = frozenset({"access", "id", "public", "pub", "name", "path", "type", "ring"})
_SECRET_KEY_CJK_MARKERS = (
    "密码", "密碼", "口令", "密钥", "秘钥", "私钥", "令牌", "凭据",
    "授权码", "激活码", "提取码", "兑换码", "卡密", "购买码", "验证码", "安全码",
)

# `scheme://userinfo@` — the userinfo (username and password) is dropped as a
# unit; the username already lives in its own field, the secret in the
# protected column. Greedy up to the last `@` so unencoded `@` inside a
# password does not leave a tail behind, and stopped by `/ ? #` so `?email=`
# query strings are never mistaken for credentials.
_URI_USERINFO_RE = re.compile(r"\b([a-z][a-z0-9+.\-]*://)[^/\s?#\"'<>]+@", re.IGNORECASE)


def is_secret_key(key: str | None) -> bool:
    """True when a field key name marks its value as secret-class."""
    if not key:
        return False
    lowered = key.strip().lower()
    if any(marker in lowered for marker in _SECRET_KEY_CJK_MARKERS):
        return True
    tokens = {token for token in re.split(r"[^a-z0-9]+", lowered) if token}
    if tokens & _SECRET_KEY_TOKENS or "sk" in tokens:
        return True
    return "key" in tokens and not tokens & _KEY_IDENTIFIER_TOKENS


def strip_uri_credentials(text: str) -> str:
    """Remove the userinfo from every `scheme://user:password@host` URI."""
    return _URI_USERINFO_RE.sub(r"\1", text)


def secret_variants(secret: str) -> set[str]:
    """The spellings a secret can take inside text: raw, percent-encoded and
    percent-decoded (a URI carries `p%40ss` for the password `p@ss`)."""
    if not secret:
        return set()
    return {
        variant
        for variant in (secret, quote(secret, safe=""), quote_plus(secret, safe=""), unquote(secret))
        if variant
    }


def redact_known_secrets(text: str, *secrets: str | None) -> str:
    """Replace every occurrence of the given secrets, in any encoded form."""
    variants: set[str] = set()
    for secret in secrets:
        variants |= secret_variants(secret or "")
    for variant in sorted(variants, key=len, reverse=True):
        if variant in text:
            text = text.replace(variant, REDACTED)
    return text
