from __future__ import annotations

import json
import sys
from pathlib import Path

from sqlalchemy import select

ROOT = Path(__file__).resolve().parents[1]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from app.database import Base, SessionLocal, engine, migrate_sqlite
from app.models import VaultRecord
from app.schemas import VaultFieldPayload
from app.security import protect_password

DEMO_RECORDS = [
    {
        "item_type": "secret",
        "template_type": "redis",
        "name": "Prod Redis Cache",
        "notes": "Production Redis cache password for order service in Shanghai region",
        "tags": ["redis", "prod", "cache", "shanghai"],
        "fields": [
            {"key": "username", "label": "Username", "value": "default", "value_type": "text", "semantic": "username", "section": "Auth", "order": 0},
            {"key": "host", "label": "Host", "value": "redis-prod.internal", "value_type": "text", "semantic": "host", "section": "Connection", "order": 1},
            {"key": "port", "label": "Port", "value": "6379", "value_type": "number", "semantic": "port", "section": "Connection", "order": 2},
            {"key": "db", "label": "Database", "value": "0", "value_type": "number", "semantic": "database", "section": "Connection", "order": 3},
            {"key": "url", "label": "URL", "value": "redis://redis-prod.internal:6379/0", "value_type": "url", "semantic": "uri", "section": "Connection", "order": 4},
        ],
        "primary_secret": "Redis#Prod2026!",
    },
    {
        "item_type": "secret",
        "template_type": "s3",
        "name": "Artifacts S3 Bucket",
        "notes": "Artifact bucket access secret for CI uploads and release packages",
        "tags": ["s3", "artifact", "ci", "release"],
        "fields": [
            {"key": "username", "label": "Username", "value": "deploy-bot", "value_type": "text", "semantic": "username", "section": "Auth", "order": 0},
            {"key": "endpoint", "label": "Endpoint", "value": "https://s3.internal.example.com", "value_type": "url", "semantic": "endpoint", "section": "Connection", "order": 1},
            {"key": "bucket", "label": "Bucket", "value": "artifacts-release", "value_type": "text", "semantic": "bucket", "section": "Connection", "order": 2},
            {"key": "access_key", "label": "Access Key", "value": "deploy-artifacts-ak", "value_type": "text", "semantic": "access_key", "section": "Auth", "order": 3},
            {"key": "region", "label": "Region", "value": "ap-east-1", "value_type": "text", "semantic": "region", "section": "Connection", "order": 4},
        ],
        "primary_secret": "S3Secret-Artifact-2026",
    },
    {
        "item_type": "secret",
        "template_type": "database",
        "name": "Billing Postgres",
        "notes": "Primary postgres password for billing database and reconciliation jobs",
        "tags": ["database", "postgres", "billing", "finance"],
        "fields": [
            {"key": "username", "label": "Username", "value": "billing_admin", "value_type": "text", "semantic": "username", "section": "Auth", "order": 0},
            {"key": "engine", "label": "Engine", "value": "postgres", "value_type": "text", "semantic": "engine", "section": "Connection", "order": 1},
            {"key": "host", "label": "Host", "value": "billing-db.internal", "value_type": "text", "semantic": "host", "section": "Connection", "order": 2},
            {"key": "port", "label": "Port", "value": "5432", "value_type": "number", "semantic": "port", "section": "Connection", "order": 3},
            {"key": "database", "label": "Database", "value": "billing", "value_type": "text", "semantic": "database", "section": "Connection", "order": 4},
        ],
        "primary_secret": "PgBilling#2026",
    },
    {
        "item_type": "secret",
        "template_type": "kafka",
        "name": "Audit Kafka SASL",
        "notes": "Kafka SASL password for audit topic consumer group in production",
        "tags": ["kafka", "audit", "prod", "sasl"],
        "fields": [
            {"key": "username", "label": "Username", "value": "audit_pipeline", "value_type": "text", "semantic": "username", "section": "Auth", "order": 0},
            {"key": "brokers", "label": "Brokers", "value": "kafka-1.internal:9092,kafka-2.internal:9092", "value_type": "text", "semantic": "brokers", "section": "Connection", "order": 1},
            {"key": "mechanism", "label": "Mechanism", "value": "SCRAM-SHA-512", "value_type": "text", "semantic": "mechanism", "section": "Auth", "order": 2},
            {"key": "topic", "label": "Topic", "value": "audit.events", "value_type": "text", "semantic": "topic", "section": "Connection", "order": 3},
        ],
        "primary_secret": "KafkaAudit!2026",
    },
    {
        "item_type": "login",
        "template_type": "account",
        "name": "GitHub Ops Bot",
        "notes": "Shared GitHub bot account used by deployment workflows and repo maintenance",
        "tags": ["account", "github", "bot", "automation"],
        "fields": [
            {"key": "username", "label": "Username", "value": "ops-bot@example.com", "value_type": "text", "semantic": "username", "section": "Login", "order": 0},
            {"key": "service", "label": "Service", "value": "GitHub", "value_type": "text", "semantic": "service", "section": "Login", "order": 1},
            {"key": "account", "label": "Account", "value": "ops-bot", "value_type": "text", "semantic": "account", "section": "Login", "order": 2},
            {"key": "url", "label": "URL", "value": "https://github.com", "value_type": "url", "semantic": "uri", "section": "Login", "order": 3},
        ],
        "primary_secret": "GhOpsBot@2026",
    },
]


def main() -> None:
    Base.metadata.create_all(bind=engine)
    migrate_sqlite()
    created = 0
    skipped = 0

    with SessionLocal() as session:
        for payload in DEMO_RECORDS:
            protected = protect_password(payload["primary_secret"])
            existing = session.scalar(
                select(VaultRecord).where(
                    VaultRecord.record_type == payload["item_type"],
                    VaultRecord.title == payload["name"],
                    VaultRecord.description == payload["notes"],
                )
            )
            if existing is not None:
                skipped += 1
                continue

            fields = [VaultFieldPayload(**field).model_dump(mode="json") for field in payload["fields"]]
            session.add(
                VaultRecord(
                    record_type=payload["item_type"],
                    title=payload["name"],
                    username=next((field["value"] for field in fields if field["key"] == "username"), None),
                    description=payload["notes"],
                    tags=json.dumps(payload["tags"]),
                    fields_json=json.dumps({"template_type": payload["template_type"], "fields": fields}),
                    encrypted_password=protected.encrypted_password,
                    password_hash=protected.password_hash,
                    password_fingerprint=protected.password_fingerprint,
                )
            )
            created += 1

        session.commit()

    print(f"Demo seed complete. created={created} skipped={skipped}")


if __name__ == "__main__":
    main()
