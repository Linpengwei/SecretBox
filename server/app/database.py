from __future__ import annotations

import json
from pathlib import Path

from sqlalchemy import create_engine
from sqlalchemy.orm import DeclarativeBase, sessionmaker

from .config import settings


class Base(DeclarativeBase):
    pass


engine = create_engine(settings.database_url, future=True)
SessionLocal = sessionmaker(bind=engine, autoflush=False, autocommit=False, future=True)


def get_db():
    session = SessionLocal()
    try:
        yield session
    finally:
        session.close()


def migrate_sqlite() -> None:
    if not settings.database_url.startswith("sqlite:///"):
        return

    db_path = settings.database_url.removeprefix("sqlite:///")
    sqlite_path = Path(db_path)
    if not sqlite_path.is_absolute():
        sqlite_path = Path.cwd() / sqlite_path
    if not sqlite_path.exists():
        return

    with engine.begin() as connection:
        inspector = connection.exec_driver_sql("PRAGMA table_info(vault_records)").fetchall()
        if not inspector:
            return

        rows = connection.exec_driver_sql(
            """
            SELECT id, record_type, title, username, description, tags, fields_json,
                   encrypted_password, password_hash, password_fingerprint, created_at, updated_at
            FROM vault_records
            """
        ).mappings().all()

        legacy_fields = any(_needs_field_migration(row["fields_json"]) for row in rows)
        index_rows = connection.exec_driver_sql("PRAGMA index_list(vault_records)").fetchall()
        has_unique_fingerprint_index = any(
            row[2] == 1 and "fingerprint" in str(row[1]).lower()
            for row in index_rows
        )
        if legacy_fields or has_unique_fingerprint_index:
            connection.exec_driver_sql(
                """
                CREATE TABLE IF NOT EXISTS vault_records_migrated (
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
                )
                """
            )
            connection.exec_driver_sql("DELETE FROM vault_records_migrated")

            for row in rows:
                connection.exec_driver_sql(
                    """
                    INSERT INTO vault_records_migrated (
                        id, record_type, title, username, description, tags, fields_json,
                        encrypted_password, password_hash, password_fingerprint, created_at, updated_at
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    (
                        row["id"],
                        row["record_type"],
                        row["title"],
                        row["username"],
                        row["description"],
                        row["tags"] or "[]",
                        _normalize_fields_json(row["fields_json"]),
                        row["encrypted_password"],
                        row["password_hash"],
                        row["password_fingerprint"],
                        row["created_at"],
                        row["updated_at"],
                    ),
                )

            connection.exec_driver_sql("DROP TABLE vault_records")
            connection.exec_driver_sql("ALTER TABLE vault_records_migrated RENAME TO vault_records")
            connection.exec_driver_sql("CREATE INDEX IF NOT EXISTS ix_vault_records_record_type ON vault_records (record_type)")
            connection.exec_driver_sql("CREATE INDEX IF NOT EXISTS ix_vault_records_password_fingerprint ON vault_records (password_fingerprint)")

        # Additive columns for the TOTP / permission-matrix phase. Runs after
        # any legacy rebuild above (the rebuild table shape predates them);
        # plain nullable ALTERs keep existing rows and indexes untouched.
        existing_columns = {row[1] for row in connection.exec_driver_sql("PRAGMA table_info(vault_records)").fetchall()}
        for column, ddl in (
            ("totp_encrypted", "ALTER TABLE vault_records ADD COLUMN totp_encrypted TEXT"),
            ("permissions_json", "ALTER TABLE vault_records ADD COLUMN permissions_json TEXT"),
        ):
            if column not in existing_columns:
                connection.exec_driver_sql(ddl)


def _needs_field_migration(raw_fields: str | None) -> bool:
    if not raw_fields:
        return False
    try:
        parsed = json.loads(raw_fields)
    except Exception:
        return False
    return not (isinstance(parsed, dict) and "fields" in parsed)


def _normalize_fields_json(raw_fields: str | None) -> str:
    if not raw_fields:
        return json.dumps({"template_type": None, "fields": []})
    try:
        parsed = json.loads(raw_fields)
    except Exception:
        return json.dumps({"template_type": None, "fields": []})

    if isinstance(parsed, dict) and "fields" in parsed:
        return json.dumps(parsed)

    legacy_fields: list[dict[str, object]] = []
    if isinstance(parsed, dict):
        for order, (key, value) in enumerate(parsed.items()):
            if key in {"password_shape", "source_excerpt"}:
                continue
            legacy_fields.append(
                {
                    "key": key,
                    "label": key.replace("_", " ").title(),
                    "value": str(value),
                    "value_type": "text",
                    "semantic": key,
                    "hidden": False,
                    "section": "Details",
                    "order": order,
                }
            )
    return json.dumps({"template_type": parsed.get("record_type") if isinstance(parsed, dict) else None, "fields": legacy_fields})
