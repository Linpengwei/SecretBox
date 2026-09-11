#!/usr/bin/env python3
"""Latency benchmark for SecretBox MCP tools.

Measures end-to-end JSON-RPC round-trip latency for every tool against a real
server subprocess (real Keychain reads), plus an in-process breakdown showing
where the time goes: `security` CLI spawn, the aiReadable filter, and
redact+scrub — across synthetic vault sizes.

Usage:
  python3 mcp-server/bench_tools.py --real                 # bench real vault
  python3 mcp-server/bench_tools.py --sizes 50 200 1000    # synthetic vaults
  python3 mcp-server/bench_tools.py --real --sizes 200 --iterations 12
"""

from __future__ import annotations

import argparse
import json
import os
import statistics
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import secretbox_mcp as server  # noqa: E402

BENCH_SERVICE = "secretbox-mcp-bench"
BENCH_ACCOUNT = "localVault"


def make_records(n: int) -> list[dict]:
    records = []
    for i in range(n):
        shared = i % 2 == 0  # half opt-in, half denied
        secret = f"Bench{i:04d}!secret"
        records.append({
            "id": f"bench-{i}",
            "itemType": "database",
            "templateType": "database",
            "clusterID": "relationalDBCredential",
            "name": f"Bench Service {i}",
            "subtitle": f"owner-{i}",
            "notes": "benchmark record",
            "tags": [f"env:bench", f"idx:{i}"],
            "fields": [],
            "passwordHash": "bench-hash",
            "passwordFingerprint": "bench-fp",
            "primarySecret": secret,
            "matchReason": None,
            "aiReadable": True if shared else False,
            "fieldMap": {
                "host": f"bench-{i}.internal",
                "port": "5432",
                "database": f"db{i}",
                "engine": "postgres",
                "url": f"postgresql://user:{secret}@bench-{i}.internal:5432/db{i}",
            },
        })
    return records


def keychain_write(records: list[dict]) -> None:
    blob = json.dumps({"records": records})
    subprocess.run(
        ["security", "add-generic-password", "-s", BENCH_SERVICE,
         "-a", BENCH_ACCOUNT, "-w", blob, "-U"],
        check=True, capture_output=True,
    )


def keychain_delete() -> None:
    subprocess.run(
        ["security", "delete-generic-password", "-s", BENCH_SERVICE,
         "-a", BENCH_ACCOUNT],
        capture_output=True,
    )


def spawn_server(service: str):
    env = dict(os.environ, SECRETBOX_KEYCHAIN_SERVICE=service)
    return subprocess.Popen(
        ["python3", str(Path(__file__).resolve().parent / "secretbox_mcp.py")],
        stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True, env=env,
    )


class Client:
    def __init__(self, proc):
        self.proc = proc
        self.next_id = 1
        send(self.proc, {"jsonrpc": "2.0", "id": 0, "method": "initialize",
                         "params": {"protocolVersion": "2025-06-18"}})
        self.proc.stdin.write(json.dumps(
            {"jsonrpc": "2.0", "method": "notifications/initialized"}) + "\n")
        self.proc.stdin.flush()

    def call(self, name: str, args: dict):
        return send(self.proc, {"jsonrpc": "2.0", "id": self.next_id,
                                "method": "tools/call",
                                "params": {"name": name, "arguments": args}})


def send(proc, message) -> dict:
    proc.stdin.write(json.dumps(message) + "\n")
    proc.stdin.flush()
    return json.loads(proc.stdout.readline())


def pick_shared_id(records: list[dict]) -> str | None:
    for record in records:
        if record.get("aiReadable") is True and record.get("primarySecret"):
            return record["id"]
    return None


def bench_tool(client: Client, name: str, args: dict, iterations: int) -> dict:
    samples = []
    for _ in range(iterations + 2):  # 2 warmup calls not recorded
        start = time.perf_counter()
        response = send(client.proc, {"jsonrpc": "2.0", "id": client.next_id,
                                      "method": "tools/call",
                                      "params": {"name": name, "arguments": args}})
        elapsed = (time.perf_counter() - start) * 1000
        client.next_id += 1
        if _ >= 2:
            if "error" in response:
                raise RuntimeError(f"{name} errored: {response['error']}")
            samples.append(elapsed)
    return {
        "tool": name,
        "min": min(samples),
        "avg": statistics.mean(samples),
        "p95": sorted(samples)[int(len(samples) * 0.95) - 1 if len(samples) > 1 else 0],
        "max": max(samples),
    }


def in_process_breakdown(records: list[dict]) -> dict:
    """Time the server-side pieces without any subprocess/JSON overhead."""
    def timed(fn, repeat=5):
        best = float("inf")
        for _ in range(repeat):
            start = time.perf_counter()
            fn()
            best = min(best, (time.perf_counter() - start) * 1000)
        return best

    # security CLI read (the process spawn dominates)
    start = time.perf_counter()
    subprocess.run(["security", "find-generic-password", "-s", BENCH_SERVICE,
                    "-a", BENCH_ACCOUNT, "-w"], capture_output=True, shell=False)
    security_ms = (time.perf_counter() - start) * 1000

    filter_ms = timed(lambda: [r for r in records if r.get("aiReadable") is True])
    redact_ms = timed(lambda: [server.scrub(server.redact_record(r)) for r in records])
    return {
        "records": len(records),
        "security_cli_ms": round(security_ms, 2),
        "ai_filter_ms": round(filter_ms, 3),
        "redact_scrub_ms": round(redact_ms, 3),
    }


def print_table(rows: list[dict]) -> None:
    print(f"  {'tool':<20} {'min':>8} {'avg':>8} {'p95':>8} {'max':>8}  (ms)")
    for row in rows:
        print(f"  {row['tool']:<20} {row['min']:>8.1f} {row['avg']:>8.1f} "
              f"{row['p95']:>8.1f} {row['max']:>8.1f}")


def run_suite(service: str, records: list[dict], iterations: int, label: str) -> None:
    keychain_write(records)
    proc = spawn_server(service)
    try:
        client = Client(proc)
        shared_id = pick_shared_id(records)
        suites = [
            ("search_credentials", {"query": "bench-"}),
            ("list_credentials", {"limit": 100}),
            ("get_credential", {"record_id": shared_id}),
            ("copy_password", {"record_id": shared_id}),
            ("get_credential(denied)", {"record_id": f"bench-{len(records)-1}"}),
        ]
        print(f"\n[{label}] vault={len(records)} records "
              f"(shared={sum(1 for r in records if r.get('aiReadable') is True)}), "
              f"{iterations} iterations each")
        for name, args in suites:
            tool = name.split("(")[0]
            print_table([bench_tool(client, tool, args, iterations)])
    finally:
        proc.stdin.close()
        proc.terminate()
    print("  breakdown (in-process, best of 5):",
          json.dumps(in_process_breakdown(records)))


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--real", action="store_true", help="bench the real vault")
    parser.add_argument("--sizes", type=int, nargs="*", default=[],
                        help="synthetic vault sizes to bench")
    parser.add_argument("--iterations", type=int, default=10)
    args = parser.parse_args()

    if not args.real and not args.sizes:
        args.sizes = [50, 200]

    clipboard = subprocess.run(["pbpaste"], capture_output=True, text=True).stdout
    try:
        if args.real:
            raw = subprocess.run(
                ["security", "find-generic-password",
                 "-s", server.keychain_service(), "-a", server.keychain_account(), "-w"],
                capture_output=True, text=True)
            blob = json.loads(raw.stdout)
            records = blob.get("records", blob) if isinstance(blob, dict) else blob
            run_suite(server.keychain_service(), records, args.iterations,
                      "real vault")
        for size in args.sizes:
            keychain_delete()
            run_suite(BENCH_SERVICE, make_records(size), args.iterations,
                      f"synthetic vault")
    finally:
        if args.sizes:
            keychain_delete()
        subprocess.run(["pbcopy"], input=clipboard, text=True)

    print("\nmachine note: first call per server process includes Python start; "
          "warmup calls are excluded from samples.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
