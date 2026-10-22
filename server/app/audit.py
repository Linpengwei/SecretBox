from __future__ import annotations

import json
from datetime import datetime, timedelta, timezone

from sqlalchemy import func, select
from sqlalchemy.orm import Session

from .models import AuditEvent

# Keys that must never be persisted inside an audit detail payload. Search
# queries top the list: in exact-match mode the query IS the plaintext
# password, so the audit trail only records that a query happened, never its
# text. Secret-shaped keys are belt-and-braces for client-supplied details.
REDACTED_DETAIL_KEYS = {
    "query", "password", "passwd", "secret", "primary_secret", "api_key",
    "apikey", "token", "messages", "prompt", "pasted_text", "totp_secret",
}
_REDACTED_PLACEHOLDER = "[REDACTED]"


def safe_detail(detail: dict | None) -> dict:
    """Deep-copy a detail dict with secret-shaped keys redacted."""
    if not detail:
        return {}

    def _scrub(value: object) -> object:
        if isinstance(value, dict):
            return {
                key: _REDACTED_PLACEHOLDER if str(key).lower() in REDACTED_DETAIL_KEYS else _scrub(item)
                for key, item in value.items()
            }
        if isinstance(value, list):
            return [_scrub(item) for item in value]
        return value

    return _scrub(detail)


def log_event(
    db: Session,
    *,
    action: str,
    actor: str = "server",
    actor_type: str = "server",
    record_id: str | None = None,
    allowed: bool = True,
    detail: dict | None = None,
    occurred_at: datetime | None = None,
) -> AuditEvent:
    event = AuditEvent(
        actor_type=actor_type,
        actor=actor[:255],
        action=action[:64],
        record_id=record_id,
        allowed=allowed,
        detail_json=json.dumps(safe_detail(detail)),
        **({"ts": occurred_at} if occurred_at else {}),
    )
    db.add(event)
    db.commit()
    return event


def event_view(event: AuditEvent) -> dict:
    try:
        detail = json.loads(event.detail_json or "{}")
    except Exception:
        detail = {}
    return {
        "id": event.id,
        "ts": event.ts,
        "actor_type": event.actor_type,
        "actor": event.actor,
        "action": event.action,
        "record_id": event.record_id,
        "allowed": event.allowed,
        "detail": detail,
    }


def list_events(
    db: Session,
    *,
    limit: int = 50,
    offset: int = 0,
    action: str | None = None,
    actor_type: str | None = None,
    allowed: bool | None = None,
) -> list[AuditEvent]:
    statement = select(AuditEvent).order_by(AuditEvent.id.desc())
    if action:
        statement = statement.where(AuditEvent.action == action)
    if actor_type:
        statement = statement.where(AuditEvent.actor_type == actor_type)
    if allowed is not None:
        statement = statement.where(AuditEvent.allowed.is_(allowed))
    return list(db.scalars(statement.limit(limit).offset(offset)))


def stats(db: Session, *, window_hours: int = 24, sample_cap: int = 5000) -> dict:
    """Aggregate counts for the dashboard: totals, per-action breakdown, and a
    trailing hourly activity series. Totals come from SQL aggregates; the
    breakdowns aggregate a capped recent sample in Python (the log is append
    only, so the tail is what the dashboard shows anyway)."""
    since = datetime.now(timezone.utc).replace(tzinfo=None) - timedelta(hours=window_hours)
    total = db.scalar(select(func.count(AuditEvent.id))) or 0
    recent = db.scalar(
        select(func.count(AuditEvent.id)).where(AuditEvent.ts >= since)
    ) or 0
    denied = db.scalar(
        select(func.count(AuditEvent.id)).where(AuditEvent.allowed.is_(False))
    ) or 0

    sample = db.scalars(
        select(AuditEvent).order_by(AuditEvent.id.desc()).limit(sample_cap)
    ).all()

    per_action: dict[str, int] = {}
    per_actor: dict[str, int] = {}
    counts_by_hour: dict[str, int] = {}
    for event in sample:
        per_action[event.action] = per_action.get(event.action, 0) + 1
        ts = event.ts
        if ts.tzinfo is not None:
            ts = ts.replace(tzinfo=None)
        if ts >= since:
            per_actor[event.actor] = per_actor.get(event.actor, 0) + 1
            key = ts.strftime("%Y-%m-%dT%H:00:00")
            counts_by_hour[key] = counts_by_hour.get(key, 0) + 1

    # Zero-fill every hour in the window so the dashboard sparkline has no gaps.
    filled: list[dict] = []
    now_hour = datetime.now(timezone.utc).replace(minute=0, second=0, microsecond=0)
    for step in range(window_hours, -1, -1):
        bucket_dt = now_hour - timedelta(hours=step)
        key = bucket_dt.strftime("%Y-%m-%dT%H:00:00")
        filled.append({"hour": key, "count": counts_by_hour.get(key, 0)})

    return {
        "total": total,
        "last_24h": recent,
        "denied": denied,
        "per_action": per_action,
        "per_actor_recent": per_actor,
        "hourly": filled,
    }
