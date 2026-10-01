#!/usr/bin/env python3
"""Discover production SQL datasources and RDS instances for rule generators."""

from __future__ import annotations

import configparser
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile


ROOT = Path(__file__).resolve().parents[1]
OUTPUT = ROOT / "scripts/alerting-inventory.json"
GRAFANA_INI = Path(os.environ.get("GRAFANA_INI", "/dataplatform/data-tools/grafana/grafana.ini"))
REGION = os.environ.get("AWS_RDS_REGION", "ap-southeast-3")
NON_PROD = re.compile(r"(^|[-_.])(dev|qa|qas|uat|test|sandbox)([-_.]|$)", re.I)
LOCAL_CONFIG = Path(os.environ.get(
    "ALERT_AUTODISCOVERY_CONFIG", ROOT / "scripts/alerting-autodiscovery.local.json"
))


def run(command: list[str], *, env: dict[str, str] | None = None) -> str:
    return subprocess.run(command, check=True, text=True, capture_output=True, env=env).stdout


def datasource_rows(query: str) -> list[dict[str, str]]:
    config = configparser.ConfigParser(interpolation=None)
    config.read(GRAFANA_INI)
    db = config["database"]
    host, _, port = db["host"].rpartition(":")
    if not host:
        host, port = db["host"], "5432"
    conn = f"host={host} port={port} dbname={db['name']} user={db['user']} sslmode={db.get('ssl_mode', 'require')}"
    shell = 'apk add --no-cache postgresql-client >/dev/null && exec psql "$1" -AtF "$(printf \'\\t\')" -c "$2"'
    output = run(
        ["docker", "run", "--pull=never", "--rm", "-e", "PGPASSWORD", "alpine:3.20", "sh", "-lc", shell, "sh", conn, query],
        env={**os.environ, "PGPASSWORD": db["password"]},
    )
    found = []
    for line in output.splitlines():
        if not line or line.startswith("*") or line.startswith("WARNING:"):
            continue
        uid, name, kind = line.split("\t", 2)
        found.append({"uid": uid, "name": name, "type": kind})
    return found


def sql_datasources() -> list[dict[str, str]]:
    rows = datasource_rows("SELECT uid, name, type FROM data_source WHERE type IN ('mssql','mysql','grafana-postgresql-datasource') ORDER BY type,name")
    found = []
    for item in rows:
        uid, name, kind = item["uid"], item["name"], item["type"]
        if NON_PROD.search(name):
            continue
        engine = {"mssql": "mssql", "mysql": "mysql", "grafana-postgresql-datasource": "postgresql"}[kind]
        found.append({"uid": uid, "name": name, "type": kind, "engine": engine})
    return found


def assumed_environment(account: str, role: str | None) -> dict[str, str]:
    environment = dict(os.environ)
    if not role:
        return environment
    credentials = json.loads(run([
        "aws", "sts", "assume-role", "--role-arn", f"arn:aws:iam::{account}:role/{role}",
        "--role-session-name", "grafana-alert-autodiscovery", "--duration-seconds", "900", "--output", "json",
    ]))["Credentials"]
    environment.update({
        "AWS_ACCESS_KEY_ID": credentials["AccessKeyId"],
        "AWS_SECRET_ACCESS_KEY": credentials["SecretAccessKey"],
        "AWS_SESSION_TOKEN": credentials["SessionToken"],
    })
    return environment


def rds_instances(datasources: list[dict[str, str]]) -> list[dict[str, object]]:
    by_name = {item["name"]: item for item in datasources}
    result = []
    settings = json.loads(LOCAL_CONFIG.read_text()) if LOCAL_CONFIG.exists() else {"rds_accounts": []}
    for account_config in settings.get("rds_accounts", []):
        datasource_name = account_config["datasource_name"]
        company = account_config["company"]
        account = account_config["account_id"]
        role = account_config.get("role_name")
        datasource = by_name.get(datasource_name)
        if not datasource:
            continue
        payload = json.loads(run([
            "aws", "rds", "describe-db-instances", "--region", REGION, "--output", "json",
        ], env=assumed_environment(account, role)))
        for instance in payload.get("DBInstances", []):
            name = instance["DBInstanceIdentifier"]
            if NON_PROD.search(name):
                continue
            engine_name = instance.get("Engine", "").lower()
            if engine_name.startswith("postgres"):
                engine = "postgres"
            elif engine_name.startswith("mysql") or engine_name.startswith("mariadb"):
                engine = "mysql"
            else:
                continue
            result.append({
                "company": company,
                "datasource_uid": datasource["uid"],
                "instance": name,
                "engine": engine,
                "allocated_gib": int(instance["AllocatedStorage"]),
                "region": REGION,
            })
    return sorted(result, key=lambda item: (str(item["company"]), str(item["instance"])))


def main() -> int:
    sql = sql_datasources()
    # CloudWatch rows are needed only to map datasource names to UIDs.
    cloudwatch = datasource_rows("SELECT uid, name, type FROM data_source WHERE type='cloudwatch' ORDER BY name")
    inventory = {"version": 1, "sql_datasources": sql, "rds_instances": rds_instances(cloudwatch)}
    rendered = json.dumps(inventory, indent=2, sort_keys=True) + "\n"
    old = OUTPUT.read_text() if OUTPUT.exists() else ""
    if rendered == old:
        print(f"Inventory unchanged: {len(sql)} SQL datasources, {len(inventory['rds_instances'])} RDS instances")
        return 0
    with tempfile.NamedTemporaryFile("w", dir=OUTPUT.parent, delete=False) as handle:
        handle.write(rendered)
        temporary = Path(handle.name)
    temporary.replace(OUTPUT)
    print(f"Inventory updated: {len(sql)} SQL datasources, {len(inventory['rds_instances'])} RDS instances")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except subprocess.CalledProcessError as exc:
        print(exc.stderr.strip() or str(exc), file=sys.stderr)
        raise SystemExit(1)
