"""The capture golden corpus, run against the server's parser and scrub.

`testsets/capture_golden.json` is the one corpus every capture parser is
measured against. The server's parser is frozen: it is no longer on the app's
write path (the app uploads structured records), and new capture rules go into
the app's capture engine. Its extraction numbers are held at their recorded
floors so a change cannot make them worse unnoticed.

The scrub is not frozen. Two properties are asserted over every case and must
hold absolutely:

- no known secret, in any encoded form, survives into a stored field, the
  stored excerpt, the derived notes or the name;
- scrubbing is idempotent — startup maintenance and the AI boundary both scrub
  text that was already scrubbed once.

The corpus also contains negative pastes (`secrets == []`). The server's
extraction floors are measured over positive cases only: its parser is frozen,
while the app's capture engine owns the new negative-case requirement.
"""
import json
from pathlib import Path
from urllib.parse import quote, unquote

import pytest
from app.ai import ai_service

CORPUS_PATH = Path(__file__).resolve().parents[2] / "testsets" / "capture_golden.json"
CORPUS = json.loads(CORPUS_PATH.read_text(encoding="utf-8"))
CASES = CORPUS["cases"]
POSITIVE_CASES = [case for case in CASES if case["secrets"]]
NEGATIVE_CASES = [case for case in CASES if not case["secrets"]]
FLOORS = CORPUS.get("floors", {}).get("server", {})


def encoded_forms(secret: str) -> set[str]:
    return {secret, quote(secret, safe=""), unquote(secret)} - {""}


def parse_and_scrub(text: str) -> tuple[list, str, str, str, str | None]:
    """What `create_record` would store for a raw paste, minus the record row."""
    parsed = ai_service.parse_pasted_secret(text)
    fields = ai_service.sanitize_fields(parsed.fields, parsed.primary_secret)
    excerpt = ai_service.sanitize_free_text(parsed.redacted_excerpt, parsed.primary_secret)
    notes = ai_service.sanitize_free_text(parsed.notes, parsed.primary_secret)
    name = ai_service.sanitize_free_text(parsed.name, parsed.primary_secret)
    return fields, excerpt, notes, name, parsed.primary_secret


def test_every_corpus_case_has_what_the_tests_need():
    assert len(CASES) >= 338, "the corpus shrank; build_capture_golden.py should merge persona, fifty, authored and edge cases"
    assert NEGATIVE_CASES, "the adversarial negative cases must stay in the corpus"
    for case in POSITIVE_CASES:
        assert case["secrets"][0], case["id"]
        assert case["template"] in {"redis", "database", "s3", "kafka", "aksk", "account", "custom"}, case["id"]
    for case in NEGATIVE_CASES:
        assert case["template"] == "-", case["id"]


def test_server_parser_extraction_holds_its_floors():
    assert FLOORS, "floors.server is missing from the corpus"
    found = primary = template = 0
    missed: list[str] = []
    wrong: list[str] = []
    for case in POSITIVE_CASES:
        parsed = ai_service.parse_pasted_secret(case["text"])
        if parsed.primary_secret:
            found += 1
        else:
            missed.append(case["id"])
        if parsed.primary_secret == case["secrets"][0]:
            primary += 1
        else:
            wrong.append(case["id"])
        if (parsed.template_type or "custom") == case["template"]:
            template += 1
    total = len(POSITIVE_CASES)

    assert primary >= FLOORS["primary"], f"correct secret dropped to {primary}/{total}; wrong: {' '.join(wrong)}"
    assert found >= FLOORS["found"], f"secret found dropped to {found}/{total}; none found: {' '.join(missed)}"
    assert template >= FLOORS["template"], f"template dropped to {template}/{total}"


def test_no_known_secret_survives_the_scrub():
    leaks: list[str] = []
    for case in CASES:
        fields, excerpt, notes, name, primary = parse_and_scrub(case["text"])
        stored = [("excerpt", excerpt), ("notes", notes), ("name", name)]
        stored += [(f"field {field.key}", field.value) for field in fields if not field.hidden]
        for secret in case["secrets"]:
            for form in encoded_forms(secret):
                for where, text in stored:
                    if form and form in (text or ""):
                        leaks.append(f"{case['id']}: {where} still contains {form[:4]}…")
    assert not leaks, "\n".join(leaks)


def test_the_scrub_is_idempotent():
    changed: list[str] = []
    for case in CASES:
        fields, excerpt, notes, name, primary = parse_and_scrub(case["text"])
        for label, text in (("excerpt", excerpt), ("notes", notes), ("name", name)):
            if text and ai_service.sanitize_free_text(text, primary) != text:
                changed.append(f"{case['id']}: {label} changes when scrubbed again")
        again = ai_service.sanitize_fields(fields, primary)
        if [field.model_dump() for field in again] != [field.model_dump() for field in fields]:
            changed.append(f"{case['id']}: fields change when sanitized again")
    assert not changed, "\n".join(changed)


@pytest.mark.parametrize(
    "text,expected",
    [
        ("s3://bucket?aws_access_key_id=AKIA&aws_secret_access_key=Images2024&region=us-east-1", "s3://bucket?aws_access_key_id=AKIA&aws_secret_access_key=[REDACTED]&region=us-east-1"),
        ("jdbc:postgresql://db:5432/app?user=app&password=Pw%231&ssl=true", "jdbc:postgresql://db:5432/app?user=app&password=[REDACTED]&ssl=true"),
        ("docker login registry.example.com -u buildship -p shipPass2026alpha", "docker login registry.example.com -u buildship -p [REDACTED]"),
        ("docker login ghcr.internal -u ops-bot --password=ghcrTok2026xZ7q", "docker login ghcr.internal -u ops-bot --password=[REDACTED]"),
        ("REDISCLI_AUTH=X redis-cli -h redis.internal -p 6379", "REDISCLI_AUTH=[REDACTED] redis-cli -h redis.internal -p 6379"),
        ("序列号：FontKey-33\n备注：内网", "序列号：[REDACTED]\n备注：内网"),
        ("前台 WiFi：FrontDesk2026\n用户：ops", "前台 WiFi：[REDACTED]\n用户：ops"),
        ("host: a.internal\npostal_code: 310000\ncode=SlidePM2026", "host: a.internal\npostal_code: 310000\ncode=[REDACTED]"),
    ],
)
def test_scrub_shapes_that_once_leaked(text, expected):
    assert ai_service.sanitize_free_text(text) == expected


def test_scrub_keeps_what_is_not_a_secret():
    text = "host=redis.internal port=6379 username=default access_key=AKIA123 author=jane laptop=mine keynote=x"
    assert ai_service.sanitize_free_text(text) == text
