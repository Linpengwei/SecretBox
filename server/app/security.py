from __future__ import annotations

import base64
import hashlib
import hmac
import json
import re
from dataclasses import dataclass
from urllib.parse import parse_qs, unquote, urlparse

from argon2 import PasswordHasher
from cryptography.fernet import Fernet

from .config import settings

password_hasher = PasswordHasher()
fernet = Fernet(settings.encryption_key.encode("utf-8"))

# otpauth:// Key URIs carry the TOTP seed in clear; any occurrence in pasted
# text must be routed to the encrypted column, never into AI context.
_TOTP_URI_PATTERN = re.compile(r"otpauth://\S+", re.IGNORECASE)


@dataclass(slots=True)
class ProtectedSecret:
    encrypted_password: str
    password_hash: str
    password_fingerprint: str


def summarize_password_shape(password: str) -> dict[str, object]:
    return {
        "length": len(password),
        "has_upper": any(ch.isupper() for ch in password),
        "has_lower": any(ch.islower() for ch in password),
        "has_digit": any(ch.isdigit() for ch in password),
        "has_symbol": any(not ch.isalnum() for ch in password),
    }


def protect_password(password: str) -> ProtectedSecret:
    password_hash = password_hasher.hash(password)
    password_fingerprint = hmac.new(
        settings.fingerprint_key.encode("utf-8"),
        password.encode("utf-8"),
        hashlib.sha256,
    ).hexdigest()
    encrypted_password = fernet.encrypt(password.encode("utf-8")).decode("utf-8")
    return ProtectedSecret(
        encrypted_password=encrypted_password,
        password_hash=password_hash,
        password_fingerprint=password_fingerprint,
    )


def decrypt_password(encrypted_password: str) -> str:
    return fernet.decrypt(encrypted_password.encode("utf-8")).decode("utf-8")


def query_fingerprint(query: str) -> str:
    return hmac.new(
        settings.fingerprint_key.encode("utf-8"),
        query.encode("utf-8"),
        hashlib.sha256,
    ).hexdigest()


def encrypt_totp(payload: dict[str, object]) -> str:
    """Fernet-encrypt a TOTP payload dict for the `totp_encrypted` column."""
    return fernet.encrypt(json.dumps(payload).encode("utf-8")).decode("utf-8")


def decrypt_totp(encrypted: str) -> dict[str, object] | None:
    try:
        return json.loads(fernet.decrypt(encrypted.encode("utf-8")).decode("utf-8"))
    except Exception:
        return None


def scrub_totp_uris(text: str) -> tuple[str, dict[str, object] | None]:
    """Strip every `otpauth://` Key URI from `text` so the seed cannot leak
    into stored notes/fields or the AI service. Returns the scrubbed text and
    (only for the first URI) a normalized payload dict ready for
    `encrypt_totp`; unparsable URIs are still removed from the text.
    """
    match = _TOTP_URI_PATTERN.search(text)
    if match is None:
        return text, None

    scrubbed = _TOTP_URI_PATTERN.sub("", text).strip()
    return (scrubbed if scrubbed else text), parse_totp_uri(match.group(0))


def parse_totp_uri(uri: str) -> dict[str, object] | None:
    """Parse a `otpauth://totp/...` Key URI into a TOTP payload dict.
    Counter-based hotp URIs and anything without a valid base32 secret are
    rejected (None)."""
    try:
        parsed = urlparse(uri)
    except ValueError:
        return None
    if parsed.scheme.lower() != "otpauth" or (parsed.hostname or "").lower() != "totp":
        return None

    label = unquote(parsed.path.lstrip("/"))
    issuer: str | None = None
    account: str | None = None
    if label:
        if ":" in label:
            issuer, _, account = label.partition(":")
            issuer = issuer or None
            account = account or None
        else:
            account = label

    query = parse_qs(parsed.query)
    secret = (query.get("secret") or [None])[0]
    if not secret:
        return None
    normalized = secret.replace(" ", "").replace("-", "").upper()
    padded = normalized + "=" * ((8 - len(normalized) % 8) % 8)
    try:
        base64.b32decode(padded)
    except Exception:
        return None

    def _int_param(name: str, default: int, low: int, high: int) -> int:
        try:
            value = int((query.get(name) or [default])[0])
        except (TypeError, ValueError):
            return default
        return value if low <= value <= high else default

    algorithm = ((query.get("algorithm") or ["SHA1"])[0] or "SHA1").upper()
    if algorithm not in {"SHA1", "SHA256", "SHA512"}:
        algorithm = "SHA1"

    return {
        "secret": normalized,
        "issuer": (query.get("issuer") or [issuer])[0] or issuer,
        "account": account,
        "digits": _int_param("digits", 6, 6, 8),
        "period": _int_param("period", 30, 15, 120),
        "algorithm": algorithm,
    }
