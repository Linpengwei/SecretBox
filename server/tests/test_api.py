import json
import sqlite3

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import delete, select
from unittest.mock import patch

from app.ai import ai_service
from app.config import settings
from app.database import SessionLocal
from app.main import app
from app.models import ProviderConfig, VaultRecord
from app.security import decrypt_totp, protect_password
from sqlalchemy import create_engine

client = TestClient(app)
# Requests made outside a `with` block don't drive the ASGI lifespan, so the
# startup hooks (create_all + migrate_sqlite) would never run against a fresh
# checkout. Enter the lifespan once for the whole module.
client.__enter__()


FREEFORM_SAMPLES = [
    (
        "redis_uri_prod",
        "redis://default:RedisProd#2026@redis-prod.internal:6379/0 env=prod service=order-cache region=shanghai",
        "redis",
        "RedisProd#2026",
        {"host": "redis-prod.internal", "port": "6379"},
        "order-cache",
    ),
    (
        "redis_kv_staging",
        "host=redis-staging.internal port=6380 db=2 username=default password=RedisStage!2026 env=staging service=session-cache redis",
        "redis",
        "RedisStage!2026",
        {"host": "redis-staging.internal", "db": "2"},
        "session-cache",
    ),
    (
        "redis_cli_auth",
        "REDISCLI_AUTH=RedisCliOnly#2026 redis-cli -h redis-ops.internal -p 6379 -n 5 env=ops redis",
        "redis",
        "RedisCliOnly#2026",
        {},
        "redis",
    ),
    (
        "postgres_database_url",
        "DATABASE_URL=postgresql://billing_admin:PgBilling%232026@billing-db.internal:5432/billing env=prod service=reconciliation",
        "database",
        # URI-embedded secrets are percent-decoded: the user's real password is
        # "PgBilling#2026", which is also what exact fingerprint search must match.
        "PgBilling#2026",
        {"engine": "postgres", "database": "billing"},
        "reconciliation",
    ),
    (
        "postgres_kv",
        "host=db.github.internal port=5432 dbname=accounts user=liuhanze password=P@ssw0rd! engine=postgres env=prod",
        "database",
        "P@ssw0rd!",
        {"engine": "postgres", "host": "db.github.internal"},
        "accounts",
    ),
    (
        "mysql_uri",
        "mysql://app_user:MySQLApp!2026@mysql-prod.internal:3306/orders?charset=utf8mb4 env=prod service=order-api",
        "database",
        "MySQLApp!2026",
        {"engine": "mysql", "database": "orders"},
        "order-api",
    ),
    (
        "clickhouse_kv",
        "host=clickhouse-01.internal port=8123 user=analytics password=CHAnalytics#2026 database=events engine=clickhouse env=prod",
        "database",
        "CHAnalytics#2026",
        {"engine": "clickhouse", "database": "events"},
        "events",
    ),
    (
        "mongodb_uri",
        "mongodb://report_user:MongoReport%402026@mongo-01.internal:27017,repl-02.internal:27017/reports?replicaSet=rs0 env=prod team=data",
        "database",
        # percent-decoded URI secret, see postgres_database_url above
        "MongoReport@2026",
        {"engine": "mongodb"},
        "reports",
    ),
    (
        "aws_s3_env",
        "AWS_ACCESS_KEY_ID=AKIAOPS123 AWS_SECRET_ACCESS_KEY=S3SecretOps! AWS_DEFAULT_REGION=ap-east-1 S3_ENDPOINT=https://s3.internal.example.com bucket=artifacts-release",
        "s3",
        "S3SecretOps!",
        {"access_key": "AKIAOPS123", "bucket": "artifacts-release"},
        "artifacts-release",
    ),
    (
        "s3_access_secret",
        "access_key=deploy-artifacts-ak secret_key=DeploySecret#2026 endpoint=https://minio.internal bucket=build-cache region=cn-east-1",
        "s3",
        "DeploySecret#2026",
        {"access_key": "deploy-artifacts-ak", "bucket": "build-cache"},
        "build-cache",
    ),
    (
        "minio_root",
        "MINIO_ROOT_USER=minio-root MINIO_ROOT_PASSWORD=MinioRoot!2026 endpoint=https://minio-prod.internal bucket=infra-backups",
        "s3",
        "MinioRoot!2026",
        {"bucket": "infra-backups"},
        "infra-backups",
    ),
    (
        "github_account",
        "service=GitHub username=ops-bot@example.com password=GhOpsBot@2026 url=https://github.com env=prod",
        "account",
        "GhOpsBot@2026",
        {"service": "GitHub", "url": "https://github.com"},
        "GitHub",
    ),
    (
        "gitlab_account",
        "account=gitlab-ci-bot email=ci-bot@example.com passwd=GitLabCI!2026 service=GitLab url=https://gitlab.example.com",
        "account",
        "GitLabCI!2026",
        {"service": "GitLab", "account": "gitlab-ci-bot"},
        "GitLab",
    ),
    (
        "kafka_sasl_dot_keys",
        'brokers=kafka-1.internal:9092,kafka-2.internal:9092 sasl.username="audit_pipeline" sasl.password="KafkaAudit!2026" mechanism=SCRAM-SHA-512 topic=audit.events env=prod',
        "kafka",
        "KafkaAudit!2026",
        {"brokers": "kafka-1.internal:9092,kafka-2.internal:9092", "mechanism": "SCRAM-SHA-512"},
        "audit.events",
    ),
    (
        "kafka_bootstrap",
        "bootstrap_servers=broker-a.internal:9092,broker-b.internal:9092 username=etl_consumer sasl_password=ETLConsumer#2026 topic=etl.jobs kafka cluster=prod",
        "kafka",
        "ETLConsumer#2026",
        {"brokers": "broker-a.internal:9092,broker-b.internal:9092", "topic": "etl.jobs"},
        "etl.jobs",
    ),
    (
        "rabbitmq_amqp",
        "amqp://rabbit_user:RabbitMQ!2026@mq-prod.internal:5672/prod-vhost service=payments queue=settlement rabbitmq",
        "custom",
        "RabbitMQ!2026",
        {"service": "payments"},
        "payments",
    ),
    (
        "rabbitmq_kv",
        "host=mq-stage.internal port=5672 username=ops password=RabbitStage#2026 vhost=stage engine=rabbitmq",
        "custom",
        "RabbitStage#2026",
        {"host": "mq-stage.internal", "vhost": "stage"},
        "mq-stage.internal",
    ),
    (
        "aliyun_aksk",
        "provider=aliyun ak=LTAI5TEXAMPLE sk=AliyunSK#2026 scope=oss-prod region=cn-shanghai",
        "aksk",
        "AliyunSK#2026",
        {"provider": "aliyun", "access_key": "LTAI5TEXAMPLE"},
        "aliyun",
    ),
    (
        "tencent_aksk",
        "provider=tencent access_key=TCloudAK001 secret_key=TCloudSecret!2026 scope=cos-backup region=ap-shanghai",
        "aksk",
        "TCloudSecret!2026",
        {"access_key": "TCloudAK001", "region": "ap-shanghai"},
        "tencent",
    ),
    (
        "harbor_account",
        "service=Harbor username=robot$deploy password=HarborRobot#2026 url=https://harbor.internal project=release-images",
        "account",
        "HarborRobot#2026",
        {"service": "Harbor", "url": "https://harbor.internal"},
        "Harbor",
    ),
]


def test_record_ingest_and_search_flow():
    with SessionLocal() as session:
        session.execute(delete(VaultRecord))
        session.commit()

    create_response = client.post(
        "/api/records",
        json={
            "item_type": "secret",
            "template_type": "database",
            "name": "GitHub Postgres",
            "primary_secret": "P@ssw0rd!",
            "notes": "GitHub primary account",
            "tags": ["database", "github"],
            "fields": [
                {"key": "username", "label": "Username", "value": "liuhanze", "value_type": "text", "semantic": "username", "section": "Login", "order": 0},
                {"key": "engine", "label": "Engine", "value": "postgres", "value_type": "text", "semantic": "engine", "section": "Connection", "order": 1},
                {"key": "host", "label": "Host", "value": "db.github.internal", "value_type": "text", "semantic": "host", "section": "Connection", "order": 2},
                {"key": "database", "label": "Database", "value": "accounts", "value_type": "text", "semantic": "database", "section": "Connection", "order": 3},
            ],
        },
    )
    assert create_response.status_code == 200
    created = create_response.json()
    assert created["primary_secret"] == "P@ssw0rd!"
    assert created["item_type"] == "secret"
    assert created["template_type"] == "database"
    assert any(field["key"] == "engine" and field["value"] == "postgres" for field in created["fields"])

    search_response = client.post("/api/search", json={"query": "postgres", "limit": 3})
    assert search_response.status_code == 200
    results = search_response.json()["results"]
    assert results
    assert results[0]["primary_secret"] == "P@ssw0rd!"


def test_duplicate_secret_records_are_preserved_and_exact_match_returns_both():
    with SessionLocal() as session:
        session.execute(delete(VaultRecord))
        session.commit()

    payload_one = {
        "item_type": "secret",
        "template_type": "redis",
        "name": "Redis A",
        "primary_secret": "Shared#Secret2026",
        "notes": "First redis credential",
        "tags": ["redis", "a"],
        "fields": [
            {"key": "username", "label": "Username", "value": "default", "value_type": "text", "semantic": "username", "section": "Auth", "order": 0},
            {"key": "host", "label": "Host", "value": "redis-a.internal", "value_type": "text", "semantic": "host", "section": "Connection", "order": 1},
        ],
    }
    payload_two = {
        "item_type": "secret",
        "template_type": "redis",
        "name": "Redis B",
        "primary_secret": "Shared#Secret2026",
        "notes": "Second redis credential with the same secret",
        "tags": ["redis", "b"],
        "fields": [
            {"key": "username", "label": "Username", "value": "cache", "value_type": "text", "semantic": "username", "section": "Auth", "order": 0},
            {"key": "host", "label": "Host", "value": "redis-b.internal", "value_type": "text", "semantic": "host", "section": "Connection", "order": 1},
        ],
    }

    assert client.post("/api/records", json=payload_one).status_code == 200
    assert client.post("/api/records", json=payload_two).status_code == 200

    search_response = client.post("/api/search", json={"query": "Shared#Secret2026", "limit": 10})
    assert search_response.status_code == 200
    results = search_response.json()["results"]

    assert len(results) == 2
    assert {result["name"] for result in results} == {"Redis A", "Redis B"}


def test_legacy_fields_json_is_read_back_as_field_array():
    protected = protect_password("Legacy#Secret2026")
    with SessionLocal() as session:
        session.execute(delete(VaultRecord))
        session.add(
            VaultRecord(
                record_type="secret",
                title="Legacy Record",
                username="legacy-user",
                description="Legacy database credential",
                tags=json.dumps(["legacy"]),
                fields_json=json.dumps({"engine": "postgres", "host": "legacy-db.internal", "password_shape": "masked"}),
                encrypted_password=protected.encrypted_password,
                password_hash=protected.password_hash,
                password_fingerprint=protected.password_fingerprint,
            )
        )
        session.commit()

    search_response = client.post("/api/search", json={"query": "Legacy", "limit": 5})
    assert search_response.status_code == 200
    result = search_response.json()["results"][0]

    assert result["template_type"] is None
    assert any(field["key"] == "engine" and field["value"] == "postgres" for field in result["fields"])
    assert all(field["key"] != "password_shape" for field in result["fields"])


def test_update_can_change_record_to_shared_secret():
    with SessionLocal() as session:
        session.execute(delete(VaultRecord))
        session.commit()

    created_one = client.post(
        "/api/records",
        json={
            "item_type": "secret",
            "template_type": "database",
            "name": "Database A",
            "primary_secret": "Shared-Update-Secret",
            "notes": "First record",
            "tags": ["database", "a"],
            "fields": [
                {"key": "username", "label": "Username", "value": "db_a", "value_type": "text", "semantic": "username", "section": "Auth", "order": 0},
            ],
        },
    )
    created_two = client.post(
        "/api/records",
        json={
            "item_type": "secret",
            "template_type": "database",
            "name": "Database B",
            "primary_secret": "Original-Second-Secret",
            "notes": "Second record",
            "tags": ["database", "b"],
            "fields": [
                {"key": "username", "label": "Username", "value": "db_b", "value_type": "text", "semantic": "username", "section": "Auth", "order": 0},
            ],
        },
    )
    assert created_one.status_code == 200
    assert created_two.status_code == 200

    second_id = created_two.json()["id"]
    update_response = client.put(
        f"/api/records/{second_id}",
        json={
            "item_type": "secret",
            "template_type": "database",
            "name": "Database B",
            "primary_secret": "Shared-Update-Secret",
            "notes": "Second record now shares the same secret",
            "tags": ["database", "b"],
            "fields": [
                {"key": "username", "label": "Username", "value": "db_b", "value_type": "text", "semantic": "username", "section": "Auth", "order": 0},
            ],
        },
    )
    assert update_response.status_code == 200

    search_response = client.post("/api/search", json={"query": "Shared-Update-Secret", "limit": 10})
    assert search_response.status_code == 200
    results = search_response.json()["results"]
    assert len(results) == 2
    assert {result["name"] for result in results} == {"Database A", "Database B"}


def test_freeform_pasted_text_is_classified_and_saved():
    with SessionLocal() as session:
        session.execute(delete(VaultRecord))
        session.commit()

    create_response = client.post(
        "/api/records",
        json={
            "pasted_text": "redis://default:RedisProd#2026@redis-prod.internal:6379/0 env=prod service=order-cache region=shanghai",
            "item_type": "secret",
            "tags": [],
            "fields": [],
        },
    )
    assert create_response.status_code == 200
    created = create_response.json()

    assert created["template_type"] == "redis"
    assert created["item_type"] == "secret"
    assert created["primary_secret"] == "RedisProd#2026"
    assert any(field["key"] == "host" and field["value"] == "redis-prod.internal" for field in created["fields"])
    assert any(field["key"] == "port" and field["value"] == "6379" for field in created["fields"])
    assert any(field["key"] == "username" and field["value"] == "default" for field in created["fields"])
    assert all("RedisProd#2026" not in field["value"] for field in created["fields"] if field["key"] == "source_excerpt")

    search_response = client.post("/api/search", json={"query": "order-cache", "limit": 5})
    assert search_response.status_code == 200
    results = search_response.json()["results"]
    assert results
    assert results[0]["template_type"] == "redis"


def test_freeform_database_dsn_is_classified_and_saved():
    with SessionLocal() as session:
        session.execute(delete(VaultRecord))
        session.commit()

    create_response = client.post(
        "/api/records",
        json={
            "pasted_text": "DATABASE_URL=postgresql://billing_admin:PgBilling%232026@billing-db.internal:5432/billing env=prod service=reconciliation",
            "item_type": "secret",
            "tags": [],
            "fields": [],
        },
    )
    assert create_response.status_code == 200
    created = create_response.json()
    assert created["template_type"] == "database"
    # URI secrets are percent-decoded so the stored password is what the user
    # would actually type (and search for).
    assert created["primary_secret"] == "PgBilling#2026"
    assert any(field["key"] == "engine" and field["value"] == "postgres" for field in created["fields"])
    assert any(field["key"] == "database" and field["value"] == "billing" for field in created["fields"])
    assert any(field["key"] == "username" and field["value"] == "billing_admin" for field in created["fields"])


def test_freeform_s3_env_vars_are_classified_and_saved():
    with SessionLocal() as session:
        session.execute(delete(VaultRecord))
        session.commit()

    create_response = client.post(
        "/api/records",
        json={
            "pasted_text": "AWS_ACCESS_KEY_ID=AKIAOPS123 AWS_SECRET_ACCESS_KEY=S3SecretOps! AWS_DEFAULT_REGION=ap-east-1 S3_ENDPOINT=https://s3.internal.example.com bucket=artifacts-release",
            "item_type": "secret",
            "tags": [],
            "fields": [],
        },
    )
    assert create_response.status_code == 200
    created = create_response.json()
    assert created["template_type"] == "s3"
    assert created["primary_secret"] == "S3SecretOps!"
    assert any(field["key"] == "access_key" and field["value"] == "AKIAOPS123" for field in created["fields"])
    assert any(field["key"] == "bucket" and field["value"] == "artifacts-release" for field in created["fields"])
    assert any(field["key"] == "endpoint" and "s3.internal.example.com" in field["value"] for field in created["fields"])


def test_freeform_kafka_sasl_is_classified_and_saved():
    with SessionLocal() as session:
        session.execute(delete(VaultRecord))
        session.commit()

    create_response = client.post(
        "/api/records",
        json={
            "pasted_text": 'brokers=kafka-1.internal:9092,kafka-2.internal:9092 sasl.username="audit_pipeline" sasl.password="KafkaAudit!2026" mechanism=SCRAM-SHA-512 topic=audit.events env=prod',
            "item_type": "secret",
            "tags": [],
            "fields": [],
        },
    )
    assert create_response.status_code == 200
    created = create_response.json()
    assert created["template_type"] == "kafka"
    assert created["primary_secret"] == "KafkaAudit!2026"
    assert any(field["key"] == "brokers" and "kafka-1.internal:9092" in field["value"] for field in created["fields"])
    assert any(field["key"] == "username" and field["value"] == "audit_pipeline" for field in created["fields"])
    assert any(field["key"] == "mechanism" and field["value"] == "SCRAM-SHA-512" for field in created["fields"])


def test_freeform_account_login_is_classified_and_saved():
    with SessionLocal() as session:
        session.execute(delete(VaultRecord))
        session.commit()

    create_response = client.post(
        "/api/records",
        json={
            "pasted_text": "service=GitHub username=ops-bot@example.com password=GhOpsBot@2026 url=https://github.com env=prod",
            "item_type": "secret",
            "tags": [],
            "fields": [],
        },
    )
    assert create_response.status_code == 200
    created = create_response.json()
    assert created["template_type"] == "account"
    assert created["item_type"] == "login"
    assert created["primary_secret"] == "GhOpsBot@2026"
    assert any(field["key"] == "service" and field["value"] == "GitHub" for field in created["fields"])
    assert any(field["key"] == "url" and field["value"] == "https://github.com" for field in created["fields"])


@pytest.mark.parametrize(
    "sample_name,pasted_text,expected_template,expected_secret,expected_fields,search_query",
    FREEFORM_SAMPLES,
)
def test_freeform_ops_samples_cover_common_paste_formats(
    sample_name: str,
    pasted_text: str,
    expected_template: str,
    expected_secret: str,
    expected_fields: dict[str, str],
    search_query: str,
):
    with SessionLocal() as session:
        session.execute(delete(VaultRecord))
        session.commit()

    create_response = client.post(
        "/api/records",
        json={
            "pasted_text": pasted_text,
            "item_type": "secret",
            "tags": [],
            "fields": [],
        },
    )
    assert create_response.status_code == 200, sample_name
    created = create_response.json()

    assert created["template_type"] == expected_template, sample_name
    assert created["primary_secret"] == expected_secret, sample_name
    for key, value in expected_fields.items():
        assert any(field["key"] == key and field["value"] == value for field in created["fields"]), sample_name
    assert all(expected_secret not in field["value"] for field in created["fields"] if field["key"] in {"url", "source_excerpt"}), sample_name

    search_response = client.post("/api/search", json={"query": search_query, "limit": 5})
    assert search_response.status_code == 200, sample_name
    results = search_response.json()["results"]
    assert results, sample_name


# --- TOTP (two-step verification) and permission matrix -----------------------

TOTP_SEED = "JBSWY3DPEHPK3PXP"


def _wipe_records() -> None:
    with SessionLocal() as session:
        session.execute(delete(VaultRecord))
        session.commit()


def _create_record_with_totp(**totp_overrides) -> dict:
    totp = {
        "secret": TOTP_SEED,
        "issuer": "GitHub",
        "account": "ops-bot@example.com",
        "digits": 6,
        "period": 30,
        "algorithm": "SHA1",
    }
    totp.update(totp_overrides)
    response = client.post(
        "/api/records",
        json={
            "pasted_text": "service=GitHub username=ops-bot@example.com password=GhOpsBot@2026",
            "item_type": "login",
            "tags": [],
            "fields": [],
            "totp": totp,
        },
    )
    assert response.status_code == 200
    return response.json()


def test_create_with_totp_stores_only_ciphertext():
    _wipe_records()
    created = _create_record_with_totp()

    assert created["totp"] is not None
    assert created["totp"]["secret"] == TOTP_SEED

    with SessionLocal() as session:
        row = session.scalars(select(VaultRecord)).one()
        assert row.totp_encrypted, "seed must be stored encrypted"
        assert TOTP_SEED not in row.totp_encrypted, "plaintext seed must never touch the DB row"
        assert TOTP_SEED not in (row.fields_json or "")
        assert TOTP_SEED not in (row.description or "")
        assert decrypt_totp(row.totp_encrypted)["secret"] == TOTP_SEED


def test_search_returns_totp_payload_for_code_generation():
    _wipe_records()
    _create_record_with_totp()

    response = client.post("/api/search", json={"query": "github", "limit": 5})
    assert response.status_code == 200
    result = response.json()["results"][0]
    assert result["totp"]["secret"] == TOTP_SEED
    assert result["totp"]["digits"] == 6


def test_update_totp_keep_replace_clear_semantics():
    _wipe_records()
    created = _create_record_with_totp()
    record_id = created["id"]

    # Absent totp on update keeps the stored seed.
    keep = client.put(
        f"/api/records/{record_id}",
        json={"pasted_text": "service=GitHub username=ops-bot@example.com password=GhOpsBot@2026", "fields": []},
    )
    assert keep.status_code == 200
    assert keep.json()["totp"]["secret"] == TOTP_SEED

    # Explicit new seed replaces it.
    replaced = client.put(
        f"/api/records/{record_id}",
        json={
            "pasted_text": "service=GitHub username=ops-bot@example.com password=GhOpsBot@2026",
            "fields": [],
            "totp": {"secret": "KRSXG5CTMVRXEZLU", "digits": 8},
        },
    )
    assert replaced.status_code == 200
    assert replaced.json()["totp"]["secret"] == "KRSXG5CTMVRXEZLU"
    assert replaced.json()["totp"]["digits"] == 8

    # remove_totp clears it.
    cleared = client.put(
        f"/api/records/{record_id}",
        json={"pasted_text": "service=GitHub username=ops-bot@example.com password=GhOpsBot@2026", "fields": [], "remove_totp": True},
    )
    assert cleared.status_code == 200
    assert cleared.json()["totp"] is None
    with SessionLocal() as session:
        assert session.scalars(select(VaultRecord)).one().totp_encrypted is None


def test_invalid_totp_payload_is_rejected():
    _wipe_records()
    response = client.post(
        "/api/records",
        json={
            "pasted_text": "service=GitHub username=ops-bot@example.com password=GhOpsBot@2026",
            "fields": [],
            "totp": {"secret": "not base32!!"},
        },
    )
    assert response.status_code == 422


def test_pasted_otpauth_uri_is_scrubbed_and_routed_to_totp():
    _wipe_records()
    response = client.post(
        "/api/records",
        json={
            "pasted_text": (
                "service=GitHub username=ops-bot@example.com password=GhOpsBot@2026 "
                "otpauth://totp/GitHub:ops-bot@example.com?secret=JBSWY3DPEHPK3PXP&issuer=GitHub&digits=6&period=30"
            ),
            "fields": [],
        },
    )
    assert response.status_code == 200
    created = response.json()
    assert created["totp"]["secret"] == TOTP_SEED, "embedded URI must be captured as the record seed"
    assert created["totp"]["issuer"] == "GitHub"
    for field in created["fields"]:
        assert "otpauth://" not in field["value"], "URI must not survive into stored fields"
    assert "otpauth://" not in created["notes"]


def test_ai_service_never_receives_totp_seed(monkeypatch):
    _wipe_records()
    captured: dict[str, list[str]] = {"prompts": []}

    async def fake_chat_completion(provider, system_prompt: str, user_prompt: str) -> str:
        captured["prompts"].extend([system_prompt, user_prompt])
        return "{}"

    monkeypatch.setattr(ai_service, "_chat_completion", fake_chat_completion)

    # Force the provider row so enrich/rerank attempt the LLM path.
    with SessionLocal() as session:
        provider = session.get(ProviderConfig, 1)
        if provider is None:
            session.add(ProviderConfig(id=1, base_url="http://llm.invalid", api_key="test", model="test"))
        else:
            provider.base_url = "http://llm.invalid"
            provider.api_key = "test"
        session.commit()

    _create_record_with_totp()
    search_response = client.post("/api/search", json={"query": "github", "limit": 5})
    assert search_response.status_code == 200

    for prompt in captured["prompts"]:
        assert TOTP_SEED not in prompt, "TOTP seed must never enter AI context"
        assert "otpauth://" not in prompt, "Key URIs must never enter AI context"


def test_permissions_round_trip():
    _wipe_records()
    response = client.post(
        "/api/records",
        json={
            "pasted_text": "service=GitHub username=ops-bot@example.com password=GhOpsBot@2026",
            "fields": [],
            "permissions": {
                "read_only": True,
                "hide_secret": True,
                "require_reauth": False,
                "ai_access": "metadata",
            },
        },
    )
    assert response.status_code == 200
    created = response.json()
    assert created["permissions"]["read_only"] is True
    assert created["permissions"]["ai_access"] == "metadata"

    with SessionLocal() as session:
        row = session.scalars(select(VaultRecord)).one()
        assert json.loads(row.permissions_json)["hide_secret"] is True

    search_response = client.post("/api/search", json={"query": "github", "limit": 5})
    assert search_response.json()["results"][0]["permissions"]["read_only"] is True


def test_migration_adds_totp_and_permissions_columns(tmp_path):
    db_path = tmp_path / "legacy.db"
    raw_connection = sqlite3.connect(db_path)
    raw_connection.executescript(
        """
        CREATE TABLE vault_records (
            id TEXT PRIMARY KEY,
            record_type TEXT NOT NULL,
            title TEXT NOT NULL,
            username TEXT,
            description TEXT NOT NULL,
            tags TEXT NOT NULL DEFAULT '[]',
            fields_json TEXT NOT NULL DEFAULT '{}',
            encrypted_password TEXT NOT NULL,
            password_hash TEXT NOT NULL,
            password_fingerprint TEXT NOT NULL,
            created_at DATETIME,
            updated_at DATETIME
        );
        INSERT INTO vault_records (id, record_type, title, username, description, tags, fields_json,
                                   encrypted_password, password_hash, password_fingerprint)
        VALUES ('legacy-1', 'redis', 'Legacy Redis', NULL, 'old row', '[]',
                '{"template_type": "redis", "fields": []}', 'cipher', 'hash', 'fp');
        """
    )
    raw_connection.commit()
    raw_connection.close()

    legacy_url = f"sqlite:///{db_path}"
    legacy_engine = create_engine(legacy_url, future=True)
    import app.database as database_module

    with patch.object(settings, "database_url", legacy_url), patch.object(database_module, "engine", legacy_engine):
        database_module.migrate_sqlite()

    check = sqlite3.connect(db_path)
    columns = {row[1] for row in check.execute("PRAGMA table_info(vault_records)").fetchall()}
    rows = check.execute("SELECT id, totp_encrypted, permissions_json FROM vault_records").fetchall()
    check.close()
    assert {"totp_encrypted", "permissions_json"} <= columns
    assert rows == [("legacy-1", None, None)], "existing rows must survive the additive migration"
