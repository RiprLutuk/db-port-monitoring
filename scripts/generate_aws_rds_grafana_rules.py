#!/usr/bin/env python3
"""Generate Grafana-managed CloudWatch alerts for production Amazon RDS instances."""

from __future__ import annotations

import hashlib
import json
from pathlib import Path
from urllib.parse import quote


OUTPUT = Path(__file__).parents[1] / "grafana/provisioning/alerting/aws-rds.yml"
LOCAL_CONFIG = Path(__file__).with_name("alerting-autodiscovery.local.json")
SETTINGS = json.loads(LOCAL_CONFIG.read_text()) if LOCAL_CONFIG.exists() else {}
REGION = SETTINGS.get("region", "ap-southeast-1")
GRAFANA_BASE_URL = SETTINGS.get("grafana_base_url", "https://grafana.example.com")
DASHBOARDS = {
    "mysql": f"{GRAFANA_BASE_URL}/d/aws-rds-mysql-v1/aws-rds-mysql-overview",
    "postgres": f"{GRAFANA_BASE_URL}/d/aws-rds-postgresql-v1/aws-rds-postgresql-overview",
}

# Allocated storage is captured from DescribeDBInstances. Re-run/update this inventory
# after resizing an instance so percentage-derived thresholds remain accurate.
INSTANCES = []

INVENTORY = Path(__file__).with_name("alerting-inventory.json")
if INVENTORY.exists():
    INSTANCES = [
        (
            item["company"], item["datasource_uid"], item["instance"],
            item["engine"], item["allocated_gib"],
        )
        for item in json.loads(INVENTORY.read_text())["rds_instances"]
    ]


def slug(value: str) -> str:
    return value.lower().replace("-", "_")


def short_id(company: str, instance: str) -> str:
    digest = hashlib.sha1(f"{company}:{instance}".encode()).hexdigest()[:12]
    return f"rds_{slug(company)[:8]}_{digest}"


def source_url(company: str, instance: str, engine: str) -> str:
    return (
        f"{DASHBOARDS[engine]}?orgId=1&from=now-12h&to=now&timezone=browser"
        f"&var-datasource={quote('Amazon RDS ' + company)}"
        f"&var-region={REGION}&var-instance={quote(instance)}&refresh=1m"
    )


def cloudwatch_query(datasource_uid: str, instance: str, metric: str, statistic: str, window: int) -> str:
    return f'''          - refId: A
            relativeTimeRange:
              from: {window}
              to: 0
            datasourceUid: {datasource_uid}
            model:
              datasource:
                type: cloudwatch
                uid: {datasource_uid}
              dimensions:
                DBInstanceIdentifier: {instance}
              expression: ""
              hide: false
              id: a
              intervalMs: 1000
              matchExact: true
              maxDataPoints: 43200
              metricEditorMode: 0
              metricName: {metric}
              metricQueryType: 0
              namespace: AWS/RDS
              period: "300"
              queryMode: Metrics
              refId: A
              region: {REGION}
              sqlExpression: ""
              statistic: {statistic}'''


def threshold(ref_id: str, expression: str, evaluator: str, value: int | float) -> str:
    return f'''          - refId: {ref_id}
            relativeTimeRange:
              from: 0
              to: 0
            datasourceUid: __expr__
            model:
              conditions:
                - evaluator:
                    params:
                      - {value}
                    type: {evaluator}
                  operator:
                    type: and
                  query:
                    params:
                      - {ref_id}
                  reducer:
                    params: []
                    type: last
                  type: query
              datasource:
                type: __expr__
                uid: __expr__
              expression: {expression}
              intervalMs: 1000
              maxDataPoints: 43200
              refId: {ref_id}
              type: threshold'''


def reduce(ref_id: str, expression: str, reducer: str = "last") -> str:
    return f'''          - refId: {ref_id}
            relativeTimeRange:
              from: 0
              to: 0
            datasourceUid: __expr__
            model:
              conditions:
                - evaluator:
                    params: []
                    type: gt
                  operator:
                    type: and
                  query:
                    params:
                      - {ref_id}
                  reducer:
                    params: []
                    type: {reducer}
                  type: query
              datasource:
                type: __expr__
                uid: __expr__
              expression: {expression}
              intervalMs: 1000
              maxDataPoints: 43200
              refId: {ref_id}
              reducer: {reducer}
              settings:
                mode: dropNN
              type: reduce'''


def labels(company: str, instance: str, engine: str, severity: str, alert_type: str) -> str:
    return f'''        labels:
          account: {company.lower()}
          alert_type: {alert_type}
          category: {"db-storage" if alert_type == "db_storage" else "db-deadlock"}
          db_name: {instance}
          environment: production
          notification_scope: it-data-db
          service: rds-{engine}
          severity: {severity}
          team: data
        notification_settings:
          receiver: forward-to-central-alertmanager
          group_by:
            - alertname
            - grafana_folder
            - db_name
          group_wait: 30s
          group_interval: 5m
          repeat_interval: 4h
        isPaused: false'''


def storage_rule(company: str, ds_uid: str, instance: str, engine: str, allocated_gib: int, critical: bool) -> str:
    warning_gib = min(allocated_gib * 0.15, 100)
    critical_gib = min(allocated_gib * 0.10, 50)
    warning_bytes = int(warning_gib * 1024**3)
    critical_bytes = int(critical_gib * 1024**3)
    kind = "critical" if critical else "warning"
    severity = "critical" if critical else "warning"
    duration = "15m" if critical else "30m"
    if critical:
        condition = f'''{reduce("B", "A")}
{threshold("C", "B", "lt", critical_bytes)}'''
        detail = f"Free storage is below {critical_gib:g} GiB (10% and 50 GiB guardrail)."
    else:
        # Math makes warning and critical mutually exclusive.
        condition = f'''{reduce("B", "A")}
          - refId: C
            relativeTimeRange:
              from: 0
              to: 0
            datasourceUid: __expr__
            model:
              datasource:
                type: __expr__
                uid: __expr__
              expression: "$B <= {warning_bytes} && $B > {critical_bytes}"
              intervalMs: 1000
              maxDataPoints: 43200
              refId: C
              type: math
{threshold("D", "C", "gt", 0)}'''
        detail = f"Free storage is below {warning_gib:g} GiB (15% and 100 GiB guardrail)."
    condition_ref = "C" if critical else "D"
    return f'''      - uid: {short_id(company, instance)}_s_{"c" if critical else "w"}
        title: RDS storage {kind} - {instance}
        condition: {condition_ref}
        data:
{cloudwatch_query(ds_uid, instance, "FreeStorageSpace", "Minimum", 1800)}
{condition}
        noDataState: OK
        execErrState: Error
        for: {duration}
        annotations:
          summary: "RDS {instance} free storage is {kind}"
          description: '{detail} Current: {{{{ $values.B.Value | humanize1024 }}}}.'
          source_url: "{source_url(company, instance, engine)}"
{labels(company, instance, engine, severity, "db_storage")}'''


def deadlock_rule(company: str, ds_uid: str, instance: str, engine: str) -> str:
    return f'''      - uid: {short_id(company, instance)}_dl
        title: RDS deadlock detected - {instance}
        condition: C
        data:
{cloudwatch_query(ds_uid, instance, "Deadlocks", "Sum", 300)}
{reduce("B", "A")}
{threshold("C", "B", "gt", 0)}
        noDataState: OK
        execErrState: Error
        for: 0s
        annotations:
          summary: "RDS {instance} detected a deadlock"
          description: 'Deadlocks in the last 5 minutes: {{{{ printf "%.0f" $values.B.Value }}}}.'
          source_url: "{source_url(company, instance, engine)}"
{labels(company, instance, engine, "critical", "db_deadlock")}'''


groups = []
for company, datasource_uid, instance, engine, allocated_gib in INSTANCES:
    rules = "\n".join(
        [
            storage_rule(company, datasource_uid, instance, engine, allocated_gib, False),
            storage_rule(company, datasource_uid, instance, engine, allocated_gib, True),
            deadlock_rule(company, datasource_uid, instance, engine),
        ]
    )
    groups.append(
        f'''  - orgId: 1
    name: {short_id(company, instance)}
    folder: AWS RDS Monitoring
    interval: 1m
    rules:
{rules}'''
    )

OUTPUT.parent.mkdir(parents=True, exist_ok=True)
OUTPUT.write_text(
    "# GENERATED FILE. Update scripts/generate_aws_rds_grafana_rules.py.\n"
    "apiVersion: 1\n"
    "groups:\n"
    + "\n".join(groups)
    + "\n"
)
print(f"Generated {len(INSTANCES) * 3} rules for {len(INSTANCES)} RDS instances: {OUTPUT}")
