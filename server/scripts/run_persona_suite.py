#!/usr/bin/env python3
"""Run the persona-200 scenario suite against the SecretBox server app in-process.

The suite simulates 200 password-usage scenarios from six user personas
(专业 SRE / 开发 / 产品经理 / 设计师 / 电脑小白 / 行政财务). For every scenario it:

1. creates the vault record via POST /api/records (exactly what a user paste does),
2. checks the stored secret round-trips (reversible ciphertext invariant),
3. checks the classified template type against the expectation,
4. searches with the raw password (must hit via keyed-hash fingerprint —
   the exact-match search invariant),
5. searches with the persona's natural-language query (semantic usability),
6. records per-operation latency.

The app runs against a throwaway SQLite database (DATABASE_URL env override) so
the developer's secretbox.db is never touched, and with no AI provider configured
so the deterministic heuristic paths are what get exercised.

Usage: python3 server/scripts/run_persona_suite.py [--suite FILE] [--out-dir DIR]
"""
from __future__ import annotations

import argparse
import json
import os
import secrets
import statistics
import sys
import time
from collections import defaultdict
from datetime import datetime, timezone
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
SERVER_DIR = REPO_ROOT / "server"

PERSONA_ORDER = ["sre", "developer", "product_manager", "designer", "novice", "admin"]
CHECKS = ["create", "secret_roundtrip", "template_type", "exact_search", "semantic_search"]


def percentile(values: list[float], pct: float) -> float:
    if not values:
        return 0.0
    ordered = sorted(values)
    idx = min(len(ordered) - 1, max(0, round(pct / 100 * (len(ordered) - 1))))
    return ordered[idx]


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--suite", default=str(REPO_ROOT / "testsets/persona200/scenarios_200.json"))
    ap.add_argument("--out-dir", default=str(REPO_ROOT / "testsets/persona200"))
    ap.add_argument("--db", default=None, help="optional sqlite path (default: throwaway file in out-dir)")
    args = ap.parse_args()

    out_dir = Path(args.out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)
    db_path = Path(args.db) if args.db else out_dir / f"persona200-{secrets.token_hex(4)}.db"
    if db_path.exists():
        db_path.unlink()
    # Must be set before app modules import: settings reads DATABASE_URL at import time.
    os.environ["DATABASE_URL"] = f"sqlite:///{db_path}"
    sys.path.insert(0, str(SERVER_DIR))

    from fastapi.testclient import TestClient  # noqa: E402

    from app.main import app  # noqa: E402

    suite = json.loads(Path(args.suite).read_text(encoding="utf-8"))
    scenarios = suite["scenarios"] if isinstance(suite, dict) else suite
    print(f"套件: {len(scenarios)} 个场景, 隔离数据库: {db_path}")

    rows: list[dict] = []
    record_ids: dict[str, str] = {}
    latencies: dict[str, list[float]] = defaultdict(list)

    with TestClient(app) as client:
        assert client.get("/health").json() == {"status": "ok"}

        # Phase A: create every record first — a shared, realistically populated vault.
        # First attempt is the pure paste (what the user actually pastes). If the parser
        # cannot find a secret in it, the real product flow is that the user types the
        # password into the editor manually — so we retry with primary_secret filled and
        # record paste_parse_ok=False. Parsing failures are a usability finding, not a
        # reason to skip the storage/search checks for that scenario.
        for sc in scenarios:
            payload = dict(sc["create"])
            t0 = time.perf_counter()
            resp = client.post("/api/records", json=payload)
            paste_parse_ok = resp.status_code == 200
            if resp.status_code == 400 and payload.get("primary_secret") is None:
                payload["primary_secret"] = sc["expect"]["primary_secret"]
                resp = client.post("/api/records", json=payload)
            dt = time.perf_counter() - t0
            latencies["create"].append(dt)
            row = {
                "id": sc["id"],
                "persona": sc["persona"],
                "generator": sc["generator"],
                "difficulty": sc.get("difficulty"),
                "title": sc.get("title"),
                "create_status": resp.status_code,
                "paste_parse_ok": paste_parse_ok,
                "create_ms": round(dt * 1000, 1),
                "record_id": None,
                "secret_roundtrip": None,
                "template_expected": sc["expect"].get("template_type"),
                "template_actual": None,
                "exact_search_rank": None,
                "exact_search_reason": None,
                "semantic_search_rank": None,
                "semantic_top_n": sc["expect"].get("semantic_top_n", 5),
                "semantic_query": sc["expect"].get("semantic_query"),
                "search_ms": None,
            }
            if resp.status_code != 200:
                row["error"] = f"create failed: {resp.status_code} {resp.text[:200]}"
                rows.append(row)
                print(f"  [CREATE-FAIL] {sc['id']}: {resp.status_code} {resp.text[:120]}")
                continue
            body = resp.json()
            row["record_id"] = body["id"]
            record_ids[sc["id"]] = body["id"]
            row["secret_roundtrip"] = body.get("primary_secret") == sc["expect"]["primary_secret"]
            row["template_actual"] = body.get("template_type")
            rows.append(row)

        # Phase B: retrieval checks against the populated vault.
        for row, sc in zip(rows, scenarios):
            if row["record_id"] is None:
                continue
            secret = sc["expect"]["primary_secret"]
            t0 = time.perf_counter()
            exact = client.post("/api/search", json={"query": secret, "limit": 10})
            semantic = client.post(
                "/api/search", json={"query": sc["expect"]["semantic_query"], "limit": 10}
            )
            dt = (time.perf_counter() - t0) / 2
            latencies["search"].append(dt)
            row["search_ms"] = round(dt * 1000, 1)
            if exact.status_code == 200:
                results = exact.json()["results"]
                ids = [r["id"] for r in results]
                target = row["record_id"]
                row["exact_search_rank"] = ids.index(target) + 1 if target in ids else None
                for item in results:
                    if item["id"] == target:
                        row["exact_search_reason"] = item.get("match_reason")
                        break
            else:
                row["error"] = f"exact search failed: {exact.status_code}"
            if semantic.status_code == 200:
                ids = [r["id"] for r in semantic.json()["results"]]
                target = row["record_id"]
                row["semantic_search_rank"] = ids.index(target) + 1 if target in ids else None
            else:
                row["error"] = f"semantic search failed: {semantic.status_code}"

    # ---- scoring ----
    for row in rows:
        # "custom" expectation means "no specific template recognized"; the server
        # represents that as template_type=None (the item still gets tag "custom").
        actual = row["template_actual"]
        expected = row["template_expected"]
        template_ok = actual == expected or (expected == "custom" and actual is None)
        row["checks"] = {
            "create": row["create_status"] == 200,
            "secret_roundtrip": bool(row["secret_roundtrip"]),
            "template_type": template_ok,
            "exact_search": row["exact_search_rank"] is not None,
            "semantic_search": (
                row["semantic_search_rank"] is not None
                and row["semantic_search_rank"] <= (row["semantic_top_n"] or 5)
            ),
        }

    def bucket_stats(bucket_rows: list[dict]) -> dict:
        stats: dict = {"count": len(bucket_rows)}
        for check in CHECKS:
            stats[check] = sum(1 for r in bucket_rows if r["checks"][check])
        stats["semantic_soft"] = sum(
            1 for r in bucket_rows if r["semantic_search_rank"] is not None
        )
        stats["paste_parse"] = sum(1 for r in bucket_rows if r.get("paste_parse_ok"))
        return stats

    overall = bucket_stats(rows)
    by_persona = {p: bucket_stats([r for r in rows if r["persona"] == p]) for p in PERSONA_ORDER}
    by_generator = defaultdict(list)
    for r in rows:
        by_generator[r["generator"]].append(r)
    by_difficulty = defaultdict(list)
    for r in rows:
        by_difficulty[r["difficulty"] or "unknown"].append(r)
    by_generator_stats = {g: bucket_stats(rs) for g, rs in sorted(by_generator.items())}
    by_difficulty_stats = {d: bucket_stats(rs) for d, rs in sorted(by_difficulty.items())}

    latency_summary = {
        name: {
            "n": len(vals),
            "mean_ms": round(statistics.fmean(vals) * 1000, 1) if vals else 0,
            "p95_ms": round(percentile(vals, 95) * 1000, 1),
            "max_ms": round(max(vals) * 1000, 1) if vals else 0,
        }
        for name, vals in latencies.items()
    }

    results_path = out_dir / "results_200.json"
    results_path.write_text(
        json.dumps(
            {
                "suite": args.suite,
                "database": str(db_path),
                "finished_at": datetime.now(timezone.utc).isoformat(),
                "overall": overall,
                "by_persona": by_persona,
                "by_generator": {g: bucket_stats(rs) for g, rs in sorted(by_generator.items())},
                "by_difficulty": {d: bucket_stats(rs) for d, rs in sorted(by_difficulty.items())},
                "latency": latency_summary,
                "rows": rows,
            },
            ensure_ascii=False,
            indent=2,
        )
        + "\n",
        encoding="utf-8",
    )

    # ---- markdown report ----
    lines: list[str] = []
    lines.append("# SecretBox 人格化 200 场景稳定性报告")
    lines.append("")
    lines.append(f"- 生成时间：{datetime.now(timezone.utc).isoformat(timespec='seconds')}")
    lines.append(f"- 套件：`{args.suite}`（{overall['count']} 条）")
    lines.append("- 执行方式：进程内 TestClient + 一次性 SQLite 库，未配置外部 AI provider（走服务端确定性启发式路径）")
    lines.append("")
    lines.append("## 总览")
    lines.append("")
    lines.append("| 检查维度 | 通过 | 通过率 | 说明 |")
    lines.append("| --- | --- | --- | --- |")
    notes = {
        "create": "粘贴/录入能否成功入库（含手动补密码重试）",
        "secret_roundtrip": "密文可逆取回，原样取回密码",
        "template_type": "类型分类符合预期（custom ≡ 服务端未识别模板/None）",
        "exact_search": "拿原密码搜索必须命中（指纹精确匹配不变量）",
        "semantic_search": "按用户口吻的自然语言检索命中且排进 top N",
    }
    paste_ok = overall["paste_parse"]
    lines.append(
        f"| 粘贴即存 | {paste_ok}/{overall['count']} | {paste_ok / overall['count']:.1%} "
        f"| 纯粘贴一次入库成功率（失败即真实产品中需手动补密码） |"
    )
    for check in CHECKS:
        n = overall[check]
        lines.append(f"| {check} | {n}/{overall['count']} | {n / overall['count']:.1%} | {notes[check]} |")
    lines.append("")

    def table(title: str, mapping: dict[str, dict], labels: dict[str, str] | None = None) -> None:
        lines.append(f"## {title}")
        lines.append("")
        lines.append("| 分组 | 场景数 | 粘贴即存 | create | roundtrip | 分类 | 精确检索 | 语义检索(≤topN) |")
        lines.append("| --- | --- | --- | --- | --- | --- | --- | --- |")
        for key in mapping:
            s = mapping[key]
            label = (labels or {}).get(key, key)
            lines.append(
                f"| {label} | {s['count']} | {s['paste_parse']}/{s['count']} | {s['create']}/{s['count']} | {s['secret_roundtrip']}/{s['count']} "
                f"| {s['template_type']}/{s['count']} | {s['exact_search']}/{s['count']} | {s['semantic_search']}/{s['count']} |"
            )
        lines.append("")

    persona_labels = {sc["persona"]: sc["persona_label"] for sc in scenarios}
    table("按人群", by_persona, persona_labels)
    table(
        "按生成器",
        by_generator_stats,
        {"claude": "claude", "codex": "codex", "opencode": "opencode"},
    )
    table("按难度", by_difficulty_stats)

    lines.append("## 延迟（进程内，供稳定性参考）")
    lines.append("")
    lines.append("| 操作 | n | 平均 | p95 | 最大 |")
    lines.append("| --- | --- | --- | --- | --- |")
    for name, s in latency_summary.items():
        lines.append(f"| {name} | {s['n']} | {s['mean_ms']} ms | {s['p95_ms']} ms | {s['max_ms']} ms |")
    lines.append("")

    failures = [r for r in rows if not all(r["checks"].values())]
    lines.append(f"## 失败明细（{len(failures)} 条）")
    lines.append("")
    if failures:
        lines.append("| 场景 | 人群 | 失败维度 | 明细 |")
        lines.append("| --- | --- | --- | --- |")
        for r in failures:
            failed = [c for c, ok in r["checks"].items() if not ok]
            detail = r.get("error") or ""
            if "template_type" in failed:
                detail += f" 期望分类 {r['template_expected']!r}, 实际 {r['template_actual']!r};"
            if "semantic_search" in failed:
                detail += f" 语义检索排名 {r['semantic_search_rank']} (需 ≤{r['semantic_top_n']});"
            if "exact_search" in failed:
                detail += f" 精确检索排名 {r['exact_search_reason'] or '未命中'};"
            lines.append(f"| {r['id']} {r['title']} | {persona_labels.get(r['persona'], r['persona'])} | {', '.join(failed)} | {detail.strip()} |")
        lines.append("")
    else:
        lines.append("全部通过。")
        lines.append("")

    report_path = out_dir / "report.md"
    report_path.write_text("\n".join(lines), encoding="utf-8")
    print(f"结果: {results_path}\n报告: {report_path}")
    print(
        "总览: " + ", ".join(f"{c}={overall[c]}/{overall['count']}" for c in CHECKS)
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
