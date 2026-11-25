from __future__ import annotations

import json
import logging
from contextlib import asynccontextmanager
from pathlib import Path

import httpx
from fastapi import Depends, FastAPI, HTTPException, Query, Request
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import HTMLResponse, RedirectResponse
from sqlalchemy import or_, select
from sqlalchemy.orm import Session

from .ai import ai_service
from .audit import event_view, list_events, log_event
from .audit import stats as audit_stats
from .config import settings
from .database import Base, engine, get_db, migrate_sqlite
from .hardening import (
    MAX_REQUEST_BYTES,
    BodySizeLimitMiddleware,
    SecurityHeadersMiddleware,
    assert_production_keys,
    assert_safe_upstream_url,
    audit_ingest_rate_limit,
    dashboard_content_security_policy,
    gateway_rate_limit,
)
from .maintenance import rescrub_stored_fields
from .models import ProviderConfig, VaultRecord
from .risk import audit_vault, organization_report, password_strength
from .schemas import (
    AIGatewayStatusView,
    AuditEventIngest,
    ProviderSettingsPayload,
    ProviderSettingsView,
    RecordPermissionsPayload,
    SearchRequest,
    SearchResponse,
    TOTPPayload,
    VaultFieldPayload,
    VaultItemCreateRequest,
    VaultItemView,
    fields_from_json,
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

logger = logging.getLogger("secretbox.server")

_DASHBOARD_HTML = (Path(__file__).resolve().parent / "static" / "dashboard.html").read_text(encoding="utf-8")


@asynccontextmanager
async def lifespan(_: FastAPI) -> None:
    # Fail fast on the development keys before any table is touched.
    assert_production_keys()
    Base.metadata.create_all(bind=engine)
    migrate_sqlite()
    rescrub_stored_fields()
    storage_catalog.ensure_structures()
    logger.info("SecretBox server ready")
    yield


app = FastAPI(title="SecretBox Server", version="0.4.0", lifespan=lifespan)
if settings.cors_origins:
    # No wildcard: with `allow_origins=["*"]` any web page the operator opens
    # could read this server's responses (search returns plaintext) through
    # the browser. Cross-origin callers must be listed explicitly.
    app.add_middleware(
        CORSMiddleware,
        allow_origins=list(settings.cors_origins),
        allow_credentials=False,
        allow_methods=["GET", "POST", "PUT"],
        allow_headers=["Content-Type", "X-SecretBox-Actor"],
    )
app.add_middleware(BodySizeLimitMiddleware, max_bytes=MAX_REQUEST_BYTES)
app.add_middleware(
    SecurityHeadersMiddleware,
    headers={
        "Content-Security-Policy": dashboard_content_security_policy(_DASHBOARD_HTML),
        "X-Content-Type-Options": "nosniff",
        "X-Frame-Options": "DENY",
        "Referrer-Policy": "no-referrer",
        "Cache-Control": "no-store",
    },
)


@app.get("/health")
def health() -> dict[str, str]:
    return {"status": "ok"}


@app.get("/", include_in_schema=False)
def root() -> RedirectResponse:
    return RedirectResponse(url="/dashboard")


@app.get("/dashboard", response_class=HTMLResponse, include_in_schema=False)
def dashboard() -> HTMLResponse:
    return HTMLResponse(_DASHBOARD_HTML)


# ---------------------------------------------------------------------------
# AI gateway: clients (and the macOS/iOS app's "use server AI" option) send
# OpenAI-compatible chat requests here; the server attaches its own upstream
# key and forwards. The client never sees the provider key.
# ---------------------------------------------------------------------------


@app.get("/api/ai/status", response_model=AIGatewayStatusView)
def ai_status(db: Session = Depends(get_db)) -> AIGatewayStatusView:
    provider = db.get(ProviderConfig, 1)
    if provider is None:
        return AIGatewayStatusView(enabled=False)
    return AIGatewayStatusView(enabled=True, model=provider.model, base_url=provider.base_url)


@app.post("/ai/v1/chat/completions", dependencies=[Depends(gateway_rate_limit)])
async def ai_gateway_chat_completions(request: Request, db: Session = Depends(get_db)) -> dict:
    actor = (request.headers.get("x-secretbox-actor") or "client")[:255]
    provider = db.get(ProviderConfig, 1)
    if provider is None:
        log_event(
            db, action="ai_chat", actor=actor, actor_type="client", allowed=False,
            detail={"reason": "gateway not configured"},
        )
        raise HTTPException(
            status_code=503,
            detail="AI gateway is not configured. Set the provider via PUT /api/provider or the dashboard AI tab.",
        )
    # Belt and braces: the row was validated when it was stored, but a row
    # written by hand must not turn into a request to a metadata service.
    try:
        assert_safe_upstream_url(provider.base_url, resolve=False)
    except ValueError as error:
        log_event(
            db, action="ai_chat", actor=actor, actor_type="client", allowed=False,
            detail={"reason": "unsafe upstream", "error_type": "UnsafeUpstream"},
        )
        raise HTTPException(status_code=502, detail=str(error)) from error

    try:
        body = await request.json()
    except Exception:
        # A malformed body is the client's error; the parser traceback is noise.
        raise HTTPException(status_code=400, detail="Request body must be JSON.") from None
    if not isinstance(body, dict) or not isinstance(body.get("messages"), list):
        raise HTTPException(status_code=400, detail="OpenAI-compatible body with a `messages` array is required.")
    if body.get("stream"):
        raise HTTPException(status_code=400, detail="Streaming is not supported by the gateway; send stream=false.")
    requested_model = body.get("model")
    # The server-configured model is enforced for every forwarded call —
    # clients cannot pick an arbitrary (or costlier) upstream model.
    forwarded_body = {**body, "model": provider.model}

    try:
        result = await ai_service.forward_chat_completion(provider=provider, payload=forwarded_body)
    except httpx.HTTPStatusError as error:
        log_event(
            db, action="ai_chat", actor=actor, actor_type="client", allowed=False,
            detail={"reason": "upstream error", "status": error.response.status_code},
        )
        raise HTTPException(status_code=502, detail=f"Upstream AI provider returned {error.response.status_code}.") from error
    except httpx.HTTPError as error:
        log_event(
            db, action="ai_chat", actor=actor, actor_type="client", allowed=False,
            detail={"reason": "upstream unreachable", "error_type": type(error).__name__},
        )
        raise HTTPException(status_code=504, detail="Upstream AI provider could not be reached.") from error

    usage = (result.get("usage") or {}) if isinstance(result, dict) else {}
    log_event(
        db, action="ai_chat", actor=actor, actor_type="client", allowed=True,
        detail={
            "model": provider.model,
            "requested_model": requested_model if requested_model and requested_model != provider.model else None,
            "prompt_tokens": usage.get("prompt_tokens"),
            "completion_tokens": usage.get("completion_tokens"),
        },
    )
    return result


# ---------------------------------------------------------------------------
# Audit trail. `POST /api/audit` is the ingest point for agent-side tools
# (e.g. the MCP server reporting every tool call); the GETs power the
# dashboard's Agent Audit tab.
# ---------------------------------------------------------------------------


@app.get("/api/audit")
def list_audit_events(
    db: Session = Depends(get_db),
    limit: int = Query(default=50, ge=1, le=500),
    offset: int = Query(default=0, ge=0),
    action: str | None = Query(default=None),
    actor_type: str | None = Query(default=None),
    allowed: bool | None = Query(default=None),
) -> dict:
    events = list_events(db, limit=limit, offset=offset, action=action, actor_type=actor_type, allowed=allowed)
    return {
        "events": [event_view(event) for event in events],
        "limit": limit,
        "offset": offset,
    }


@app.get("/api/audit/stats")
def audit_stats_endpoint(db: Session = Depends(get_db)) -> dict:
    return audit_stats(db)


@app.post("/api/audit", status_code=202, dependencies=[Depends(audit_ingest_rate_limit)])
def ingest_audit_event(payload: AuditEventIngest, db: Session = Depends(get_db)) -> dict:
    event = log_event(
        db,
        action=payload.action,
        actor=payload.actor,
        actor_type=payload.actor_type,
        record_id=payload.record_id,
        allowed=payload.allowed,
        detail=payload.detail,
        occurred_at=payload.occurred_at,
    )
    return {"accepted": True, "id": event.id}


# ---------------------------------------------------------------------------
# Dashboard data endpoints (overview / security review / organization).
# ---------------------------------------------------------------------------


@app.get("/api/dashboard/overview")
def dashboard_overview(db: Session = Depends(get_db)) -> dict:
    records = list(db.scalars(select(VaultRecord)))
    provider = db.get(ProviderConfig, 1)
    organization = organization_report(records)
    return {
        "records": {
            "total": len(records),
            "by_type": organization["by_type"],
            "by_template": organization["by_template"],
            "top_tags": organization["top_tags"],
            "totp_enabled": sum(1 for record in records if record.totp_encrypted),
            "duplicates": len(organization["duplicate_titles"]),
        },
        "ai": {
            "configured": provider is not None,
            "model": provider.model if provider else None,
        },
        "audit_stats": audit_stats(db),
    }


@app.get("/api/dashboard/security")
def dashboard_security(db: Session = Depends(get_db)) -> dict:
    records = list(db.scalars(select(VaultRecord)))
    report = audit_vault(records)
    report.pop("records", None)  # the per-record table lives on the records tab
    return report


@app.get("/api/dashboard/organization")
def dashboard_organization(db: Session = Depends(get_db)) -> dict:
    records = list(db.scalars(select(VaultRecord)))
    return organization_report(records)


# ---------------------------------------------------------------------------
# Records inventory + per-record permission matrix management (dashboard).
# ---------------------------------------------------------------------------


@app.get("/api/records")
def list_records(db: Session = Depends(get_db)) -> list[dict]:
    records = db.scalars(select(VaultRecord).order_by(VaultRecord.created_at.desc())).all()
    fingerprint_counts: dict[str, int] = {}
    for record in records:
        fingerprint_counts[record.password_fingerprint] = fingerprint_counts.get(record.password_fingerprint, 0) + 1
    items: list[dict] = []
    for record in records:
        view = build_item_view(record, include_secret=False)
        try:
            strength = password_strength(decrypt_password(record.encrypted_password)).as_dict()
        except Exception:
            strength = {"score": None, "label": "unknown", "reasons": ["could not be decrypted with the current key"]}
        strength["reused"] = fingerprint_counts.get(record.password_fingerprint, 1) > 1
        items.append(
            {
                **view.model_dump(mode="json"),
                "totp_enabled": bool(record.totp_encrypted),
                "updated_at": record.updated_at,
                "strength": strength,
            }
        )
    return items


@app.put("/api/records/{record_id}/permissions", response_model=VaultItemView)
def update_record_permissions(
    record_id: str,
    payload: RecordPermissionsPayload,
    db: Session = Depends(get_db),
) -> VaultItemView:
    record = db.get(VaultRecord, record_id)
    if record is None:
        raise HTTPException(status_code=404, detail="Record not found")
    record.permissions_json = json.dumps(payload.model_dump(mode="json"))
    db.commit()
    db.refresh(record)
    log_event(
        db,
        action="permissions_update",
        actor_type="dashboard",
        actor="dashboard",
        record_id=record.id,
        detail={
            "ai_access": payload.ai_access,
            "read_only": payload.read_only,
            "hide_secret": payload.hide_secret,
            "require_reauth": payload.require_reauth,
        },
    )
    return build_item_view(record)


@app.get("/api/provider", response_model=ProviderSettingsView)
def get_provider(db: Session = Depends(get_db)) -> ProviderSettingsView:
    provider = db.get(ProviderConfig, 1)
    if provider is None:
        return ProviderSettingsView(configured=False)
    return ProviderSettingsView(configured=True, base_url=provider.base_url, model=provider.model)


@app.put("/api/provider", response_model=ProviderSettingsView)
def put_provider(payload: ProviderSettingsPayload, db: Session = Depends(get_db)) -> ProviderSettingsView:
    # The base URL is stored and later requested with the API key attached;
    # refuse anything that is not a plausible model endpoint before storing.
    try:
        assert_safe_upstream_url(payload.base_url)
    except ValueError as error:
        raise HTTPException(status_code=422, detail=str(error)) from error

    provider = db.get(ProviderConfig, 1)
    if provider is None:
        provider = ProviderConfig(id=1, base_url=payload.base_url, api_key=payload.api_key, model=payload.model)
        db.add(provider)
    else:
        provider.base_url = payload.base_url
        provider.api_key = payload.api_key
        provider.model = payload.model
    db.commit()
    log_event(db, action="provider_update", actor="api", allowed=True, detail={"model": provider.model})
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
    log_event(
        db, action="record_create", actor="api", record_id=record.id,
        detail={"item_type": record.record_type, "title": record.title},
    )
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
    log_event(
        db, action="record_update", actor="api", record_id=record.id,
        detail={"item_type": record.record_type, "title": record.title},
    )
    return build_item_view(record, include_secret=True)


@app.post("/api/search", response_model=SearchResponse)
async def search_records(payload: SearchRequest, db: Session = Depends(get_db)) -> SearchResponse:
    fingerprint = query_fingerprint(payload.query)
    exact_matches = list(db.scalars(select(VaultRecord).where(VaultRecord.password_fingerprint == fingerprint).limit(payload.limit)))
    if exact_matches:
        # The query text is deliberately absent from the audit detail: in this
        # branch the query IS the plaintext password.
        log_event(
            db, action="search", actor="api",
            detail={"mode": "exact_fingerprint", "results": len(exact_matches)},
        )
        return SearchResponse(
            results=[
                build_item_view(match, include_secret=True, match_reason="exact secret fingerprint match")
                for match in exact_matches
            ]
        )

    # `%` and `_` are LIKE wildcards: unescaped, a query of "%" would match the
    # whole vault. They only ever match themselves.
    searchable_columns = (
        VaultRecord.description,
        VaultRecord.title,
        VaultRecord.record_type,
        VaultRecord.username,
        VaultRecord.fields_json,
    )
    statements = [
        select(VaultRecord).where(or_(*(column.ilike(f"%{_escape_like(payload.query)}%", escape="\\") for column in searchable_columns)))
    ]
    # Natural-language queries ("增长后台的登录密码") rarely appear verbatim in a
    # record, so recall per query token as well; ranking stays in rerank_candidates.
    tokens = [_escape_like(token) for token in ai_service._query_tokens(payload.query)[:24]]
    if tokens:
        statements.append(
            select(VaultRecord).where(or_(*(column.ilike(f"%{token}%", escape="\\") for token in tokens for column in searchable_columns)))
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
        # Nothing matched. There is deliberately no "return something anyway"
        # fallback: results carry plaintext, so an unrelated record must never
        # be handed out for a query that did not match it.
        log_event(db, action="search", actor="api", detail={"mode": "semantic", "results": 0})
        return SearchResponse(results=[])
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
    log_event(
        db, action="search", actor="api",
        detail={"mode": "semantic", "results": len(ordered_results)},
    )
    return SearchResponse(results=ordered_results)


def _escape_like(text: str) -> str:
    """Escape SQL LIKE wildcards (and the escape character) so user input can
    only match itself."""
    return text.replace("\\", "\\\\").replace("%", "\\%").replace("_", "\\_")


def build_item_view(
    record: VaultRecord,
    *,
    include_secret: bool = False,
    match_reason: str | None = None,
) -> VaultItemView:
    template_type, fields = fields_from_json(record.fields_json)
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
        primary_secret=decrypt_password(record.encrypted_password) if include_secret else None,
        totp=totp,
        permissions=permissions,
        created_at=record.created_at,
        match_reason=match_reason,
    )


def field_value(fields: list[VaultFieldPayload], key: str) -> str | None:
    for field in fields:
        if field.key == key or field.semantic == key:
            return field.value or None
    return None
