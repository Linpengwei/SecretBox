"""Dashboard / audit / security-review / AI-gateway endpoint tests."""

import json
import secrets
from datetime import datetime, timedelta
from unittest.mock import patch

import httpx
from fastapi.testclient import TestClient
from sqlalchemy import select

from app.ai import ai_service
from app.database import SessionLocal
from app.main import app
from app.models import AuditEvent, ProviderConfig, VaultRecord
from app.security import protect_password

client = TestClient(app)
client.__enter__()

# Throwaway fixture secrets, randomized per test run so nothing here is a real
# credential. Only their vault behaviour (weak/reused/strong) is asserted.
WEAK_SAMPLE = "123456"
STRONG_SAMPLE = f"Tumble7#{secrets.token_hex(5)}"
REUSED_SAMPLE = f"SharedRollout#{secrets.token_hex(4)}"
UPSTREAM_KEY = "test-" + secrets.token_hex(8)


def _wipe_state() -> None:
    with SessionLocal() as session:
        for row in session.scalars(select(VaultRecord)):
            session.delete(row)
        for row in session.scalars(select(AuditEvent)):
            session.delete(row)
        for row in session.scalars(select(ProviderConfig)):
            session.delete(row)
        session.commit()


def _create_record(name: str, secret: str, *, item_type: str = "secret", tags: list[str] | None = None) -> dict:
    response = client.post(
        "/api/records",
        json={
            "item_type": item_type,
            "name": name,
            "primary_secret": secret,
            "notes": f"{name} notes",
            "tags": tags or [],
            "fields": [],
        },
    )
    assert response.status_code == 200, response.text
    return response.json()


# --- dashboard shell ---------------------------------------------------------


def test_root_redirects_and_dashboard_html_is_served():
    root = client.get("/", follow_redirects=False)
    assert root.status_code in (307, 302)
    assert root.headers["location"] == "/dashboard"

    page = client.get("/dashboard")
    assert page.status_code == 200
    assert "SecretBox Server Dashboard" in page.text
    assert "Agent Audit" in page.text and "AI Gateway" in page.text


# --- records inventory + permissions ------------------------------------------


def test_records_list_reports_strength_and_reuse_without_secrets():
    _wipe_state()
    _create_record("Weak Login", WEAK_SAMPLE, item_type="login")
    _create_record("Shared A", REUSED_SAMPLE)
    _create_record("Shared B", REUSED_SAMPLE)

    response = client.get("/api/records")
    assert response.status_code == 200
    items = response.json()
    assert len(items) == 3

    by_name = {item["name"]: item for item in items}
    assert by_name["Weak Login"]["strength"]["label"] == "weak"
    assert by_name["Shared A"]["strength"]["reused"] is True
    assert by_name["Shared B"]["strength"]["reused"] is True

    body = json.dumps(items)
    assert WEAK_SAMPLE not in body and REUSED_SAMPLE not in body, "inventory must not leak plaintext"
    assert all(item["primary_secret"] is None for item in items)


def test_permissions_can_be_updated_via_dashboard():
    _wipe_state()
    created = _create_record("GitHub Ops", STRONG_SAMPLE, item_type="login")

    response = client.put(
        f"/api/records/{created['id']}/permissions",
        json={"read_only": True, "hide_secret": False, "require_reauth": True, "ai_access": "metadata_and_tools"},
    )
    assert response.status_code == 200
    assert response.json()["permissions"]["ai_access"] == "metadata_and_tools"

    listed = client.get("/api/records").json()
    target = next(item for item in listed if item["id"] == created["id"])
    assert target["permissions"]["read_only"] is True

    events = client.get("/api/audit", params={"action": "permissions_update"}).json()["events"]
    assert events and events[0]["detail"]["ai_access"] == "metadata_and_tools"

    missing = client.put("/api/records/does-not-exist/permissions", json={"ai_access": "none"})
    assert missing.status_code == 404


# --- security review ----------------------------------------------------------


def test_security_report_flags_weak_reuse_and_stale_without_leaking_secrets():
    _wipe_state()
    _create_record("Weak Login", WEAK_SAMPLE, item_type="login")
    _create_record("Shared A", REUSED_SAMPLE)
    _create_record("Shared B", REUSED_SAMPLE)

    stale_cutoff = datetime.utcnow() - timedelta(days=400)
    stale_secret = f"Ancient#{secrets.token_hex(4)}"
    protected = protect_password(stale_secret)
    with SessionLocal() as session:
        session.add(
            VaultRecord(
                record_type="secret",
                title="Stale Redis",
                username=None,
                description="old credential",
                tags=json.dumps(["redis"]),
                fields_json=json.dumps({"template_type": "redis", "fields": []}),
                encrypted_password=protected.encrypted_password,
                password_hash=protected.password_hash,
                password_fingerprint=protected.password_fingerprint,
                updated_at=stale_cutoff,
                created_at=stale_cutoff,
            )
        )
        session.commit()

    response = client.get("/api/dashboard/security")
    assert response.status_code == 200
    report = response.json()
    kinds = {finding["kind"] for finding in report["findings"]}
    assert "weak_password" in kinds
    assert "password_reuse" in kinds
    assert "stale_password" in kinds

    assert report["summary"]["weak"] >= 1
    assert report["summary"]["reused"] == 2
    assert report["summary"]["stale"] == 1

    body = json.dumps(report)
    for secret in (WEAK_SAMPLE, REUSED_SAMPLE, stale_secret):
        assert secret not in body, "security report must never echo plaintext"


def test_organization_report_distribution_and_duplicates():
    _wipe_state()
    _create_record("Redis Prod", STRONG_SAMPLE, tags=["redis", "prod"])
    _create_record("Redis Stage", STRONG_SAMPLE, tags=["redis", "staging"])
    _create_record("Same Name", WEAK_SAMPLE)
    _create_record("Same Name", STRONG_SAMPLE)

    response = client.get("/api/dashboard/organization")
    assert response.status_code == 200
    report = response.json()
    assert report["total"] == 4
    assert report["by_type"]["secret"] == 4
    tags = {entry["tag"]: entry["count"] for entry in report["top_tags"]}
    assert tags.get("redis") == 2
    assert any(dup["records"][0]["name"] == "Same Name" and len(dup["records"]) == 2 for dup in report["duplicate_titles"])


def test_overview_endpoint_aggregates_sections():
    _wipe_state()
    _create_record("Overview Item", STRONG_SAMPLE, item_type="login", tags=["login"])
    _create_record("Overview Item", WEAK_SAMPLE)  # duplicate title on purpose

    response = client.get("/api/dashboard/overview")
    assert response.status_code == 200
    data = response.json()
    assert data["records"]["total"] == 2
    assert data["records"]["duplicates"] == 1
    assert data["records"]["by_type"]["login"] == 1
    assert "audit_stats" in data and "hourly" in data["audit_stats"]
    assert data["ai"]["configured"] is False


# --- audit trail ---------------------------------------------------------------


def test_audit_ingest_redacts_secret_shaped_details():
    _wipe_state()
    response = client.post(
        "/api/audit",
        json={
            "actor": "claude-code",
            "actor_type": "agent",
            "action": "copy_password",
            "record_id": "abc-123",
            "allowed": True,
            "detail": {"query": f"SuperSecret{secrets.token_hex(3)}", "note": "tool call from session 42"},
        },
    )
    assert response.status_code == 202

    events = client.get("/api/audit", params={"actor_type": "agent"}).json()["events"]
    assert events, "ingested agent event must be listed"
    assert events[0]["actor"] == "claude-code"
    assert events[0]["detail"]["query"] == "[REDACTED]", "secret-shaped keys must be redacted at ingest"
    assert events[0]["detail"]["note"] == "tool call from session 42"

    stats = client.get("/api/audit/stats").json()
    assert stats["per_action"].get("copy_password", 0) >= 1


def test_search_audit_never_stores_the_query_text():
    _wipe_state()
    _create_record("Fingerprint Target", STRONG_SAMPLE)

    exact = client.post("/api/search", json={"query": STRONG_SAMPLE, "limit": 5})
    assert exact.status_code == 200
    semantic = client.post("/api/search", json={"query": "Fingerprint", "limit": 5})
    assert semantic.status_code == 200

    body = json.dumps(client.get("/api/audit", params={"limit": 100}).json())
    assert STRONG_SAMPLE not in body, "the query (possibly a plaintext password) must never reach the audit log"
    modes = {event["detail"].get("mode") for event in client.get("/api/audit").json()["events"] if event["action"] == "search"}
    assert modes == {"exact_fingerprint", "semantic"}


# --- AI gateway ----------------------------------------------------------------


def _configure_provider() -> None:
    with SessionLocal() as session:
        provider = session.get(ProviderConfig, 1)
        if provider is None:
            session.add(ProviderConfig(id=1, base_url="http://upstream.invalid/v1", api_key=UPSTREAM_KEY, model="server-model"))
        else:
            provider.base_url = "http://upstream.invalid/v1"
            provider.api_key = UPSTREAM_KEY
            provider.model = "server-model"
        session.commit()


def test_ai_status_reflects_configuration():
    _wipe_state()
    unconfigured = client.get("/api/ai/status").json()
    assert unconfigured["enabled"] is False

    _configure_provider()
    configured = client.get("/api/ai/status").json()
    assert configured["enabled"] is True
    assert configured["model"] == "server-model"
    assert UPSTREAM_KEY not in json.dumps(configured)


def test_ai_gateway_unconfigured_or_malformed_requests():
    _wipe_state()
    response = client.post("/ai/v1/chat/completions", json={"messages": [{"role": "user", "content": "hi"}]})
    assert response.status_code == 503

    _configure_provider()
    assert client.post("/ai/v1/chat/completions", json={"stream": True, "messages": []}).status_code == 400
    assert client.post("/ai/v1/chat/completions", json={"nope": 1}).status_code == 400


def test_ai_gateway_enforces_server_model_and_audits_usage():
    _wipe_state()
    _configure_provider()
    captured: dict[str, object] = {}

    async def fake_forward(provider, payload):
        captured["provider"] = provider
        captured["payload"] = payload
        return {
            "choices": [{"message": {"role": "assistant", "content": "gateway ok"}}],
            "usage": {"prompt_tokens": 12, "completion_tokens": 5},
        }

    with patch.object(ai_service, "forward_chat_completion", fake_forward):
        response = client.post(
            "/ai/v1/chat/completions",
            json={"model": "gpt-expensive", "messages": [{"role": "user", "content": "ping"}]},
            headers={"X-SecretBox-Actor": "secretbox-macos"},
        )

    assert response.status_code == 200
    assert response.json()["choices"][0]["message"]["content"] == "gateway ok"
    # The server-configured model is enforced regardless of what the client sent.
    assert captured["payload"]["model"] == "server-model"
    assert UPSTREAM_KEY not in json.dumps(response.json())

    events = client.get("/api/audit", params={"action": "ai_chat"}).json()["events"]
    assert events[0]["actor"] == "secretbox-macos"
    assert events[0]["allowed"] is True
    assert events[0]["detail"]["prompt_tokens"] == 12


def test_ai_gateway_maps_upstream_failure_to_502_and_denied_audit():
    _wipe_state()
    _configure_provider()

    request = httpx.Request("POST", "http://upstream.invalid/v1/chat/completions")
    upstream_error = httpx.HTTPStatusError(
        "boom", request=request, response=httpx.Response(500, request=request)
    )

    async def failing_forward(provider, payload):
        raise upstream_error

    with patch.object(ai_service, "forward_chat_completion", failing_forward):
        response = client.post("/ai/v1/chat/completions", json={"messages": [{"role": "user", "content": "ping"}]})

    assert response.status_code == 502
    events = client.get("/api/audit", params={"action": "ai_chat"}).json()["events"]
    assert events[0]["allowed"] is False
    assert events[0]["detail"]["reason"] == "upstream error"
