"""Startup and request-path hardening.

Everything here is cheap, dependency-free and fail-closed:

- `assert_production_keys` — refuse to start on the built-in development keys
  unless `SECRETBOX_DEV=1` says the operator knows.
- `assert_safe_upstream_url` — the AI provider base URL is operator input that
  the server later POSTs to with the stored API key. Cloud-metadata and
  link-local targets are refused before anything is stored.
- `SlidingWindowLimiter` — per-client request limits on the two endpoints that
  are trivial to abuse anonymously: the AI gateway (spends the operator's
  upstream budget) and the audit ingest (can flood the audit trail).
- `SecurityHeadersMiddleware` / `BodySizeLimitMiddleware` — a CSP pinned to
  the dashboard's own inline script, plus a request-body cap.
"""
from __future__ import annotations

import base64
import hashlib
import ipaddress
import logging
import re
import socket
import time
from collections import deque
from urllib.parse import urlsplit

from fastapi import HTTPException, Request
from starlette.datastructures import MutableHeaders
from starlette.responses import JSONResponse

from .config import DEV_ENCRYPTION_KEY, DEV_FINGERPRINT_KEY, settings

logger = logging.getLogger("secretbox.hardening")

MAX_REQUEST_BYTES = 1024 * 1024
MAX_TRACKED_CLIENTS = 10_000

# Hostnames that resolve to cloud instance-metadata services.
_METADATA_HOSTS = frozenset({"metadata.google.internal", "metadata.goog", "instance-data", "instance-data.ec2.internal"})

_INLINE_SCRIPT_RE = re.compile(r"<script(?P<attrs>[^>]*)>(?P<body>.*?)</script>", re.IGNORECASE | re.DOTALL)
_SCRIPT_SRC_RE = re.compile(r"\bsrc\s*=", re.IGNORECASE)


def assert_production_keys() -> None:
    """Raise unless the encryption / fingerprint keys are real, or the operator
    explicitly opted into the development defaults."""
    if settings.allow_dev_defaults:
        return
    if settings.encryption_key == DEV_ENCRYPTION_KEY or settings.fingerprint_key == DEV_FINGERPRINT_KEY:
        raise RuntimeError(
            "Refusing to start with the built-in development keys. Set ENCRYPTION_KEY and "
            "FINGERPRINT_KEY, or opt into development defaults with SECRETBOX_DEV=1."
        )


def assert_safe_upstream_url(url: str, *, resolve: bool = True) -> None:
    """Validate an AI provider base URL before it is stored and before it is
    ever requested. Loopback and private networks stay allowed on purpose:
    self-hosted model servers are a supported upstream.

    `resolve=False` skips DNS and checks literals only — for the request path,
    where a blocking lookup would stall the event loop and the row was already
    validated with DNS when it was stored."""
    parts = urlsplit(url)
    if parts.scheme not in {"http", "https"}:
        raise ValueError("Upstream base URL must use http or https.")
    if not parts.hostname:
        raise ValueError("Upstream base URL must include a host.")
    if parts.username or parts.password:
        raise ValueError("Upstream base URL must not embed credentials.")
    try:
        # Reading `.port` is what validates the port; the value itself is not used.
        _ = parts.port
    except ValueError as error:
        raise ValueError("Upstream base URL has an invalid port.") from error

    host = parts.hostname.strip("[]")
    if host.lower() in _METADATA_HOSTS:
        raise ValueError("Upstream base URL points at a cloud metadata service.")

    try:
        literal = ipaddress.ip_address(host.split("%", 1)[0])
    except ValueError:
        literal = None

    addresses: list[str]
    if literal is not None:
        addresses = [str(literal)]
    elif not resolve:
        return
    else:
        try:
            infos = socket.getaddrinfo(host, None)
        except OSError as error:
            raise ValueError(f"Upstream host cannot be resolved: {host}") from error
        addresses = [info[4][0] for info in infos]
    if not addresses:
        raise ValueError(f"Upstream host cannot be resolved: {host}")

    for address in addresses:
        ip = ipaddress.ip_address(address.split("%", 1)[0])
        # Tunnelled forms carry an IPv4 address inside; judge that address.
        while ip.version == 6 and (ip.ipv4_mapped or ip.sixtofour):
            ip = ip.ipv4_mapped or ip.sixtofour
        # `is_reserved` alone is not a reason to refuse: on some Python
        # versions it is also true for IPv6 loopback, a legitimate upstream.
        if ip.is_link_local or ip.is_unspecified or ip.is_multicast or (ip.is_reserved and not ip.is_loopback):
            raise ValueError("Upstream base URL points at a link-local or otherwise unusable address.")


class SlidingWindowLimiter:
    """Fixed-size sliding window per client key, in memory. Good enough for a
    single-process server; a multi-worker deployment needs a shared store."""

    def __init__(self, name: str, limit: int, window_seconds: float) -> None:
        self.name = name
        self.limit = limit
        self.window_seconds = window_seconds
        self._hits: dict[str, deque[float]] = {}

    def allow(self, key: str, now: float | None = None) -> bool:
        current = time.monotonic() if now is None else now
        if len(self._hits) > MAX_TRACKED_CLIENTS:
            self._evict(current)
        hits = self._hits.setdefault(key, deque())
        while hits and current - hits[0] > self.window_seconds:
            hits.popleft()
        if len(hits) >= self.limit:
            return False
        hits.append(current)
        return True

    def reset(self) -> None:
        self._hits.clear()

    def _evict(self, now: float) -> None:
        for key in [key for key, hits in self._hits.items() if not hits or now - hits[-1] > self.window_seconds]:
            del self._hits[key]
        if len(self._hits) > MAX_TRACKED_CLIENTS:
            self._hits.clear()


GATEWAY_LIMITER = SlidingWindowLimiter("ai_gateway", limit=60, window_seconds=60)
AUDIT_INGEST_LIMITER = SlidingWindowLimiter("audit_ingest", limit=600, window_seconds=60)


def _client_key(request: Request) -> str:
    return request.client.host if request.client else "unknown"


def _enforce(limiter: SlidingWindowLimiter, request: Request) -> None:
    if not settings.rate_limit_enabled:
        return
    key = _client_key(request)
    if not limiter.allow(key):
        logger.warning("rate limit exceeded: %s client=%s", limiter.name, key)
        raise HTTPException(status_code=429, detail="Too many requests. Slow down and retry.")


def gateway_rate_limit(request: Request) -> None:
    _enforce(GATEWAY_LIMITER, request)


def audit_ingest_rate_limit(request: Request) -> None:
    _enforce(AUDIT_INGEST_LIMITER, request)


def dashboard_content_security_policy(html: str) -> str:
    """CSP for the single-file dashboard. Its inline `<script>` is allowed by
    hash, so injected markup can never run script even if a value escaped
    `esc()`; inline styles stay allowed (the page styles rows in template
    strings)."""
    hashes = []
    for match in _INLINE_SCRIPT_RE.finditer(html):
        if _SCRIPT_SRC_RE.search(match.group("attrs")):
            continue
        digest = base64.b64encode(hashlib.sha256(match.group("body").encode("utf-8")).digest()).decode("ascii")
        hashes.append(f"'sha256-{digest}'")
    script_src = " ".join(["'self'", *hashes])
    return "; ".join(
        [
            "default-src 'self'",
            f"script-src {script_src}",
            "style-src 'self' 'unsafe-inline'",
            "img-src 'self' data:",
            "connect-src 'self'",
            "object-src 'none'",
            "base-uri 'none'",
            "form-action 'self'",
            "frame-ancestors 'none'",
        ]
    )


class SecurityHeadersMiddleware:
    """Adds the CSP and the usual hardening headers to every HTTP response."""

    def __init__(self, app, headers: dict[str, str]) -> None:
        self.app = app
        self.headers = headers

    async def __call__(self, scope, receive, send) -> None:
        if scope["type"] != "http":
            await self.app(scope, receive, send)
            return

        async def send_with_headers(message) -> None:
            if message["type"] == "http.response.start":
                headers = MutableHeaders(scope=message)
                for name, value in self.headers.items():
                    headers.append(name, value)
            await send(message)

        await self.app(scope, receive, send_with_headers)


class BodySizeLimitMiddleware:
    """Rejects requests that announce a body above `max_bytes` before it is
    read. The gateway forwards whatever JSON it receives, so an unbounded
    body is an unbounded upstream bill."""

    def __init__(self, app, max_bytes: int) -> None:
        self.app = app
        self.max_bytes = max_bytes

    async def __call__(self, scope, receive, send) -> None:
        if scope["type"] == "http":
            for name, value in scope.get("headers", []):
                if name == b"content-length":
                    try:
                        too_large = int(value) > self.max_bytes
                    except ValueError:
                        too_large = True
                    if too_large:
                        response = JSONResponse(status_code=413, content={"detail": "Request body is too large."})
                        await response(scope, receive, send)
                        return
        await self.app(scope, receive, send)
