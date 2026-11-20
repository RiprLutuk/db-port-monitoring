#!/usr/bin/env python3
"""Reconcile Grafana alert rules in database against provisioned files and active datasources."""

from __future__ import annotations

import argparse
import configparser
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import yaml

ROOT = Path(__file__).resolve().parents[1]
GRAFANA_INI = Path(os.environ.get("GRAFANA_INI", "/dataplatform/data-tools/grafana/grafana.ini"))
LOCAL_CONFIG = Path(os.environ.get(
    "ALERT_AUTODISCOVERY_CONFIG", ROOT / "scripts/alerting-autodiscovery.local.json"
))
MANAGED_PREFIXES = ("rds_", "pg_", "my_", "po_", "ms_", "mssql_", "postgresql_", "mysql_")


def run(command: list[str], *, env: dict[str, str] | None = None) -> str:
    return subprocess.run(command, check=True, text=True, capture_output=True, env=env).stdout


def get_db_connection() -> tuple[str, str]:
    config = configparser.ConfigParser(interpolation=None)
    config.read(GRAFANA_INI)
    db = config["database"]
    host, _, port = db["host"].rpartition(":")
    if not host:
        host, port = db["host"], "5432"
    db_name = db["name"]
    db_user = db["user"]
    ssl_mode = db.get("ssl_mode", "require")
    conn = f"host={host} port={port} dbname={db_name} user={db_user} sslmode={ssl_mode}"
    return conn, db["password"]


def query_db(sql: str) -> list[str]:
    conn, password = get_db_connection()
    shell = 'apk add --no-cache postgresql-client >/dev/null && exec psql "$1" -AtF "$(printf \'\\t\')" -c "$2"'
    output = run(
        ["docker", "run", "--pull=never", "--rm", "-e", "PGPASSWORD", "alpine:3.20", "sh", "-lc", shell, "sh", conn, sql],
        env={**os.environ, "PGPASSWORD": password},
    )
    return [line for line in output.splitlines() if line and not line.startswith("*") and not line.startswith("WARNING:")]


def execute_sql(statement: str) -> None:
    conn, password = get_db_connection()
    shell = 'apk add --no-cache postgresql-client >/dev/null && exec psql "$1" -v ON_ERROR_STOP=1 -c "$2"'
    run(
        ["docker", "run", "--pull=never", "--rm", "-e", "PGPASSWORD", "alpine:3.20", "sh", "-lc", shell, "sh", conn, statement],
        env={**os.environ, "PGPASSWORD": password},
    )


def load_active_provisioned_uids() -> set[str]:
    alerting_dirs = [
        ROOT / "grafana/provisioning/alerting",
        Path("/dataplatform/data-tools/grafana/provisioning/alerting"),
    ]
    uids: set[str] = set()
    seen_paths = set()
    for directory in alerting_dirs:
        if not directory.exists():
            continue
        for yml_file in directory.glob("*.yml"):
            real = yml_file.resolve()
            if real in seen_paths:
                continue
            seen_paths.add(real)
            try:
                content = yaml.safe_load(yml_file.read_text(encoding="utf-8")) or {}
                for grp in content.get("groups", []):
                    for rule in grp.get("rules", []):
                        uid = rule.get("uid")
                        if uid:
                            uids.add(uid)
            except Exception as exc:
                print(f"Warning: Failed to parse {yml_file}: {exc}", file=sys.stderr)
    return uids


def load_valid_datasource_uids() -> set[str]:
    rows = query_db("SELECT uid, name FROM data_source;")
    uids = set()
    for line in rows:
        parts = line.split("\t", 1)
        if parts:
            uids.add(parts[0])
    return uids


def find_orphaned_rules(active_uids: set[str], valid_ds_uids: set[str]) -> list[dict[str, str]]:
    settings = json.loads(LOCAL_CONFIG.read_text()) if LOCAL_CONFIG.exists() else {}
    exclude_patterns = [re.compile(p, re.I) for p in settings.get("exclude_instance_patterns", [])]

    rows = query_db("SELECT uid, title, rule_group, data FROM alert_rule;")
    orphaned = []
    for line in rows:
        parts = line.split("\t", 3)
        if len(parts) < 3:
            continue
        uid, title, group = parts[0], parts[1], parts[2]
        data_json = parts[3] if len(parts) > 3 else "[]"

        reason = None
        # Check 1: Explicit pattern exclusion (e.g. wct)
        if any(p.search(title) or p.search(uid) or p.search(group) for p in exclude_patterns):
            reason = "matches exclude_instance_patterns"

        # Check 2: Managed rule prefix but no longer in active YAML provisioning
        elif any(uid.startswith(pfx) for pfx in MANAGED_PREFIXES) and uid not in active_uids:
            reason = "not present in active provisioning files"

        # Check 3: References a datasource UID that no longer exists in data_source table
        else:
            try:
                queries = json.loads(data_json)
                for q in queries:
                    ds_uid = q.get("datasourceUid")
                    if ds_uid and ds_uid != "__expr__" and ds_uid not in valid_ds_uids:
                        reason = f"references dropped datasource UID '{ds_uid}'"
                        break
            except Exception:
                pass

        if reason:
            orphaned.append({"uid": uid, "title": title, "group": group, "reason": reason})

    return orphaned


def prune_rules(orphaned: list[dict[str, str]], dry_run: bool = False) -> int:
    if not orphaned:
        print("Reconcile: No orphaned or stale alert rules found. Database is clean.")
        return 0

    print(f"Reconcile: Found {len(orphaned)} orphaned alert rules in Grafana DB:")
    for item in orphaned:
        print(f"  - [{item['uid']}] \"{item['title']}\" (Reason: {item['reason']})")

    if dry_run:
        print("Reconcile: Dry-run mode enabled; no rules deleted.")
        return len(orphaned)

    uids = [item["uid"] for item in orphaned]
    uids_in = ", ".join(f"'{u}'" for u in uids)
    sql = f"""
    BEGIN;
    DELETE FROM alert_rule_state WHERE rule_uid IN ({uids_in});
    DELETE FROM alert_rule_version WHERE rule_uid IN ({uids_in});
    DELETE FROM alert_instance WHERE rule_uid IN ({uids_in});
    DELETE FROM alert_rule WHERE uid IN ({uids_in});
    COMMIT;
    """
    execute_sql(sql)
    print(f"Reconcile: Successfully pruned {len(orphaned)} orphaned alert rules from Grafana DB.")
    return len(orphaned)


def main() -> int:
    parser = argparse.ArgumentParser(description="Reconcile and prune orphaned Grafana alert rules.")
    parser.add_argument("--dry-run", action="store_true", help="Print orphaned rules without deleting them.")
    args = parser.parse_args()

    active_uids = load_active_provisioned_uids()
    valid_ds_uids = load_valid_datasource_uids()
    orphaned = find_orphaned_rules(active_uids, valid_ds_uids)
    count = prune_rules(orphaned, dry_run=args.dry_run)
    return 0


if __name__ == "__main__":
    sys.exit(main())
