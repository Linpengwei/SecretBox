"""One-pass startup maintenance that brings stored data in line with the
current redaction rules."""
from __future__ import annotations

import json
import logging

from sqlalchemy import select
from sqlalchemy.orm import Session

from .ai import ai_service
from .database import SessionLocal
from .models import VaultRecord
from .schemas import fields_from_json
from .security import decrypt_password

logger = logging.getLogger("secretbox.maintenance")


def rescrub_stored_fields(session: Session | None = None) -> int:
    """Re-apply the write-path field rules (`AIService.sanitize_fields`) to
    every stored record.

    Records written before the structural scrub existed can still hold a
    secondary secret in a `source_excerpt` or a percent-encoded password in a
    URL field. This touches stored fields only — hand-written notes are
    deliberately left alone. Idempotent: a second startup finds nothing to
    change. Returns the number of records rewritten.
    """
    owns_session = session is None
    session = session or SessionLocal()
    changed = 0
    try:
        for record in session.scalars(select(VaultRecord)):
            template_type, fields = fields_from_json(record.fields_json)
            try:
                secret: str | None = decrypt_password(record.encrypted_password)
            except Exception:
                # Undecryptable with the current key: still scrub what the
                # structural rules can reach (URI credentials, secret-class keys).
                secret = None
            cleaned = ai_service.sanitize_fields(fields, secret)
            if [field.model_dump(mode="json") for field in cleaned] == [field.model_dump(mode="json") for field in fields]:
                continue
            record.fields_json = json.dumps(
                {"template_type": template_type, "fields": [field.model_dump(mode="json") for field in cleaned]}
            )
            changed += 1
        session.commit()
    finally:
        if owns_session:
            session.close()

    if changed:
        logger.warning(
            "Re-scrubbed the stored fields of %d record(s); they predated the structural redaction.",
            changed,
        )
    return changed
