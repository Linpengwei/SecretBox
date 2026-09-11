from __future__ import annotations

import uuid
from datetime import datetime

from sqlalchemy import DateTime, Integer, String, Text, func
from sqlalchemy.orm import Mapped, mapped_column

from .database import Base


class ProviderConfig(Base):
    __tablename__ = "provider_configs"

    id: Mapped[int] = mapped_column(Integer, primary_key=True, default=1)
    base_url: Mapped[str] = mapped_column(String(500))
    api_key: Mapped[str] = mapped_column(String(500))
    model: Mapped[str] = mapped_column(String(200), default="gpt-4o-mini")
    updated_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now(), onupdate=func.now())


class VaultRecord(Base):
    __tablename__ = "vault_records"

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=lambda: str(uuid.uuid4()))
    record_type: Mapped[str] = mapped_column(String(50), index=True)
    title: Mapped[str] = mapped_column(String(255))
    username: Mapped[str | None] = mapped_column(String(255), nullable=True)
    description: Mapped[str] = mapped_column(Text)
    tags: Mapped[str] = mapped_column(Text, default="[]")
    fields_json: Mapped[str] = mapped_column(Text, default="{}")
    encrypted_password: Mapped[str] = mapped_column(Text)
    password_hash: Mapped[str] = mapped_column(Text)
    password_fingerprint: Mapped[str] = mapped_column(String(64), index=True)
    # TOTP seed for the record's verification codes — Fernet ciphertext of a
    # JSON payload (secret/issuer/account/digits/period/algorithm). Nullable:
    # records without two-step verification store nothing here. Server-side
    # hash/fingerprint are deliberately omitted: the server never verifies
    # TOTP codes and never searches by seed.
    totp_encrypted: Mapped[str | None] = mapped_column(Text, nullable=True)
    # Permission matrix (read-only/hide-secret/re-auth/AI access level) —
    # non-secret metadata on par with `tags`/`fields_json`. Enforcement lives
    # in the clients and MCP server until the API gains real authentication.
    permissions_json: Mapped[str | None] = mapped_column(Text, nullable=True)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())
    updated_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now(), onupdate=func.now())
