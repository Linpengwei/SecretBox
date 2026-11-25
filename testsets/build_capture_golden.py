#!/usr/bin/env python3
"""Build testsets/capture_golden.json — the one corpus every capture parser is
measured against.

Sources, merged in this order:

1. The 200 persona scenarios (`persona200/scenarios_200.json`): text and the
   expected primary secret and template come from the scenario itself, so the
   two files cannot drift apart.
2. The 50-sample classifier set (`server/docs/diverse_fifty_samples.json`):
   text, type and cluster from the file. The file never carried the secret, so
   each sample names the key that carries it (FIFTY_SECRET_SOURCE) and this
   script reads the value out of the sample text.
3. The authored cases below: shapes that leaked or were mis-parsed before the
   capture engine existed — several secrets in one paste, percent-encoded URI
   passwords, natural-language handoffs, values glued to a following sentence.

`secrets[0]` is the primary secret; the rest are secondary secrets that a
parser must keep out of ordinary fields. `floors` is hand-maintained and is
carried over untouched when this script regenerates the corpus.

Usage: python3 testsets/build_capture_golden.py
"""
from __future__ import annotations

import json
import re
from pathlib import Path
from urllib.parse import unquote

HERE = Path(__file__).resolve().parent
REPO_ROOT = HERE.parent
PERSONA = HERE / "persona200" / "scenarios_200.json"
FIFTY = REPO_ROOT / "server" / "docs" / "diverse_fifty_samples.json"
TARGET = HERE / "capture_golden.json"

ABOUT = (
    "The capture golden corpus. secrets[0] is the primary secret a parser must lock into the "
    "protected slot; further entries are secondary secrets that must be captured as secrets and "
    "never stored as an ordinary field. template 'custom' means no specific template. Built by "
    "testsets/build_capture_golden.py — edit that script, not this file."
)

# Where each 50-sample carries its secret: "uri" = the password in the URI's
# userinfo (percent-decoded); anything else = that key in the text.
FIFTY_SECRET_SOURCE = {
    "redis-uri-prod": "uri",
    "redis-kv-stage": "password",
    "redis-cli-auth": "REDISCLI_AUTH",
    "redis-url-inline": "uri",
    "redis-config-note": "password",
    "postgres-database-url": "uri",
    "postgres-kv": "password",
    "mysql-uri": "uri",
    "clickhouse-uri": "uri",
    "mongodb-uri": "uri",
    "mariadb-kv": "password",
    "postgres-service-note": "password",
    "mysql-reporting": "password",
    "mongodb-kv": "password",
    "clickhouse-kv": "password",
    "aws-s3-env": "aws_secret_access_key",
    "minio-kv": "secret_key",
    "oss-provider": "secret_key",
    "s3-endpoint-host": "aws_secret_access_key",
    "storage-note": "secret_key",
    "kafka-sasl": "sasl.password",
    "kafka-bootstrap": "sasl_password",
    "kafka-plain": "password",
    "kafka-stage": "sasl_password",
    "kafka-bootstrap-short": "password",
    "github-account": "password",
    "gitlab-account": "passwd",
    "harbor-robot": "password",
    "jenkins-login": "password",
    "grafana-login": "password",
    "argocd-login": "password",
    "sonarqube-login": "password",
    "jira-login": "password",
    "gitea-login": "password",
    "slack-login": "password",
    "aliyun-aksk": "sk",
    "tencent-aksk": "secret_key",
    "aws-aksk": "secret_key",
    "gcp-aksk": "sk",
    "azure-aksk": "secret_key",
    "amqp-uri-payments": "uri",
    "rabbitmq-kv-stage": "password",
    "rabbitmq-inline": "password",
    "amqp-orders": "uri",
    "rabbitmq-billing": "password",
    "service-endpoint-token": "token",
    "service-endpoint-password": "password",
    "service-endpoint-url": "password",
    "service-endpoint-login": "secret",
    "service-endpoint-api": "password",
}

_URI_USERINFO_RE = re.compile(r"://(?:[^:@/\s]*:)?(?P<secret>[^@/\s]+)@", re.IGNORECASE)
_MIN_SECRET_LENGTH = 6


def read_fifty_secret(label: str, text: str) -> str:
    """The secret of a 50-sample, read from the sample text itself."""
    source = FIFTY_SECRET_SOURCE[label]
    if source == "uri":
        match = _URI_USERINFO_RE.search(text)
        if not match:
            raise SystemExit(f"fifty sample {label!r}: no URI with a password in its text")
        return unquote(match.group("secret"))
    match = re.search(rf"(?<![\w.]){re.escape(source)}\s*[=:]\s*(?:\"([^\"]+)\"|'([^']+)'|(\S+))", text, re.IGNORECASE)
    if not match:
        raise SystemExit(f"fifty sample {label!r}: key {source!r} not found in its text")
    return next(value for value in match.groups() if value is not None)


# (id, text, secrets, template, cluster or None). Synthetic paste shapes; the
# values are made up, like everything else in the corpus.
EXTRA_CASES = [
    (
        "X-01-multi-secret-paste",
        "账号: ops-bot\n密码: Growth2026\nAK: LTAI5TEXAMPLEKEY\nSK: FlXe9s2QwErT7uIo\n支付密码: 739281",
        ["Growth2026", "FlXe9s2QwErT7uIo", "739281"],
        "account",
        None,
    ),
    (
        "X-02-redis-uri-percent-encoded-password",
        "redis://default:R3dis%40Prod@redis-prod.internal:6379/0 env=prod",
        ["R3dis@Prod"],
        "redis",
        "cacheCredential",
    ),
    (
        "X-03-env-block-with-several-secrets",
        "DATABASE_URL=postgresql://app:MainPass%401@db.internal:5432/app\nSTRIPE_KEY=sk_live_51ExampleExample\nREDIS_AUTH=CachePass2026",
        ["MainPass@1", "sk_live_51ExampleExample", "CachePass2026"],
        "database",
        None,
    ),
    (
        "X-04-natural-language-handoff",
        "账号是 pm_growth 密码是 Growth2026 邮箱密钥是 MailKey9q7x 支付密码 739281",
        ["Growth2026", "MailKey9q7x", "739281"],
        "account",
        None,
    ),
    (
        "X-05-jdbc-url-with-password-parameter",
        "jdbc:postgresql://pg.internal:5432/order_db?user=order_app&password=JdbcPw%237788&ssl=true",
        ["JdbcPw#7788"],
        "database",
        None,
    ),
    (
        "X-06-glued-code-and-next-line-secret",
        "购物密码20010515\n登录密码\nXf4@Pk8#Rs2",
        ["Xf4@Pk8#Rs2", "20010515"],
        "custom",
        None,
    ),
    ("X-07-bare-password", "hg_6688@2026", ["hg_6688@2026"], "custom", None),
    ("X-08-two-word-site-and-credential", "商城名 hg_6688@2026", ["hg_6688@2026"], "custom", None),
    ("X-09-keyword-then-next-line-secret", "密码\nXf4@Pk8#Rs2", ["Xf4@Pk8#Rs2"], "custom", None),
    ("X-10-zh-labels-fullwidth-colon", "账号：pm_growth\n密码：Growth2026", ["Growth2026"], "account", None),
    (
        "X-11-aws-env-key-id-and-secret",
        "AWS_ACCESS_KEY_ID=AKIAIOSFODNN7EXAMPLE\nAWS_SECRET_ACCESS_KEY=wJalrXUtnFEMI7example\nAWS_DEFAULT_REGION=us-east-1",
        ["wJalrXUtnFEMI7example"],
        "s3",
        "objectStorageCredential",
    ),
    (
        "X-12-secret-under-an-unusual-label",
        "主机：10.0.0.5\nclient_secret：8oKj2-qR9tLm3\n备注：内网",
        ["8oKj2-qR9tLm3"],
        "custom",
        None,
    ),
    (
        "X-13-secondary-secret-next-to-primary",
        "host=redis.internal\npassword=Primary#1\nREDIS_AUTH=Secondary#2",
        ["Primary#1", "Secondary#2"],
        "redis",
        None,
    ),
]


def build() -> dict:
    cases: list[dict] = []

    scenarios = json.loads(PERSONA.read_text(encoding="utf-8"))
    scenarios = scenarios["scenarios"] if isinstance(scenarios, dict) else scenarios
    for scenario in scenarios:
        cases.append(
            {
                "id": scenario["id"],
                "source": "persona200",
                "persona": scenario.get("persona"),
                "text": scenario["create"]["pasted_text"],
                "secrets": [scenario["expect"]["primary_secret"]],
                "template": scenario["expect"]["template_type"] or "custom",
            }
        )

    fifty = json.loads(FIFTY.read_text(encoding="utf-8"))
    if {sample["label"] for sample in fifty} != set(FIFTY_SECRET_SOURCE):
        raise SystemExit("FIFTY_SECRET_SOURCE and diverse_fifty_samples.json name different samples")
    for sample in fifty:
        secret = read_fifty_secret(sample["label"], sample["text"])
        if len(secret) < _MIN_SECRET_LENGTH:
            raise SystemExit(f"fifty sample {sample['label']!r}: extracted secret looks wrong ({secret!r})")
        cases.append(
            {
                "id": f"FIFTY-{sample['label']}",
                "source": "fifty",
                "text": sample["text"],
                "secrets": [secret],
                "template": sample["expectedType"],
                "cluster": sample["expectedCluster"],
            }
        )

    for case_id, text, secrets, template, cluster in EXTRA_CASES:
        cases.append(
            {"id": case_id, "source": "authored", "text": text, "secrets": secrets, "template": template, "cluster": cluster}
        )

    ids = [case["id"] for case in cases]
    if len(set(ids)) != len(ids):
        raise SystemExit("duplicate case ids in the golden corpus")

    existing = json.loads(TARGET.read_text(encoding="utf-8")) if TARGET.exists() else {}
    return {
        "version": 1,
        "about": ABOUT,
        "metrics": {
            "found": "the parser returns at least one secret",
            "primary": "the parser's primary secret equals secrets[0] (for URI-embedded passwords: the percent-decoded one)",
            "template": "the detected template equals `template` ('custom' means none)",
            "secondary": "for cases with more than one secret: every secondary secret is captured as a secret",
            "leaks": "known secrets (any encoded form) appearing in an ordinary, non-hidden field or in a stored excerpt — must be 0",
        },
        "floors": existing.get("floors", {}),
        "cases": cases,
    }


def main() -> int:
    corpus = build()
    TARGET.write_text(json.dumps(corpus, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    by_source: dict[str, int] = {}
    for case in corpus["cases"]:
        by_source[case["source"]] = by_source.get(case["source"], 0) + 1
    print(
        f"wrote {TARGET.relative_to(REPO_ROOT)}: {len(corpus['cases'])} cases {by_source}; "
        f"floors carried over: {corpus['floors'] or 'none yet'}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
