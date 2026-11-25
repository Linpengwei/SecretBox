"""Startup guard, upstream validation, request limits and response headers.

The server has no accounts yet (that is the auth phase). Until then these are
the controls that keep the default deployment from being an open relay: it
refuses to start on the development keys unless told to, never stores an
upstream URL that points at cloud metadata, throttles the two endpoints that
are trivial to abuse anonymously, and stops any web page in the operator's
browser from reading responses cross-origin.
"""
import base64
import hashlib
import re
import secrets
from unittest.mock import patch

import pytest
from app import hardening
from app.ai import ai_service
from app.config import settings
from app.database import SessionLocal
from app.hardening import (
    AUDIT_INGEST_LIMITER,
    GATEWAY_LIMITER,
    MAX_REQUEST_BYTES,
    assert_production_keys,
)
from app.main import app
from app.models import AuditEvent, ProviderConfig, VaultRecord
from fastapi.testclient import TestClient
from sqlalchemy import select

client = TestClient(app)
client.__enter__()

# Throwaway fixture values, randomized per test run so nothing here is a real
# key. Only their validation behaviour is asserted.
UPSTREAM_KEY = "test-" + secrets.token_hex(8)
REAL_FINGERPRINT_KEY = "fp-" + secrets.token_hex(8)
URL_WITH_USERINFO = f"http://ops:{secrets.token_hex(6)}@model.internal/v1"


def _wipe_state() -> None:
    GATEWAY_LIMITER.reset()
    AUDIT_INGEST_LIMITER.reset()
    with SessionLocal() as session:
        for model in (VaultRecord, AuditEvent, ProviderConfig):
            for row in session.scalars(select(model)):
                session.delete(row)
        session.commit()


@pytest.fixture(autouse=True)
def _isolated_state():
    _wipe_state()
    yield
    _wipe_state()


# --- development keys ---------------------------------------------------------


def test_development_keys_need_an_explicit_opt_in(monkeypatch):
    monkeypatch.setattr(settings, "allow_dev_defaults", False)
    with pytest.raises(RuntimeError, match="SECRETBOX_DEV"):
        assert_production_keys()

    monkeypatch.setattr(settings, "allow_dev_defaults", True)
    assert_production_keys()

    # One real key does not excuse the other one still being the default.
    monkeypatch.setattr(settings, "allow_dev_defaults", False)
    monkeypatch.setattr(settings, "fingerprint_key", REAL_FINGERPRINT_KEY)
    with pytest.raises(RuntimeError, match="ENCRYPTION_KEY"):
        assert_production_keys()


# --- upstream validation ------------------------------------------------------


@pytest.mark.parametrize(
    "url",
    [
        "http://169.254.169.254/latest/meta-data",  # AWS / GCP / Azure instance metadata
        "http://[::ffff:169.254.169.254]/latest",  # the same address, IPv4-mapped
        "http://[2002:a9fe:a9fe::1]/latest",  # the same address, 6to4-tunnelled
        "http://0.0.0.0/",
        "http://224.0.0.1/",
        "http://metadata.google.internal/computeMetadata/v1",
        "file:///etc/passwd",
        "gopher://model.internal/",
        URL_WITH_USERINFO,
        "http://model.internal:99999/v1",
        "http://",
        "model.internal/v1",
        "",
    ],
)
def test_provider_rejects_unsafe_upstream_urls(url):
    response = client.put("/api/provider", json={"base_url": url, "api_key": UPSTREAM_KEY, "model": "m"})
    assert response.status_code == 422, url
    assert client.get("/api/provider").json()["configured"] is False, "a rejected URL must not be stored"


@pytest.mark.parametrize("url", ["http://127.0.0.1:11434/v1", "http://10.0.0.5:8080/v1", "http://[::1]:8000/v1"])
def test_self_hosted_upstreams_on_loopback_and_private_networks_are_allowed(url):
    response = client.put("/api/provider", json={"base_url": url, "api_key": UPSTREAM_KEY, "model": "m"})
    assert response.status_code == 200, url
    assert response.json()["base_url"] == url


def test_gateway_refuses_an_unsafe_upstream_that_was_written_by_hand():
    with SessionLocal() as session:
        session.add(ProviderConfig(id=1, base_url="http://169.254.169.254/latest", api_key=UPSTREAM_KEY, model="m"))
        session.commit()

    async def must_not_run(provider, payload):
        raise AssertionError("the request must be refused before anything is forwarded")

    with patch.object(ai_service, "forward_chat_completion", must_not_run):
        response = client.post("/ai/v1/chat/completions", json={"messages": [{"role": "user", "content": "hi"}]})

    assert response.status_code == 502
    assert client.get("/api/audit", params={"action": "ai_chat"}).json()["events"][0]["allowed"] is False


def test_upstream_check_without_dns_only_inspects_literals():
    assert_safe = hardening.assert_safe_upstream_url
    assert_safe("http://upstream.invalid/v1", resolve=False)  # not resolvable, but not inspected
    with pytest.raises(ValueError):
        assert_safe("http://169.254.169.254/v1", resolve=False)
    with pytest.raises(ValueError):
        assert_safe("http://metadata.google.internal/v1", resolve=False)


# --- request limits -----------------------------------------------------------


def test_gateway_calls_are_rate_limited_per_client(monkeypatch):
    monkeypatch.setattr(GATEWAY_LIMITER, "limit", 3)
    statuses = [client.post("/ai/v1/chat/completions", json={"messages": []}).status_code for _ in range(5)]
    # 503 = not configured (handled), 429 = refused before the handler ran.
    assert statuses == [503, 503, 503, 429, 429]
    assert client.get("/api/records").status_code == 200, "other endpoints are not affected"


def test_audit_ingest_is_rate_limited_per_client(monkeypatch):
    monkeypatch.setattr(AUDIT_INGEST_LIMITER, "limit", 2)
    statuses = [client.post("/api/audit", json={"action": "tool_call"}).status_code for _ in range(4)]
    assert statuses == [202, 202, 429, 429]


def test_rate_limits_can_be_switched_off_for_suites(monkeypatch):
    monkeypatch.setattr(GATEWAY_LIMITER, "limit", 1)
    monkeypatch.setattr(settings, "rate_limit_enabled", False)
    assert [client.post("/ai/v1/chat/completions", json={"messages": []}).status_code for _ in range(3)] == [503, 503, 503]


def test_sliding_window_forgets_old_hits():
    limiter = hardening.SlidingWindowLimiter("test", limit=2, window_seconds=10)
    assert limiter.allow("a", now=0) and limiter.allow("a", now=1)
    assert not limiter.allow("a", now=2)
    assert limiter.allow("a", now=11), "a hit older than the window no longer counts"
    assert limiter.allow("b", now=2), "limits are per client"


def test_oversized_request_body_is_rejected_before_it_is_read():
    response = client.post(
        "/api/search",
        content=b"x" * (MAX_REQUEST_BYTES + 1),
        headers={"Content-Type": "application/json"},
    )
    assert response.status_code == 413


# --- browser-facing response headers ------------------------------------------


def test_dashboard_csp_pins_the_inline_script_by_hash():
    page = client.get("/dashboard")
    csp = page.headers["content-security-policy"]

    script = re.search(r"<script>(.*?)</script>", page.text, flags=re.DOTALL).group(1)
    digest = base64.b64encode(hashlib.sha256(script.encode("utf-8")).digest()).decode("ascii")
    script_src = next(directive for directive in csp.split("; ") if directive.startswith("script-src"))
    assert f"'sha256-{digest}'" in script_src
    assert "unsafe-inline" not in script_src and "unsafe-eval" not in script_src

    directives = {directive.split(" ", 1)[0]: directive for directive in csp.split("; ")}
    assert directives["default-src"] == "default-src 'self'"
    assert directives["connect-src"] == "connect-src 'self'"
    assert directives["object-src"] == "object-src 'none'"
    assert directives["frame-ancestors"] == "frame-ancestors 'none'"


def test_every_response_carries_the_hardening_headers():
    for response in (client.get("/health"), client.get("/dashboard"), client.get("/api/records")):
        assert response.headers["x-content-type-options"] == "nosniff"
        assert response.headers["x-frame-options"] == "DENY"
        assert response.headers["referrer-policy"] == "no-referrer"
        assert response.headers["cache-control"] == "no-store"
        assert "content-security-policy" in response.headers


def test_cross_origin_browser_reads_are_refused_by_default():
    evil = {"Origin": "https://evil.example"}
    # A web page in the operator's browser must not be able to read this
    # server's responses; /api/search hands out plaintext.
    response = client.get("/api/records", headers=evil)
    assert response.status_code == 200
    assert "access-control-allow-origin" not in response.headers

    preflight = client.options(
        "/api/search",
        headers={**evil, "Access-Control-Request-Method": "POST", "Access-Control-Request-Headers": "content-type"},
    )
    assert "access-control-allow-origin" not in preflight.headers
