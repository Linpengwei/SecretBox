"""Red lines for stored free text and the AI egress boundary.

Each case here was a real leak before phase 0: a secondary secret, a
percent-encoded URI password, or a whole ``.env`` block ending up in
``fields_json`` and inside an AI prompt. The tests assert both halves of the
fix — nothing secret is *stored*, and nothing outside the metadata whitelist
is ever *sent* — so a regression in either guard fails on its own.
"""
import importlib.util
import json
from pathlib import Path

import pytest
from app.ai import AIService, ai_service
from app.database import SessionLocal
from app.main import app
from app.maintenance import rescrub_stored_fields
from app.models import ProviderConfig, VaultRecord
from app.redaction import (
    AI_METADATA_FIELD_KEYS,
    is_secret_key,
    redact_known_secrets,
    strip_uri_credentials,
)
from app.security import protect_password
from fastapi.testclient import TestClient
from sqlalchemy import delete, select

client = TestClient(app)
client.__enter__()

# (name, pasted_text, secret the parser must lock into the protected column,
#  every spelling of every secret that must stay out of storage and prompts)
LEAK_CASES = [
    (
        "multi_secret_paste",
        "账号: ops-bot\n密码: Growth2026\nAK: LTAI5TEXAMPLEKEY\nSK: FlXe9s2QwErT7uIo\n支付密码: 739281",
        "Growth2026",
        ["Growth2026", "FlXe9s2QwErT7uIo", "739281"],
    ),
    (
        "redis_uri_percent_encoded_password",
        "redis://default:R3dis%40Prod@redis-prod.internal:6379/0 env=prod",
        "R3dis@Prod",
        ["R3dis%40Prod", "R3dis@Prod"],
    ),
    (
        "env_file_with_several_secrets",
        "DATABASE_URL=postgresql://app:MainPass%401@db.internal:5432/app\nSTRIPE_KEY=sk_live_51ExampleExample\nREDIS_AUTH=CachePass2026",
        "MainPass@1",
        ["MainPass%401", "MainPass@1", "sk_live_51ExampleExample", "CachePass2026"],
    ),
    (
        "natural_language_handoff",
        "账号是 pm_growth 密码是 Growth2026 邮箱密钥是 MailKey9q7x 支付密码 739281",
        "Growth2026",
        ["Growth2026", "MailKey9q7x", "739281"],
    ),
    (
        "jdbc_url_with_password_parameter",
        "jdbc:postgresql://pg.internal:5432/order_db?user=order_app&password=JdbcPw%237788&ssl=true",
        "JdbcPw#7788",
        ["JdbcPw%237788", "JdbcPw#7788"],
    ),
    (
        "glued_code_and_next_line_secret",
        "购物密码20010515\n登录密码\nXf4@Pk8#Rs2",
        "Xf4@Pk8#Rs2",
        ["20010515", "Xf4@Pk8#Rs2"],
    ),
]


def _wipe_records() -> None:
    with SessionLocal() as session:
        session.execute(delete(VaultRecord))
        session.commit()


def _route_ai_through_stub(monkeypatch, reply: str = "{}") -> list[str]:
    """Force the provider row and replace the model call with a stub that
    records every prompt. Returns the list the prompts land in."""
    prompts: list[str] = []

    async def stub_chat_completion(provider, system_prompt: str, user_prompt: str) -> str:
        prompts.extend([system_prompt, user_prompt])
        return reply

    monkeypatch.setattr(ai_service, "_chat_completion", stub_chat_completion)
    with SessionLocal() as session:
        provider = session.get(ProviderConfig, 1)
        if provider is None:
            session.add(ProviderConfig(id=1, base_url="http://127.0.0.1:9/v1", api_key="test", model="test"))
        else:
            provider.base_url = "http://127.0.0.1:9/v1"
            provider.api_key = "test"
        session.commit()
    return prompts


def _stored_row(record_id: str) -> VaultRecord:
    with SessionLocal() as session:
        row = session.get(VaultRecord, record_id)
        assert row is not None
        session.refresh(row)
        session.expunge(row)
        return row


@pytest.mark.parametrize("name,pasted_text,expected_secret,needles", LEAK_CASES, ids=[case[0] for case in LEAK_CASES])
def test_secondary_secrets_never_reach_storage_or_ai_context(monkeypatch, name, pasted_text, expected_secret, needles):
    _wipe_records()
    prompts = _route_ai_through_stub(monkeypatch)

    response = client.post("/api/records", json={"pasted_text": pasted_text})
    assert response.status_code == 200, name
    created = response.json()
    assert created["primary_secret"] == expected_secret, f"{name}: the parser must still lock the primary secret in"

    row = _stored_row(created["id"])
    stored = json.dumps([row.fields_json, row.description, row.title, row.tags, row.username])
    response_body = json.dumps(created["fields"]) + created["notes"] + created["name"]

    search = client.post("/api/search", json={"query": "prod internal ops pm_growth order_db", "limit": 5})
    assert search.status_code == 200
    assert prompts, "both the enrichment and the rerank call must have gone through the stub"

    for needle in needles:
        assert needle not in stored, f"{name}: {needle!r} stored in plaintext metadata"
        assert needle not in response_body, f"{name}: {needle!r} echoed back in a metadata field"
        assert all(needle not in prompt for prompt in prompts), f"{name}: {needle!r} reached AI context"


def test_ai_context_is_a_metadata_whitelist_projection(monkeypatch):
    _wipe_records()
    prompts = _route_ai_through_stub(monkeypatch)
    unlisted_marker = "QQUNLISTEDMARKERQQ"

    response = client.post(
        "/api/records",
        json={
            "item_type": "secret",
            "template_type": "custom",
            "name": "Internal tool",
            "primary_secret": "Primary#Secret1",
            "notes": "hand-written note",
            "fields": [
                {"key": "host", "label": "Host", "value": "tool.internal", "value_type": "text", "semantic": "host", "section": "Connection", "order": 1},
                {"key": "internal_ticket", "label": "Internal ticket", "value": unlisted_marker, "value_type": "text", "semantic": None, "section": "Details", "order": 2},
                {"key": "client_secret", "label": "Client secret", "value": "SecondarySecret2", "value_type": "text", "semantic": None, "section": "Details", "order": 3},
            ],
        },
    )
    assert response.status_code == 200
    by_key = {field["key"]: field for field in response.json()["fields"]}

    # Stored as sent (minus secret material), so nothing is silently dropped …
    assert by_key["internal_ticket"]["value"] == unlisted_marker
    assert by_key["client_secret"]["value"] == "SecondarySecret2"
    # … but a secret-class key is flagged, so clients conceal it.
    assert by_key["client_secret"]["hidden"] is True
    assert by_key["host"]["hidden"] is False

    assert client.post("/api/search", json={"query": "internal"}).status_code == 200
    joined = "\n".join(prompts)
    assert "tool.internal" in joined, "whitelisted metadata is what the model is for"
    assert "hand-written note" in joined
    for forbidden in (unlisted_marker, "SecondarySecret2", "Primary#Secret1", "internal_ticket", "client_secret", "source_excerpt", "pasted_text"):
        assert forbidden not in joined, f"{forbidden!r} must never enter AI context"


def test_raw_paste_text_and_source_excerpt_never_enter_a_prompt(monkeypatch):
    _wipe_records()
    prompts = _route_ai_through_stub(monkeypatch)

    response = client.post(
        "/api/records",
        json={"pasted_text": "service=GitHub username=ops-bot password=GhOpsBot@2026 zzcontext=only-in-the-excerpt"},
    )
    assert response.status_code == 200
    keys = {field["key"] for field in response.json()["fields"]}
    assert "source_excerpt" in keys, "the excerpt is still kept, for semantic recall"

    client.post("/api/search", json={"query": "github"})
    joined = "\n".join(prompts)
    assert '"pasted_text"' not in joined and '"source_excerpt"' not in joined
    assert '"fields"' in joined


def test_model_output_cannot_introduce_secret_class_fields(monkeypatch):
    _wipe_records()
    _route_ai_through_stub(
        monkeypatch,
        reply=json.dumps(
            {
                "name": "Renamed by model",
                "notes": "model note",
                "tags": ["model-tag"],
                "fields": [
                    {"key": "client_secret", "label": "Client secret", "value": "ModelSupplied1", "value_type": "text", "semantic": None, "hidden": False, "section": "Details", "order": 1},
                    {"key": "environment", "label": "Environment", "value": "prod", "value_type": "text", "semantic": "environment", "hidden": False, "section": "Metadata", "order": 2},
                    {"key": "region", "label": "Region", "value": "eu-west-1 Primary#Secret1", "value_type": "text", "semantic": "region", "hidden": False, "section": "Metadata", "order": 3},
                ],
            }
        ),
    )

    response = client.post("/api/records", json={"item_type": "secret", "name": "Tool", "primary_secret": "Primary#Secret1", "fields": []})
    assert response.status_code == 200
    fields = {field["key"]: field["value"] for field in response.json()["fields"]}

    assert "client_secret" not in fields, "a secret-class key proposed by the model is refused outright"
    assert fields["environment"] == "prod"
    assert fields["region"] == "eu-west-1 [REDACTED]", "a known secret echoed by the model is scrubbed"


def test_a_pasted_password_that_misses_the_fingerprint_never_reaches_the_model(monkeypatch):
    _wipe_records()
    prompts = _route_ai_through_stub(monkeypatch)
    # A single long token mixing character classes: what a pasted password
    # looks like, and (here) also the record's title so recall finds it.
    credential_shaped = "Billing2026!Db"
    assert client.post("/api/records", json={"item_type": "secret", "name": credential_shaped, "primary_secret": "Real#Secret1", "fields": []}).status_code == 200
    assert client.post("/api/search", json={"query": credential_shaped}).json()["results"], "the query does match a record"
    prompts_before = len(prompts)
    assert AIService._looks_like_secret(credential_shaped)

    client.post("/api/search", json={"query": credential_shaped})
    assert len(prompts) == prompts_before, "a credential-shaped query is ranked locally, never sent to the model"

    client.post("/api/search", json={"query": "billing"})
    assert len(prompts) > prompts_before, "an ordinary query still gets the model ranking"


def test_search_without_any_match_returns_no_records():
    _wipe_records()
    for name in ("Redis prod", "GitHub bot"):
        assert client.post("/api/records", json={"item_type": "secret", "name": name, "primary_secret": f"{name}#Secret1", "fields": []}).status_code == 200

    response = client.post("/api/search", json={"query": "zzqqxxnothing"})
    assert response.status_code == 200
    assert response.json()["results"] == [], "no fallback: results carry plaintext, so an unrelated record is never handed out"

    # A LIKE wildcard is not a query: "%" used to match the whole vault.
    assert client.post("/api/search", json={"query": "%"}).json()["results"] == []


def test_api_views_never_expose_password_hash_or_fingerprint():
    _wipe_records()
    created = client.post("/api/records", json={"item_type": "secret", "name": "Hash probe", "primary_secret": "HashProbe#1", "fields": []}).json()
    row = _stored_row(created["id"])
    assert row.password_hash.startswith("$argon2id$") and len(row.password_fingerprint) == 64

    views = [
        created,
        client.get("/api/records").json(),
        client.post("/api/search", json={"query": "hash"}).json(),
        client.put(f"/api/records/{created['id']}/permissions", json={"ai_access": "metadata"}).json(),
    ]
    for view in views:
        dumped = json.dumps(view)
        assert "password_hash" not in dumped and "password_fingerprint" not in dumped
        assert row.password_hash not in dumped and row.password_fingerprint not in dumped


def test_startup_rescrub_rewrites_legacy_fields_once_and_leaves_notes_alone():
    _wipe_records()
    protected = protect_password("R3dis@Prod")
    legacy_fields = [
        {"key": "host", "label": "Host", "value": "redis.internal", "value_type": "text", "semantic": "host", "hidden": False, "section": "Connection", "order": 1},
        {"key": "url", "label": "URL", "value": "redis://default:R3dis%40Prod@redis.internal:6379/0", "value_type": "url", "semantic": "uri", "hidden": False, "section": "Connection", "order": 2},
        {"key": "source_excerpt", "label": "Source Excerpt", "value": "SK: LegacySk#9911 支付密码: 424242", "value_type": "text", "semantic": "source_excerpt", "hidden": False, "section": "Metadata", "order": 3},
        {"key": "client_secret", "label": "Client secret", "value": "LegacySecondary#5", "value_type": "text", "semantic": None, "hidden": False, "section": "Details", "order": 4},
    ]
    with SessionLocal() as session:
        session.add(
            VaultRecord(
                record_type="secret",
                title="Legacy redis",
                description="hand-written note, must survive untouched",
                tags="[]",
                fields_json=json.dumps({"template_type": "redis", "fields": legacy_fields}),
                encrypted_password=protected.encrypted_password,
                password_hash=protected.password_hash,
                password_fingerprint=protected.password_fingerprint,
            )
        )
        session.commit()

    assert rescrub_stored_fields() == 1

    row = _stored_row(_single_record_id())
    fields = {field["key"]: field for field in json.loads(row.fields_json)["fields"]}
    assert fields["url"]["value"] == "redis://redis.internal:6379/0", "URL fields lose their userinfo"
    assert fields["source_excerpt"]["value"] == "SK: [REDACTED] 支付密码: [REDACTED]"
    assert fields["client_secret"]["hidden"] is True, "secret-class keys get flagged for clients to conceal"
    assert fields["client_secret"]["value"] == "LegacySecondary#5", "user-supplied values are flagged, never dropped"
    assert row.description == "hand-written note, must survive untouched"

    assert rescrub_stored_fields() == 0, "idempotent: the next startup finds nothing to change"


def _single_record_id() -> str:
    with SessionLocal() as session:
        return session.scalars(select(VaultRecord.id)).one()


def test_ai_metadata_whitelist_matches_mcp_server():
    # Two independent components project the same vault onto "what an agent
    # may see"; they must agree, or the server starts disclosing what the MCP
    # server withholds (or vice versa).
    module_path = Path(__file__).resolve().parents[2] / "mcp-server" / "secretbox_mcp.py"
    spec = importlib.util.spec_from_file_location("secretbox_mcp_under_test", module_path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)

    assert AI_METADATA_FIELD_KEYS == module.METADATA_FIELD_KEYS


@pytest.mark.parametrize(
    "key,expected",
    [
        ("password", True), ("DB_PASSWORD", True), ("支付密码", True), ("secret_key", True), ("STRIPE_KEY", True),
        ("api_key", True), ("private_key", True), ("token", True), ("REDIS_AUTH", True), ("client_secret", True),
        ("sk", True), ("aws_secret_access_key", True), ("passphrase", True), ("密钥", True), ("license_key", True),
        ("access_key", False), ("aws_access_key_id", False), ("ak", False), ("key_id", False), ("public_key", False),
        ("host", False), ("username", False), ("engine", False), ("mechanism", False), ("sasl_mechanism", False),
    ],
)
def test_is_secret_key(key, expected):
    assert is_secret_key(key) is expected


@pytest.mark.parametrize(
    "text,expected",
    [
        ("redis://default:R3dis%40Prod@redis-prod.internal:6379/0", "redis://redis-prod.internal:6379/0"),
        ("redis://:pwd@host:6379", "redis://host:6379"),
        ("amqp://user:pa@ss@mq.internal:5672/vh", "amqp://mq.internal:5672/vh"),
        ("see https://github.com and https://user:pw@gitlab.example.com/x?a=b@c next", "see https://github.com and https://gitlab.example.com/x?a=b@c next"),
        ("https://example.com/@handle", "https://example.com/@handle"),
        ("mail me at ops@example.com", "mail me at ops@example.com"),
        ("git@github.com:org/repo.git", "git@github.com:org/repo.git"),
    ],
)
def test_strip_uri_credentials(text, expected):
    assert strip_uri_credentials(text) == expected


def test_redact_known_secrets_covers_every_encoded_form():
    assert redact_known_secrets("pw R3dis%40Prod / R3dis@Prod / x", "R3dis@Prod") == "pw [REDACTED] / [REDACTED] / x"
