#!/usr/bin/env python3
"""
CEO Advisors CRM — Daily Supabase backup.

Dumps all public-schema tables to gzipped JSON, one file per table,
under <out_dir>/YYYY-MM-DD/<table>.json.gz, plus a manifest.json.

Usage:
    SUPABASE_URL=https://<ref>.supabase.co \\
    SUPABASE_SERVICE_ROLE_KEY=eyJ... \\
    BACKUP_OUT_DIR=./backups \\
    python scripts/backup_supabase.py

Schema-only backups are not needed here: schema is versioned in
supabase_migrations/*.sql, so restore = re-run migrations + replay JSON.
"""
import gzip
import json
import os
import sys
import urllib.error
import urllib.request
from datetime import datetime, timezone

TABLES = [
    "consultants",
    "clients",
    "companies",
    "deals",
    "activities",
    "pupilos",
    "activity_log",
    "notifications",
    "chat_rate_limits",
]

PAGE = 1000


def fetch_all(supa_url: str, key: str, table: str) -> list:
    rows: list = []
    offset = 0
    while True:
        url = f"{supa_url}/rest/v1/{table}?select=*&limit={PAGE}&offset={offset}"
        req = urllib.request.Request(
            url,
            headers={
                "apikey": key,
                "Authorization": f"Bearer {key}",
                "Accept": "application/json",
            },
        )
        with urllib.request.urlopen(req, timeout=60) as r:
            batch = json.loads(r.read().decode("utf-8"))
        if not batch:
            break
        rows.extend(batch)
        if len(batch) < PAGE:
            break
        offset += PAGE
    return rows


def main() -> int:
    supa_url = os.environ["SUPABASE_URL"].rstrip("/")
    key = os.environ["SUPABASE_SERVICE_ROLE_KEY"]
    out_dir = os.environ.get("BACKUP_OUT_DIR", "backups")

    ts = datetime.now(timezone.utc).strftime("%Y-%m-%d")
    day_dir = os.path.join(out_dir, ts)
    os.makedirs(day_dir, exist_ok=True)

    summary: dict[str, object] = {}
    had_error = False
    for table in TABLES:
        try:
            rows = fetch_all(supa_url, key, table)
            path = os.path.join(day_dir, f"{table}.json.gz")
            with gzip.open(path, "wt", encoding="utf-8") as f:
                json.dump(rows, f, ensure_ascii=False, default=str, separators=(",", ":"))
            summary[table] = len(rows)
            print(f"{table}: {len(rows)} rows -> {path}")
        except urllib.error.HTTPError as e:
            summary[table] = f"HTTP {e.code}: {e.reason}"
            print(f"{table}: ERROR {e.code} {e.reason}", file=sys.stderr)
            had_error = True
        except Exception as e:
            summary[table] = f"ERROR: {e}"
            print(f"{table}: ERROR {e}", file=sys.stderr)
            had_error = True

    manifest = {
        "timestamp_utc": datetime.now(timezone.utc).isoformat(),
        "project_url": supa_url,
        "tables": summary,
    }
    with open(os.path.join(day_dir, "manifest.json"), "w", encoding="utf-8") as f:
        json.dump(manifest, f, indent=2, ensure_ascii=False)

    return 1 if had_error else 0


if __name__ == "__main__":
    sys.exit(main())
