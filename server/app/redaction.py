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

# Substrings that mark a key as secret-class wherever they occur in one of
# its words ("ScriptPassphrase", "aws_secret_access_key", "serial_number").
_SECRET_KEY_MARKERS = (
    "passw", "passcode", "passphrase", "pincode", "secret", "token",
    "credential", "license", "licence", "serial", "signature", "cookie",
    "private",
)
# Words that are secret-class only as a whole word. "laptop" is not an OTP,
# "keynote" is not a key, "author" is not an auth.
_SECRET_KEY_WORDS = frozenset(
    {"pwd", "otp", "cvv", "cvc", "salt", "seed", "auth", "pass", "pin", "sk", "wifi"}
)
# "...key" is secret-class unless the name says it identifies a key rather than
# carrying one (access keys are identifiers and stay visible metadata).
_KEY_IDENTIFIER_WORDS = frozenset({"access", "id", "public", "pub", "name", "path", "type", "ring"})
# "...code" likewise: a postal or country code is not a license code.
_CODE_IDENTIFIER_WORDS = frozenset(
    {
        "postal", "country", "region", "area", "zip", "status", "error",
        "http", "state", "response", "currency", "locale", "sort", "color",
        "promo", "discount", "tax",
    }
)
_SECRET_KEY_CJK_MARKERS = (
    "密码", "密碼", "口令", "密钥", "秘钥", "私钥", "金钥", "金鑰", "令牌", "凭据",
    "授权码", "激活码", "提取码", "兑换码", "卡密", "购买码", "验证码", "安全码",
    "序列号", "序列號",
)
_CAMEL_BOUNDARY_RE = re.compile(r"(?<=[a-z0-9])(?=[A-Z])")
_NON_WORD_RE = re.compile(r"[^a-z0-9]+")


def key_words(key: str) -> set[str]:
    """The words of a key, read both ways: split at word boundaries only
    ("WiFi" -> "wifi") and additionally at camelCase boundaries ("AuthToken"
    -> "auth", "token"). Either reading may be the meaningful one, so the
    rule set is tested against the union."""
    split = _CAMEL_BOUNDARY_RE.sub("_", key.strip()).lower()
    plain = key.strip().lower()
    return {word for text in (split, plain) for word in _NON_WORD_RE.split(text) if word}


def is_secret_key(key: str | None) -> bool:
    """True when a key name marks its value as secret-class. A secret under a
    label nobody thought of is the failure this rule exists to prevent, so it
    is biased towards "yes": the cost of a false positive is a concealed
    field, the cost of a false negative is a leaked secret."""
    if not key:
        return False
    lowered = key.strip().lower()
    if any(marker in lowered for marker in _SECRET_KEY_CJK_MARKERS):
        return True
    words = key_words(key)
    if any(marker in word for word in words for marker in _SECRET_KEY_MARKERS):
        return True
    if words & _SECRET_KEY_WORDS:
        return True
    if "key" in words and not words & _KEY_IDENTIFIER_WORDS:
        return True
    return "code" in words and not words & _CODE_IDENTIFIER_WORDS


# `scheme://userinfo@` — the userinfo (username and password) is dropped as a
# unit; the username already lives in its own field, the secret in the
# protected column. Greedy up to the last `@` so unencoded `@` inside a
# password does not leave a tail behind, and stopped by `/ ?` so a query
# string is never mistaken for credentials. `#` is allowed inside the
# userinfo: a raw one can only occur there ("redis://u:Redis#2026@host" is
# common in practice), and excluding it made the strip a two-pass affair.
_URI_USERINFO_RE = re.compile(r"\b([a-z][a-z0-9+.\-]*://)[^/\s?\"'<>]+@", re.IGNORECASE)
# A whole URI. Stopped by whitespace and by CJK sentence punctuation, which
# the prose around a pasted URI routinely supplies.
_URI_RE = re.compile(r"\b[a-z][a-z0-9+.\-]*://[^\s，。；！？]+", re.IGNORECASE)
_URI_PARAM_RE = re.compile(r"([?&;])([^=?&#]+)=([^&#]*)")
# `--password=…`, `-p …` as in `docker login -u user -p secret`. Several tools
# use `-p` for a port, so a purely numeric value after the short flag is left
# alone. The separator is its own group so the text keeps its spacing.
_CLI_LONG_SECRET_FLAG_RE = re.compile(
    r"(?:(?<=\s)|^)(--?(?:password|passwd|pwd|passphrase|token|secret|key))([ \t]+|=)(\"[^\"]*\"|'[^']*'|[^\s]+)",
    re.IGNORECASE,
)
_CLI_SHORT_PASSWORD_RE = re.compile(
    r"(?:(?<=\s)|^)(-p)([ \t]+|=)(?!\d+(?:\s|$))(\"[^\"]*\"|'[^']*'|[^\s]+)", re.IGNORECASE
)


def strip_uri_credentials(text: str) -> str:
    """Remove the userinfo from every `scheme://user:password@host` URI."""
    return _URI_USERINFO_RE.sub(r"\1", text)


def redact_uri_params(text: str) -> str:
    """Inside every URI, blank the value of secret-class query parameters
    (`s3://bucket?aws_secret_access_key=…`). URIs are handled before the
    general key/value scan: read as one `key: value` pair, `s3://…` makes the
    scheme the key and the entire rest of the URI a single value, so nothing
    inside it would ever be inspected."""
    return _URI_RE.sub(
        lambda uri: _URI_PARAM_RE.sub(
            lambda param: f"{param.group(1)}{param.group(2)}={REDACTED}" if is_secret_key(param.group(2)) else param.group(0),
            uri.group(0),
        ),
        text,
    )


def redact_cli_secret_flags(text: str) -> str:
    """Blank the value of a password flag on a command line."""
    text = _CLI_LONG_SECRET_FLAG_RE.sub(lambda m: f"{m.group(1)}{m.group(2)}{REDACTED}", text)
    return _CLI_SHORT_PASSWORD_RE.sub(lambda m: f"{m.group(1)}{m.group(2)}{REDACTED}", text)


def uri_spans(text: str) -> list[tuple[int, int]]:
    """Where the URIs are in `text`, for callers that must not read a URI as
    ordinary prose."""
    return [uri.span() for uri in _URI_RE.finditer(text)]


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
