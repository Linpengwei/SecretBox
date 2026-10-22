from __future__ import annotations

import base64
from datetime import datetime

from pydantic import BaseModel, Field, field_validator


class ProviderSettingsPayload(BaseModel):
    base_url: str
    api_key: str
    model: str = "gpt-4o-mini"


class ProviderSettingsView(BaseModel):
    configured: bool
    base_url: str | None = None
    model: str | None = None


class VaultFieldPayload(BaseModel):
    key: str
    label: str
    value: str = ""
    value_type: str = "text"
    semantic: str | None = None
    hidden: bool = False
    section: str | None = None
    order: int = 0


class TOTPPayload(BaseModel):
    """TOTP seed for a record's verification codes. Secret-class data: the
    server stores it only as `totp_encrypted` ciphertext and must never let
    it reach the AI service or any redacted context."""

    secret: str = Field(min_length=8)
    issuer: str | None = None
    account: str | None = None
    digits: int = Field(default=6, ge=6, le=8)
    period: int = Field(default=30, ge=15, le=120)
    algorithm: str = Field(default="SHA1", pattern="^(SHA1|SHA256|SHA512)$")

    @field_validator("secret")
    @classmethod
    def _secret_must_be_base32(cls, value: str) -> str:
        normalized = value.replace(" ", "").replace("-", "").upper()
        padded = normalized + "=" * ((8 - len(normalized) % 8) % 8)
        try:
            base64.b32decode(padded)
        except Exception as error:  # binascii.Error / ValueError on garbage
            raise ValueError("TOTP secret must be RFC 4648 base32") from error
        return normalized


class RecordPermissionsPayload(BaseModel):
    """Per-record permission matrix (Bitwarden-style granular access).
    Non-secret metadata; enforced client-side and by the MCP server."""

    read_only: bool = False
    hide_secret: bool = False
    require_reauth: bool = False
    ai_access: str = Field(default="none", pattern="^(none|metadata|metadata_and_tools)$")
    subjects: list[dict[str, str]] | None = None


class VaultItemCreateRequest(BaseModel):
    item_type: str = "secret"
    template_type: str | None = None
    name: str | None = None
    pasted_text: str | None = None
    primary_secret: str | None = Field(default=None, min_length=1)
    notes: str | None = None
    tags: list[str] = Field(default_factory=list)
    fields: list[VaultFieldPayload] = Field(default_factory=list)
    # Absent `totp` on update keeps the stored seed; `remove_totp` clears it.
    totp: TOTPPayload | None = None
    remove_totp: bool = False
    permissions: RecordPermissionsPayload | None = None


class VaultItemView(BaseModel):
    id: str
    item_type: str
    template_type: str | None = None
    name: str
    subtitle: str | None = None
    notes: str
    tags: list[str]
    fields: list[VaultFieldPayload]
    password_hash: str
    password_fingerprint: str
    primary_secret: str | None = None
    totp: TOTPPayload | None = None
    permissions: RecordPermissionsPayload | None = None
    created_at: datetime | None = None
    match_reason: str | None = None


class SearchRequest(BaseModel):
    query: str = Field(min_length=1)
    limit: int = Field(default=5, ge=1, le=20)


class SearchResponse(BaseModel):
    results: list[VaultItemView]


class AIGatewayStatusView(BaseModel):
    """What clients probe to decide whether the "use server AI" option is
    available. `base_url` is the configured upstream (host only carries no
    secret); the API key itself is never included."""

    enabled: bool
    model: str | None = None
    base_url: str | None = None
    gateway_path: str = "/ai/v1/chat/completions"
    enforced_model: bool = True


class AuditEventIngest(BaseModel):
    """Agent/client-side audit report pushed to the server (e.g. from the MCP
    server after each tool call). Detail goes through `safe_detail` before
    storage — secret-shaped keys are redacted server-side regardless."""

    actor: str = Field(default="unknown-agent", max_length=255)
    actor_type: str = Field(default="agent", max_length=32)
    action: str = Field(max_length=64)
    record_id: str | None = None
    allowed: bool = True
    detail: dict[str, object] | None = None
    occurred_at: datetime | None = None
