from __future__ import annotations

import json
import re
from dataclasses import dataclass
from datetime import datetime, timedelta

from .models import VaultRecord
from .security import decrypt_password

# Offline password strength heuristics for the security-risk review. The
# plaintext is decrypted in server memory only to compute the verdict; scores,
# reasons and record identities are the only things this module ever returns —
# never the password itself, and nothing here is ever sent to the AI service.

COMMON_PASSWORDS = {
    "123456", "password", "123456789", "12345678", "12345", "qwerty",
    "1234567890", "1234567", "111111", "123123", "abc123", "password1",
    "1234", "qwerty123", "000000", "iloveyou", "123321", "654321", "666666",
    "123qwe", "qwertyuiop", "123123123", "121212", "asdasd", "88888888",
    "admin", "admin123", "root", "passw0rd", "p@ssw0rd", "letmein",
    "welcome", "monkey", "dragon", "sunshine", "princess", "football",
    "secret", "1q2w3e4r", "1qaz2wsx", "qazwsx", "zxcvbnm", "trustno1",
    "aaaaaa", "asdfgh", "112233", "1234qwer", "superman", "batman",
}

COMMON_WORDS = (
    "password", "passwd", "admin", "secret", "welcome", "letmein",
    "iloveyou", "qwerty", "login", "master", "hello", "test", "guest",
)

KEYBOARD_ROWS = ("qwertyuiop", "asdfghjkl", "zxcvbnm", "1234567890")

_ALPHABET_RUNS = ["".join(chr(code) for code in range(start, start + 26)) for start in (ord("a"), ord("0"))]


def _has_run(lowered: str, runs: tuple[str, ...] | list[str], min_len: int = 4) -> bool:
    for run in runs:
        for index in range(len(run) - min_len + 1):
            chunk = run[index : index + min_len]
            if chunk in lowered or chunk[::-1] in lowered:
                return True
    return False


def _sequential_chars(password: str, min_len: int = 4) -> bool:
    ascending = descending = 1
    for previous, current in zip(password, password[1:]):
        if ord(current) - ord(previous) == 1:
            ascending += 1
            descending = 1
        elif ord(previous) - ord(current) == 1:
            descending += 1
            ascending = 1
        else:
            ascending = descending = 1
        if ascending >= min_len or descending >= min_len:
            return True
    return False


@dataclass(slots=True)
class StrengthVerdict:
    score: int
    label: str
    reasons: list[str]

    def as_dict(self) -> dict:
        return {"score": self.score, "label": self.label, "reasons": self.reasons}


def password_strength(password: str) -> StrengthVerdict:
    """Heuristic 0-100 score with human-readable reasons. Mirrors the checks a
    reviewer would run by hand: length, charset mix, common passwords,
    keyboard/sequential runs, repeats, and date-like patterns."""
    reasons: list[str] = []
    score = 100
    length = len(password)

    if length < 8:
        score -= 55
        reasons.append(f"only {length} characters")
    elif length < 12:
        score -= 25
        reasons.append("shorter than 12 characters")
    elif length >= 16:
        score += 10

    has_upper = any(ch.isupper() for ch in password)
    has_lower = any(ch.islower() for ch in password)
    has_digit = any(ch.isdigit() for ch in password)
    has_symbol = any(not ch.isalnum() for ch in password)
    classes = sum((has_upper, has_lower, has_digit, has_symbol))
    if classes == 1:
        score -= 35
        reasons.append("single character class (e.g. letters only)")
    else:
        score -= (4 - classes) * 6
        if not has_digit:
            reasons.append("no digits")
        if not has_symbol and length < 16:
            reasons.append("no symbols")

    lowered = password.lower()
    if lowered in COMMON_PASSWORDS:
        score = min(score, 5)
        reasons.append("on the list of most common passwords")
    else:
        for word in COMMON_WORDS:
            if word in lowered and length <= len(word) + 4:
                score -= 25
                reasons.append(f"built around the common word {word!r}")
                break

    if password.isdigit():
        score -= 25
        reasons.append("digits only")
        if re.search(r"(19|20)\d{2}", password):
            reasons.append("looks like a year/date")
    elif re.search(r"(19|20)\d{2}", password):
        score -= 10
        reasons.append("contains a year (possible birthday/date)")

    if _has_run(lowered, KEYBOARD_ROWS):
        score -= 30
        reasons.append("keyboard run (qwerty-style)")
    if _has_run(lowered, _ALPHABET_RUNS):
        score -= 25
        reasons.append("alphabet run (abcd-style)")
    if _sequential_chars(password):
        score -= 20
        reasons.append("sequential characters")

    if re.search(r"(.)\1{2,}", password):
        score -= 15
        reasons.append("repeated character run")
    if re.search(r"(.{1,4})\1{1,}", password):
        score -= 10
        reasons.append("repeating pattern")

    score = max(0, min(100, score))
    label = "weak" if score < 35 else ("fair" if score < 70 else "strong")
    return StrengthVerdict(score=score, label=label, reasons=reasons)


def _record_identity(record: VaultRecord) -> dict:
    template = None
    if record.fields_json:
        try:
            parsed = json.loads(record.fields_json)
            template = parsed.get("template_type") if isinstance(parsed, dict) else None
        except Exception:
            template = None
    return {
        "id": record.id,
        "name": record.title,
        "type": record.record_type,
        "template_type": template,
        "username": record.username,
    }


def audit_vault(records: list[VaultRecord], *, stale_days: int = 180) -> dict:
    """Full security-risk review over the vault. Plaintext secrets exist only
    inside this function's loop; every finding carries record identities and
    verdicts, never secret material."""
    findings: list[dict] = []
    per_record: list[dict] = []
    weak_ids: list[dict] = []
    fair_count = strong_count = 0
    score_sum = 0
    undecryptable = 0
    reuse_groups: dict[str, list[dict]] = {}
    stale_cutoff = datetime.utcnow() - timedelta(days=stale_days)

    for record in records:
        try:
            plaintext = decrypt_password(record.encrypted_password)
        except Exception:
            undecryptable += 1
            continue
        verdict = password_strength(plaintext)
        identity = _record_identity(record)
        entry = {
            **identity,
            "strength": verdict.as_dict(),
            "reused": False,
            "stale": False,
            "totp_enabled": bool(record.totp_encrypted),
            "updated_at": record.updated_at,
        }
        per_record.append(entry)
        score_sum += verdict.score
        if verdict.label == "weak":
            weak_ids.append(identity)
        elif verdict.label == "fair":
            fair_count += 1
        else:
            strong_count += 1

        group = reuse_groups.setdefault(record.password_fingerprint, [])
        group.append(identity)

        stale = False
        if record.updated_at is not None and record.updated_at.replace(tzinfo=None) < stale_cutoff:
            stale = True
            entry["stale"] = True
            entry["stale_days"] = (datetime.utcnow() - record.updated_at.replace(tzinfo=None)).days

    reused_records = 0
    for fingerprints, members in reuse_groups.items():
        if len(members) > 1:
            reused_records += len(members)
            for entry in per_record:
                if entry["id"] in {member["id"] for member in members}:
                    entry["reused"] = True
            findings.append({
                "severity": "high",
                "kind": "password_reuse",
                "title": f"Same password used on {len(members)} records",
                "records": members,
                "advice": "Rotate these records to unique passwords; one leak compromises all of them.",
            })

    if weak_ids:
        findings.append({
            "severity": "high" if len(weak_ids) > 2 else "medium",
            "kind": "weak_password",
            "title": f"{len(weak_ids)} weak password(s)",
            "records": weak_ids,
            "advice": "Replace with generated 16+ character secrets.",
        })

    stale_entries = [entry for entry in per_record if entry.get("stale")]
    if stale_entries:
        findings.append({
            "severity": "low",
            "kind": "stale_password",
            "title": f"{len(stale_entries)} password(s) unchanged for {stale_days}+ days",
            "records": [{"id": e["id"], "name": e["name"], "type": e["type"]} for e in stale_entries],
            "advice": "Review and rotate long-lived credentials, especially for production infrastructure.",
        })

    logins_without_totp = [
        {"id": e["id"], "name": e["name"], "type": e["type"]}
        for e in per_record
        if e["type"] == "login" and not e["totp_enabled"]
    ]
    if logins_without_totp:
        findings.append({
            "severity": "info",
            "kind": "no_totp",
            "title": f"{len(logins_without_totp)} login record(s) without two-step verification",
            "records": logins_without_totp,
            "advice": "Attach a TOTP seed where the service supports it.",
        })

    if undecryptable:
        findings.append({
            "severity": "medium",
            "kind": "undecryptable",
            "title": f"{undecryptable} record(s) could not be decrypted with the current key",
            "records": [],
            "advice": "Check ENCRYPTION_KEY continuity; the affected records cannot be audited or recovered.",
        })

    total = len(per_record)
    findings.sort(key=lambda finding: {"high": 0, "medium": 1, "low": 2, "info": 3}.get(finding["severity"], 4))
    return {
        "generated_at": datetime.utcnow(),
        "stale_days": stale_days,
        "summary": {
            "total": total,
            "weak": len(weak_ids),
            "fair": fair_count,
            "strong": strong_count,
            "reused": reused_records,
            "stale": len(stale_entries),
            "average_score": round(score_sum / total, 1) if total else None,
            "score_distribution": {
                "weak": len(weak_ids),
                "fair": fair_count,
                "strong": strong_count,
            },
        },
        "findings": findings,
        "records": per_record,
    }


def organization_report(records: list[VaultRecord]) -> dict:
    """How the vault is organized: type/template/tag distribution, duplicate
    titles, and records missing identifying metadata. Powers the dashboard's
    organization tab; metadata only, no secrets involved."""
    by_type: dict[str, int] = {}
    by_template: dict[str, int] = {}
    tag_counts: dict[str, int] = {}
    title_counts: dict[str, list[dict]] = {}
    missing_username: list[dict] = []
    missing_tags: list[dict] = []
    unclassified: list[dict] = []

    for record in records:
        identity = _record_identity(record)
        by_type[record.record_type] = by_type.get(record.record_type, 0) + 1

        template = identity["template_type"]
        if template:
            by_template[template] = by_template.get(template, 0) + 1
        else:
            unclassified.append(identity)

        tags: list[str] = []
        try:
            tags = [str(tag) for tag in json.loads(record.tags or "[]")]
        except Exception:
            tags = []
        if tags:
            for tag in tags:
                normalized = tag.strip().lower()
                if normalized:
                    tag_counts[normalized] = tag_counts.get(normalized, 0) + 1
        else:
            missing_tags.append(identity)

        normalized_title = (record.title or "").strip().lower()
        if normalized_title:
            title_counts.setdefault(normalized_title, []).append(identity)

        if record.record_type in {"login", "account"} and not record.username:
            missing_username.append(identity)

    duplicates = [
        {"title": members[0]["name"], "records": members}
        for members in title_counts.values()
        if len(members) > 1
    ]

    return {
        "generated_at": datetime.utcnow(),
        "total": len(records),
        "by_type": by_type,
        "by_template": by_template,
        "top_tags": sorted(
            ({"tag": tag, "count": count} for tag, count in tag_counts.items()),
            key=lambda item: -item["count"],
        )[:15],
        "duplicate_titles": duplicates,
        "missing_username": missing_username,
        "missing_tags": missing_tags,
        "unclassified": unclassified,
    }
