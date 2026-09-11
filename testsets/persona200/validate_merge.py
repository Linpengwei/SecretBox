#!/usr/bin/env python3
"""Validate the raw persona batches produced by claude/codex/opencode and merge
them into testsets/persona200/scenarios_200.json.

Usage: python3 validate_merge.py [--raw-dir DIR] [--out FILE]
Exits non-zero when any batch is unusable; prints a per-batch and per-rule report.
"""
from __future__ import annotations

import argparse
import json
import re
import sys
import unicodedata
from datetime import datetime, timezone
from pathlib import Path

# persona -> (generator CLI, expected scenario count)
PLAN: dict[str, tuple[str, int]] = {
    "sre": ("claude", 40),
    "developer": ("claude", 30),
    "product_manager": ("codex", 30),
    "designer": ("codex", 35),
    "novice": ("opencode", 40),
    "admin": ("opencode", 25),
}
PERSONA_LABELS = {
    "sre": "专业 SRE",
    "developer": "软件开发工程师",
    "product_manager": "产品经理",
    "designer": "设计师",
    "novice": "电脑小白",
    "admin": "行政/财务人员",
}
TEMPLATE_TYPES = {"redis", "database", "s3", "kafka", "aksk", "account", "custom"}
DIFFICULTIES = {"easy", "medium", "hard"}
SAFE_TLDS = (".internal", ".test", ".example", ".invalid", ".localhost")
SAFE_DOMAINS = {"example.com", "example.org", "example.net", "localhost", "127.0.0.1", "0.0.0.0"}
HOST_RE = re.compile(r"\b(?:[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\.)+(?:com|org|net|io|cn|dev|app|internal|test|example|local)\b", re.IGNORECASE)


class Issues:
    def __init__(self) -> None:
        self.errors: list[str] = []
        self.warnings: list[str] = []

    def error(self, msg: str) -> None:
        self.errors.append(msg)

    def warn(self, msg: str) -> None:
        self.warnings.append(msg)


def extract_json_array(text: str):
    """Tolerate markdown fences / CLI banners: slice from first '[' to last ']'."""
    start, end = text.find("["), text.rfind("]")
    if start == -1 or end <= start:
        raise ValueError("no JSON array found in output")
    return json.loads(text[start : end + 1])


def check_text_fictional(where: str, text: str, issues: Issues) -> None:
    for match in HOST_RE.finditer(text):
        host = match.group(0).lower().rstrip(".")
        if host in SAFE_DOMAINS or host.endswith(SAFE_TLDS):
            continue
        issues.warn(f"{where}: 疑似非白名单域名 '{host}'")


def validate_scenario(idx: int, item, persona: str, generator: str, issues: Issues):
    def err(msg: str) -> None:
        issues.error(f"{persona}[{idx}]: {msg}")

    if not isinstance(item, dict):
        err("条目不是对象")
        return None
    for key in ("title", "story", "difficulty", "create", "expect"):
        if key not in item:
            err(f"缺少字段 {key}")

    title = str(item.get("title") or "").strip()
    if not title:
        err("title 为空")
    if item.get("difficulty") not in DIFFICULTIES:
        err(f"difficulty 非法: {item.get('difficulty')!r}")

    create = item.get("create") if isinstance(item.get("create"), dict) else {}
    expect = item.get("expect") if isinstance(item.get("expect"), dict) else {}
    pasted = create.get("pasted_text")
    if not isinstance(pasted, str) or not pasted.strip():
        err("create.pasted_text 必须是非空字符串")
    if "fields" in create and not isinstance(create.get("fields"), list):
        err("create.fields 必须是数组")

    secret = expect.get("primary_secret")
    if not isinstance(secret, str) or not secret.strip():
        err("expect.primary_secret 必须是非空字符串")
        return None
    if secret != secret.strip():
        err("expect.primary_secret 含首尾空格")
    if len(secret) < 4 or len(secret) > 120:
        err(f"expect.primary_secret 长度异常: {len(secret)}")
    if "\n" in secret or "\r" in secret:
        err("expect.primary_secret 含换行")
    # NFKC sanity: reject control characters (emoji / CJK are fine)
    for ch in secret:
        if unicodedata.category(ch) == "Cc":
            err(f"expect.primary_secret 含控制字符 U+{ord(ch):04X}")
            break

    template = expect.get("template_type")
    if template not in TEMPLATE_TYPES:
        err(f"expect.template_type 非法: {template!r}")

    query = expect.get("semantic_query")
    if not isinstance(query, str) or len(query.strip()) < 2:
        err("expect.semantic_query 必须是非空字符串")
    elif secret and secret in query:
        err("expect.semantic_query 不得包含密码本身")

    top_n = expect.get("semantic_top_n", 5)
    if not isinstance(top_n, int) or not 1 <= top_n <= 10:
        err(f"expect.semantic_top_n 非法: {top_n!r}")

    check_text_fictional("pasted_text", pasted or "", issues)
    check_text_fictional("semantic_query", query or "", issues)
    check_text_fictional("title", title, issues)

    manual_secret = create.get("primary_secret")
    if manual_secret is not None and (not isinstance(manual_secret, str) or not manual_secret.strip()):
        err("create.primary_secret 若提供必须非空")

    return {
        "title": title,
        "story": str(item.get("story") or "").strip(),
        "difficulty": item.get("difficulty"),
        "create": {
            "pasted_text": pasted,
            "primary_secret": manual_secret,
            "name": create.get("name"),
            "notes": create.get("notes"),
            "tags": [str(t) for t in (create.get("tags") or [])][:5],
            "fields": create.get("fields") or [],
        },
        "expect": {
            "primary_secret": secret,
            "template_type": template,
            "semantic_query": query,
            "semantic_top_n": top_n,
        },
    }


def main() -> int:
    ap = argparse.ArgumentParser()
    here = Path(__file__).resolve().parent
    ap.add_argument("--raw-dir", default=str(here / "raw"))
    ap.add_argument("--out", default=str(here / "scenarios_200.json"))
    args = ap.parse_args()
    raw_dir = Path(args.raw_dir)

    scenarios: list[dict] = []
    seen_secrets: dict[str, str] = {}
    seen_pastes: dict[str, str] = {}
    summary: list[str] = []
    hard_fail = False

    for persona, (generator, expected_count) in PLAN.items():
        issues = Issues()
        path = raw_dir / f"{persona}.json"
        if not path.exists():
            print(f"[FAIL] {persona}: 缺少 {path}")
            hard_fail = True
            continue
        raw = path.read_text(encoding="utf-8")
        try:
            items = extract_json_array(raw)
        except Exception as exc:  # noqa: BLE001
            print(f"[FAIL] {persona}: 无法解析 JSON ({exc}); 文件前 200 字符: {raw[:200]!r}")
            hard_fail = True
            continue

        kept: list[dict] = []
        for idx, item in enumerate(items):
            clean = validate_scenario(idx, item, persona, generator, issues)
            if clean is None:
                continue
            secret_key = clean["expect"]["primary_secret"].strip()
            paste_key = re.sub(r"\s+", " ", (clean["create"]["pasted_text"] or "").strip())
            if secret_key in seen_secrets:
                issues.error(f"{persona}[{idx}]: 密码与 {seen_secrets[secret_key]} 重复")
                continue
            if paste_key and paste_key in seen_pastes:
                issues.warn(f"{persona}[{idx}]: 粘贴文本与 {seen_pastes[paste_key]} 重复")
            seen_secrets[secret_key] = f"{persona}[{idx}]"
            if paste_key:
                seen_pastes[paste_key] = f"{persona}[{idx}]"
            clean = {
                "id": "",
                "generator": generator,
                "persona": persona,
                "persona_label": PERSONA_LABELS[persona],
                **clean,
            }
            kept.append(clean)

        count = len(kept)
        status = "OK" if count == expected_count and not issues.errors else ("WARN" if not issues.errors else "FAIL")
        if status == "FAIL":
            hard_fail = True
        summary.append(
            f"{persona} ({generator}): 期望 {expected_count}, 得到 {len(items)}, 校验通过 {count} [{status}]"
            + (f"; errors={len(issues.errors)} warnings={len(issues.warnings)}" if issues.errors or issues.warnings else "")
        )
        print(f"[{status}] {summary[-1]}")
        for msg in issues.errors[:20]:
            print(f"    E {msg}")
        for msg in issues.warnings[:10]:
            print(f"    W {msg}")
        scenarios.extend(kept)

    # deterministic ids grouped by persona
    counters: dict[str, int] = {}
    for sc in scenarios:
        persona = sc["persona"]
        counters[persona] = counters.get(persona, 0) + 1
        sc["id"] = f"{persona.upper()[:4]}-{counters[persona]:03d}"

    total = len(scenarios)
    print(f"\n总计: {total}/200 条场景")
    if total != 200:
        print("[FAIL] 总数不是 200")
        hard_fail = True

    out_path = Path(args.out)
    out_path.write_text(
        json.dumps(
            {
                "version": 1,
                "generated_at": datetime.now(timezone.utc).isoformat(),
                "generators": {"claude": 70, "codex": 65, "opencode": 65},
                "total": total,
                "scenarios": scenarios,
            },
            ensure_ascii=False,
            indent=2,
        )
        + "\n",
        encoding="utf-8",
    )
    print(f"已写出 {out_path}")
    return 1 if hard_fail else 0


if __name__ == "__main__":
    sys.exit(main())
