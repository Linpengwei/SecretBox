from __future__ import annotations

import json

from fastapi import Depends, FastAPI, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from sqlalchemy import or_, select
from sqlalchemy.orm import Session

from .ai import ai_service
from .database import Base, engine, get_db, migrate_sqlite
from .models import ProviderConfig, VaultRecord
from .schemas import (
    ProviderSettingsPayload,
    ProviderSettingsView,
    RecordPermissionsPayload,
    SearchRequest,
    SearchResponse,
    TOTPPayload,
    VaultFieldPayload,
    VaultItemCreateRequest,
    VaultItemView,
)
from .security import (
    decrypt_password,
    decrypt_totp,
    encrypt_totp,
    protect_password,
    query_fingerprint,
    scrub_totp_uris,
)
from .storage import storage_catalog

app = FastAPI(title="SecretBox Server", version="0.2.0")
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)


@app.on_event("startup")
def on_startup() -> None:
    Base.metadata.create_all(bind=engine)
    migrate_sqlite()
    storage_catalog.ensure_structures()


@app.get("/health")
def health() -> dict[str, str]:
    return {"status": "ok"}


@app.get("/api/provider", response_model=ProviderSettingsView)
def get_provider(db: Session = Depends(get_db)) -> ProviderSettingsView:
    provider = db.get(ProviderConfig, 1)
    if provider is None:
        return ProviderSettingsView(configured=False)
    return ProviderSettingsView(configured=True, base_url=provider.base_url, model=provider.model)


@app.put("/api/provider", response_model=ProviderSettingsView)
def put_provider(payload: ProviderSettingsPayload, db: Session = Depends(get_db)) -> ProviderSettingsView:
    provider = db.get(ProviderConfig, 1)
    if provider is None:
        provider = ProviderConfig(id=1, base_url=payload.base_url, api_key=payload.api_key, model=payload.model)
        db.add(provider)
    else:
        provider.base_url = payload.base_url
        provider.api_key = payload.api_key
        provider.model = payload.model
    db.commit()
    return ProviderSettingsView(configured=True, base_url=provider.base_url, model=provider.model)


@app.post("/api/records", response_model=VaultItemView)
async def create_record(payload: VaultItemCreateRequest, db: Session = Depends(get_db)) -> VaultItemView:
    # Route any otpauth:// Key URI out of the pasted text first: the seed
    # must land in the encrypted column and can never flow into AI context.
    pasted_text, embedded_totp = scrub_totp_uris(payload.pasted_text or "")
    totp_payload = payload.totp.model_dump(mode="json") if payload.totp else embedded_totp

    parsed = ai_service.parse_pasted_secret(pasted_text)
    primary_secret = payload.primary_secret or parsed.primary_secret
    if not primary_secret:
        raise HTTPException(status_code=400, detail="Unable to find a password or secret in the pasted text.")
    merged_fields = ai_service.sanitize_fields(ai_service._merge_fields(parsed.fields, payload.fields), primary_secret)

    provider = db.get(ProviderConfig, 1)
    enriched = await ai_service.enrich_item(
        provider=provider,
        item_type=payload.item_type if payload.fields or payload.template_type or payload.name else parsed.item_type,
        template_type=payload.template_type or parsed.template_type,
        name=payload.name or parsed.name,
        primary_secret=primary_secret,
        pasted_text=parsed.redacted_excerpt or pasted_text,
        notes=payload.notes or parsed.notes,
        tags=payload.tags or parsed.tags,
        fields=merged_fields,
    )
    protected = protect_password(primary_secret)
    record = VaultRecord(
        record_type=enriched.item_type,
        title=enriched.name,
        username=field_value(enriched.fields, "username"),
        description=enriched.notes,
        tags=json.dumps(enriched.tags),
        fields_json=json.dumps(
            {
                "template_type": enriched.template_type,
                "fields": [field.model_dump(mode="json") for field in enriched.fields],
            }
        ),
        encrypted_password=protected.encrypted_password,
        password_hash=protected.password_hash,
        password_fingerprint=protected.password_fingerprint,
        totp_encrypted=encrypt_totp(totp_payload) if totp_payload else None,
        permissions_json=json.dumps(payload.permissions.model_dump(mode="json")) if payload.permissions else None,
    )
    db.add(record)
    db.commit()
    db.refresh(record)
    return build_item_view(record, include_secret=True)


@app.put("/api/records/{record_id}", response_model=VaultItemView)
async def update_record(record_id: str, payload: VaultItemCreateRequest, db: Session = Depends(get_db)) -> VaultItemView:
    record = db.get(VaultRecord, record_id)
    if record is None:
        raise HTTPException(status_code=404, detail="Record not found")

    # Same red-line scrub as create: the seed never flows past this point.
    pasted_text, embedded_totp = scrub_totp_uris(payload.pasted_text or "")

    parsed = ai_service.parse_pasted_secret(pasted_text)
    existing_secret = decrypt_password(record.encrypted_password)
    primary_secret = payload.primary_secret or parsed.primary_secret or existing_secret
    if not primary_secret:
        raise HTTPException(status_code=400, detail="Unable to resolve a password or secret for this update.")
    merged_fields = ai_service.sanitize_fields(ai_service._merge_fields(parsed.fields, payload.fields), primary_secret)

    provider = db.get(ProviderConfig, 1)
    enriched = await ai_service.enrich_item(
        provider=provider,
        item_type=payload.item_type if payload.fields or payload.template_type or payload.name else parsed.item_type,
        template_type=payload.template_type or parsed.template_type,
        name=payload.name or parsed.name,
        primary_secret=primary_secret,
        pasted_text=parsed.redacted_excerpt or pasted_text,
        notes=payload.notes or parsed.notes,
        tags=payload.tags or parsed.tags,
        fields=merged_fields,
    )
    protected = protect_password(primary_secret)

    record.record_type = enriched.item_type
    record.title = enriched.name
    record.username = field_value(enriched.fields, "username")
    record.description = enriched.notes
    record.tags = json.dumps(enriched.tags)
    record.fields_json = json.dumps(
        {
            "template_type": enriched.template_type,
            "fields": [field.model_dump(mode="json") for field in enriched.fields],
        }
    )
    record.encrypted_password = protected.encrypted_password
    record.password_hash = protected.password_hash
    record.password_fingerprint = protected.password_fingerprint
    if payload.totp is not None:
        record.totp_encrypted = encrypt_totp(payload.totp.model_dump(mode="json"))
    elif embedded_totp is not None:
        record.totp_encrypted = encrypt_totp(embedded_totp)
    elif payload.remove_totp:
        record.totp_encrypted = None
    if payload.permissions is not None:
        record.permissions_json = json.dumps(payload.permissions.model_dump(mode="json"))
    db.commit()
    db.refresh(record)
    return build_item_view(record, include_secret=True)


@app.post("/api/search", response_model=SearchResponse)
async def search_records(payload: SearchRequest, db: Session = Depends(get_db)) -> SearchResponse:
    fingerprint = query_fingerprint(payload.query)
    exact_matches = list(db.scalars(select(VaultRecord).where(VaultRecord.password_fingerprint == fingerprint).limit(payload.limit)))
    if exact_matches:
        return SearchResponse(
            results=[
                build_item_view(match, include_secret=True, match_reason="exact secret fingerprint match")
                for match in exact_matches
            ]
        )

    searchable_columns = (
        VaultRecord.description,
        VaultRecord.title,
        VaultRecord.record_type,
        VaultRecord.username,
        VaultRecord.fields_json,
    )
    statements = [
        select(VaultRecord).where(or_(*(column.ilike(f"%{payload.query}%") for column in searchable_columns)))
    ]
    # Natural-language queries ("增长后台的登录密码") rarely appear verbatim in a
    # record, so recall per query token as well; ranking stays in rerank_candidates.
    tokens = ai_service._query_tokens(payload.query)[:24]
    if tokens:
        statements.append(
            select(VaultRecord).where(or_(*(column.ilike(f"%{token}%") for token in tokens for column in searchable_columns)))
        )
    candidates: list[VaultRecord] = []
    seen_ids: set[str] = set()
    for statement in statements:
        # Cap high enough that popular-token OR matches don't crowd out the
        # target before ranking; ordering is rerank_candidates' job.
        statement = statement.limit(200)
        for record in db.scalars(statement):
            if record.id not in seen_ids:
                seen_ids.add(record.id)
                candidates.append(record)
    if not candidates:
        candidates = list(db.scalars(select(VaultRecord).limit(payload.limit * 3)))
    provider = db.get(ProviderConfig, 1)
    ranked = await ai_service.rerank_candidates(provider=provider, query=payload.query, candidates=candidates)
    candidates_by_id = {candidate.id: candidate for candidate in candidates}
    ordered_results = []
    for record_id, reason in ranked:
        candidate = candidates_by_id.get(record_id)
        if candidate is None:
            continue
        ordered_results.append(build_item_view(candidate, include_secret=True, match_reason=reason))
        if len(ordered_results) >= payload.limit:
            break
    return SearchResponse(results=ordered_results)


def build_item_view(
    record: VaultRecord,
    *,
    include_secret: bool = False,
    match_reason: str | None = None,
) -> VaultItemView:
    template_type, fields = unpack_fields(record.fields_json)
    totp = None
    if include_secret and record.totp_encrypted:
        totp_data = decrypt_totp(record.totp_encrypted)
        if totp_data is not None:
            totp = TOTPPayload(**totp_data)
    permissions = None
    if record.permissions_json:
        try:
            permissions = RecordPermissionsPayload(**json.loads(record.permissions_json))
        except Exception:
            permissions = None
    return VaultItemView(
        id=record.id,
        item_type=record.record_type,
        template_type=template_type,
        name=record.title,
        subtitle=field_value(fields, "username") or field_value(fields, "host") or field_value(fields, "service"),
        notes=record.description,
        tags=json.loads(record.tags or "[]"),
        fields=fields,
        password_hash=record.password_hash,
        password_fingerprint=record.password_fingerprint,
        primary_secret=decrypt_password(record.encrypted_password) if include_secret else None,
        totp=totp,
        permissions=permissions,
        created_at=record.created_at,
        match_reason=match_reason,
    )


def unpack_fields(raw_fields: str | None) -> tuple[str | None, list[VaultFieldPayload]]:
    if not raw_fields:
        return None, []

    parsed = json.loads(raw_fields)
    if isinstance(parsed, dict) and "fields" in parsed:
        return parsed.get("template_type"), [VaultFieldPayload(**field) for field in parsed.get("fields", [])]

    if isinstance(parsed, dict):
        legacy_fields = []
        for order, (key, value) in enumerate(parsed.items()):
            if key in {"password_shape", "source_excerpt"}:
                continue
            legacy_fields.append(
                VaultFieldPayload(
                    key=key,
                    label=key.replace("_", " ").title(),
                    value=str(value),
                    value_type="text",
                    semantic=key,
                    hidden=False,
                    section="Details",
                    order=order,
                )
            )
        return None, legacy_fields

    return None, []


def field_value(fields: list[VaultFieldPayload], key: str) -> str | None:
    for field in fields:
        if field.key == key or field.semantic == key:
            return field.value or None
    return None
