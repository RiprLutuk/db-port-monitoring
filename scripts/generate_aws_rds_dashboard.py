#!/usr/bin/env python3
"""Generate a reusable, multi-account Amazon RDS CloudWatch dashboard."""

from pathlib import Path
from copy import deepcopy
import json


OUTPUT_DIR = Path(__file__).parents[1] / "grafana"
DATASOURCE = {"type": "cloudwatch", "uid": "$datasource"}


def target(ref_id, metric, statistic="Average", *, label=None):
    item = {
        "datasource": DATASOURCE,
        "dimensions": {"DBInstanceIdentifier": "$instance"},
        "expression": "",
        "id": ref_id.lower(),
        "matchExact": False,
        "metricEditorMode": 0,
        "metricName": metric,
        "metricQueryType": 0,
        "namespace": "AWS/RDS",
        # Auto scales the CloudWatch period with the selected time range and
        # avoids GetMetricData's aggregate datapoint limit on long ranges.
        "period": "auto",
        "queryMode": "Metrics",
        "refId": ref_id,
        "region": "$region",
        "sqlExpression": "",
        "statistic": statistic,
    }
    if label:
        item["label"] = label
    return item


def timeseries(panel_id, title, x, y, w, h, unit, targets, *, minimum=None, maximum=None, description=""):
    defaults = {
        "color": {"mode": "palette-classic"},
        "custom": {
            "axisCenteredZero": False,
            "axisColorMode": "text",
            "axisLabel": "",
            "axisPlacement": "auto",
            "drawStyle": "line",
            "fillOpacity": 12,
            "gradientMode": "none",
            "hideFrom": {"legend": False, "tooltip": False, "viz": False},
            "lineInterpolation": "smooth",
            "lineWidth": 1,
            "pointSize": 3,
            "scaleDistribution": {"type": "linear"},
            "showPoints": "never",
            "spanNulls": True,
            "stacking": {"group": "A", "mode": "none"},
            "thresholdsStyle": {"mode": "off"},
        },
        "mappings": [],
        "thresholds": {
            "mode": "absolute",
            "steps": [{"color": "green", "value": None}],
        },
        "unit": unit,
    }
    if minimum is not None:
        defaults["min"] = minimum
    if maximum is not None:
        defaults["max"] = maximum
    return {
        "id": panel_id,
        "type": "timeseries",
        "title": title,
        "description": description,
        "datasource": DATASOURCE,
        "gridPos": {"x": x, "y": y, "w": w, "h": h},
        "fieldConfig": {"defaults": defaults, "overrides": []},
        "options": {
            "legend": {
                "calcs": [],
                "displayMode": "list",
                "placement": "bottom",
                "showLegend": True,
            },
            "tooltip": {"mode": "multi", "sort": "desc"},
        },
        "targets": targets,
    }


def row(panel_id, title, y):
    return {
        "id": panel_id,
        "type": "row",
        "title": title,
        "collapsed": False,
        "gridPos": {"x": 0, "y": y, "w": 24, "h": 1},
        "panels": [],
    }


panels = [
    row(1, "Core Health", 0),
    timeseries(2, "CPU Utilization", 0, 1, 6, 5, "percent", [target("A", "CPUUtilization", "Maximum")], minimum=0, maximum=100),
    timeseries(3, "Free Storage Space", 6, 1, 6, 5, "bytes", [target("A", "FreeStorageSpace", "Minimum")], minimum=0,
               description="Available instance storage. Aurora and storage-autoscaling behavior can differ by engine."),
    timeseries(4, "Freeable Memory", 12, 1, 6, 5, "bytes", [target("A", "FreeableMemory", "Minimum")], minimum=0),
    timeseries(5, "Database Connections", 18, 1, 6, 5, "short", [target("A", "DatabaseConnections", "Maximum")], minimum=0),

    row(10, "I/O and Storage Pressure", 6),
    timeseries(11, "Read / Write IOPS", 0, 7, 6, 5, "iops", [
        target("A", "ReadIOPS", "Average", label="${PROP('Dim.DBInstanceIdentifier')} read"),
        target("B", "WriteIOPS", "Average", label="${PROP('Dim.DBInstanceIdentifier')} write"),
    ], minimum=0),
    timeseries(12, "Read / Write Latency", 6, 7, 6, 5, "s", [
        target("A", "ReadLatency", "Average", label="${PROP('Dim.DBInstanceIdentifier')} read"),
        target("B", "WriteLatency", "Average", label="${PROP('Dim.DBInstanceIdentifier')} write"),
    ], minimum=0),
    timeseries(13, "Read / Write Throughput", 12, 7, 6, 5, "Bps", [
        target("A", "ReadThroughput", "Average", label="${PROP('Dim.DBInstanceIdentifier')} read"),
        target("B", "WriteThroughput", "Average", label="${PROP('Dim.DBInstanceIdentifier')} write"),
    ], minimum=0),
    timeseries(14, "Disk Queue Depth", 18, 7, 6, 5, "short", [target("A", "DiskQueueDepth", "Average")], minimum=0),

    row(20, "Reliability and Capacity Signals", 12),
    timeseries(21, "Deadlocks", 0, 13, 8, 5, "short", [target("A", "Deadlocks", "Sum")], minimum=0,
               description="Deadlocks are not the same as live blocking sessions. Exact blockers require engine SQL or Performance Insights."),
    timeseries(22, "Replica Lag", 8, 13, 8, 5, "s", [target("A", "ReplicaLag", "Maximum")], minimum=0),
    timeseries(23, "Swap Usage", 16, 13, 8, 5, "bytes", [target("A", "SwapUsage", "Maximum")], minimum=0),
    timeseries(24, "Network Throughput", 0, 18, 8, 5, "Bps", [
        target("A", "NetworkReceiveThroughput", "Average", label="${PROP('Dim.DBInstanceIdentifier')} receive"),
        target("B", "NetworkTransmitThroughput", "Average", label="${PROP('Dim.DBInstanceIdentifier')} transmit"),
    ], minimum=0),
    timeseries(25, "Burst Balance", 8, 18, 8, 5, "percent", [target("A", "BurstBalance", "Minimum")], minimum=0, maximum=100),
    timeseries(26, "Transaction Log Disk Usage", 16, 18, 8, 5, "bytes", [target("A", "TransactionLogsDiskUsage", "Maximum")], minimum=0,
               description="Engine-specific metric; unsupported engines return no series."),

    row(30, "Engine-specific Database Signals", 23),
    timeseries(31, "MySQL Binlog Disk Usage", 0, 24, 6, 5, "bytes", [target("A", "BinLogDiskUsage", "Maximum")], minimum=0,
               description="MySQL only. Disk space occupied by binary logs."),
    timeseries(32, "PostgreSQL WAL / Slot Storage", 6, 24, 6, 5, "bytes", [
        target("A", "TransactionLogsDiskUsage", "Maximum", label="${PROP('Dim.DBInstanceIdentifier')} WAL"),
        target("B", "ReplicationSlotDiskUsage", "Maximum", label="${PROP('Dim.DBInstanceIdentifier')} slots"),
    ], minimum=0, description="PostgreSQL only. WAL and replication-slot retained storage."),
    timeseries(33, "Active / Blocked Transactions", 12, 24, 6, 5, "short", [
        target("A", "ActiveTransactionsCount", "Maximum", label="${PROP('Dim.DBInstanceIdentifier')} active"),
        target("B", "BlockedTransactionsCount", "Maximum", label="${PROP('Dim.DBInstanceIdentifier')} blocked"),
    ], minimum=0, description="High-level transaction counts from Database Insights; not session PID detail."),
    timeseries(34, "DB Load: CPU / Non-CPU", 18, 24, 6, 5, "short", [
        target("A", "DBLoadCPU", "Average", label="${PROP('Dim.DBInstanceIdentifier')} CPU"),
        target("B", "DBLoadNonCPU", "Average", label="${PROP('Dim.DBInstanceIdentifier')} waits"),
    ], minimum=0, description="Average active sessions split between CPU and non-CPU waits."),

    timeseries(35, "MySQL InnoDB Deadlocks", 0, 29, 6, 5, "short", [target("A", "InnoDBDeadlocks", "Sum")], minimum=0,
               description="MySQL only. InnoDB deadlocks reported by Database Insights."),
    timeseries(36, "MySQL InnoDB Log Writes", 6, 29, 6, 5, "ops", [
        target("A", "InnoDBLogWrites", "Average", label="${PROP('Dim.DBInstanceIdentifier')} writes"),
        target("B", "InnoDBLogWriteRequests", "Average", label="${PROP('Dim.DBInstanceIdentifier')} requests"),
    ], minimum=0, description="MySQL only. InnoDB redo-log write activity."),
    timeseries(37, "PostgreSQL WAL Generation", 12, 29, 6, 5, "Bps", [target("A", "TransactionLogsGeneration", "Average")], minimum=0,
               description="PostgreSQL only. Transaction-log generation rate."),
    timeseries(38, "PostgreSQL Replication Slot Lag", 18, 29, 6, 5, "bytes", [
        target("A", "OldestReplicationSlotLag", "Maximum", label="${PROP('Dim.DBInstanceIdentifier')} physical"),
        target("B", "OldestLogicalReplicationSlotLag", "Maximum", label="${PROP('Dim.DBInstanceIdentifier')} logical"),
    ], minimum=0, description="PostgreSQL only. Retained WAL behind the oldest replication slots."),

    {
        "id": 40,
        "type": "text",
        "title": "Blocking visibility",
        "gridPos": {"x": 0, "y": 34, "w": 24, "h": 3},
        "options": {
            "mode": "markdown",
            "content": (
                "This dashboard now shows high-level **BlockedTransactionsCount**, **Deadlocks**, and DB load/waits when "
                "Database Insights publishes them. CloudWatch still does not expose the current blocker PID, blocked PID, "
                "or exact blocking duration as standard time-series fields. Use the engine-specific SQL blocking dashboards "
                "or the Performance Insights API for session-level investigation."
            ),
        },
    },
]


dashboard = {
    "annotations": {
        "list": [{
            "builtIn": 1,
            "datasource": {"type": "grafana", "uid": "-- Grafana --"},
            "enable": True,
            "hide": True,
            "iconColor": "rgba(0, 211, 255, 1)",
            "name": "Annotations & Alerts",
            "type": "dashboard",
        }]
    },
    "description": "Centralized Amazon RDS operational overview across CloudWatch datasource accounts.",
    "editable": True,
    "fiscalYearStartMonth": 0,
    "graphTooltip": 1,
    "id": None,
    "links": [],
    "liveNow": False,
    "panels": panels,
    "refresh": "1m",
    "schemaVersion": 41,
    "tags": ["aws", "rds", "database", "centralized"],
    "templating": {
        "list": [
            {
                "name": "datasource",
                "label": "AWS Account / Datasource",
                "type": "datasource",
                "query": "cloudwatch",
                "regex": "/^Amazon RDS/",
                "refresh": 1,
                "hide": 0,
                "includeAll": False,
                "multi": False,
                "current": {},
                "options": [],
            },
            {
                "name": "region",
                "label": "Region",
                "type": "custom",
                "query": "ap-northeast-1,ap-southeast-1,ap-southeast-2,ap-southeast-3,us-east-1",
                "hide": 0,
                "includeAll": False,
                "multi": False,
                "current": {"text": "ap-southeast-3", "value": "ap-southeast-3"},
                "options": [
                    {"selected": False, "text": "ap-northeast-1", "value": "ap-northeast-1"},
                    {"selected": False, "text": "ap-southeast-1", "value": "ap-southeast-1"},
                    {"selected": False, "text": "ap-southeast-2", "value": "ap-southeast-2"},
                    {"selected": True, "text": "ap-southeast-3", "value": "ap-southeast-3"},
                    {"selected": False, "text": "us-east-1", "value": "us-east-1"},
                ],
            },
            {
                "name": "instance",
                "label": "RDS Instance",
                "type": "query",
                "datasource": DATASOURCE,
                "definition": "dimension_values($region,AWS/RDS,CPUUtilization,DBInstanceIdentifier)",
                "query": "dimension_values($region,AWS/RDS,CPUUtilization,DBInstanceIdentifier)",
                "refresh": 1,
                "hide": 0,
                "includeAll": True,
                "allValue": "*",
                "multi": True,
                "current": {"text": "All", "value": ["*"]},
                "options": [],
            },
            {
                "name": "period",
                "label": "Period",
                "type": "custom",
                "query": "60,300,900,3600",
                "hide": 0,
                "includeAll": False,
                "multi": False,
                "current": {"text": "300", "value": "300"},
                "options": [
                    {"selected": False, "text": "60", "value": "60"},
                    {"selected": True, "text": "300", "value": "300"},
                    {"selected": False, "text": "900", "value": "900"},
                    {"selected": False, "text": "3600", "value": "3600"},
                ],
            },
        ]
    },
    "time": {"from": "now-12h", "to": "now"},
    "timepicker": {},
    "timezone": "browser",
    "title": "AWS RDS Central Overview",
    "uid": "aws-rds-central-v1",
    "version": 1,
    "weekStart": "monday",
}

# Period is intentionally automatic for every dashboard query. A fixed period
# becomes unsafe when users expand the time picker to several days or months.
dashboard["templating"]["list"] = [
    variable for variable in dashboard["templating"]["list"] if variable["name"] != "period"
]

def dashboard_link(title, uid, slug):
    return {
        "asDropdown": False,
        "icon": "external link",
        "includeVars": True,
        "keepTime": True,
        "tags": [],
        "targetBlank": False,
        "title": title,
        "tooltip": "",
        "type": "link",
        "url": f"/d/{uid}/{slug}",
    }


def engine_variables(engine_prefix):
    variables = deepcopy(dashboard["templating"])
    for variable in variables["list"]:
        if variable["name"] == "instance":
            variable["regex"] = f"/^rds-{engine_prefix}-/"
            # Do not use the custom wildcard "*" here. Grafana must expand All
            # to the regex-filtered option list, otherwise CloudWatch returns
            # every engine in the selected account.
            variable.pop("allValue", None)
            variable["current"] = {"selected": True, "text": "All", "value": "$__all"}
    return variables


def base_engine_panels(engine_panels):
    return [
        row(1, "Core Health", 0),
        timeseries(2, "CPU Utilization", 0, 1, 6, 5, "percent", [target("A", "CPUUtilization", "Maximum")], minimum=0, maximum=100),
        timeseries(3, "Free Storage Space", 6, 1, 6, 5, "bytes", [target("A", "FreeStorageSpace", "Minimum")], minimum=0),
        timeseries(4, "Freeable Memory", 12, 1, 6, 5, "bytes", [target("A", "FreeableMemory", "Minimum")], minimum=0),
        timeseries(5, "Database Connections", 18, 1, 6, 5, "short", [target("A", "DatabaseConnections", "Maximum")], minimum=0),
        row(10, "I/O and Network", 6),
        timeseries(11, "Read / Write IOPS", 0, 7, 6, 5, "iops", [
            target("A", "ReadIOPS", "Average", label="${PROP('Dim.DBInstanceIdentifier')} read"),
            target("B", "WriteIOPS", "Average", label="${PROP('Dim.DBInstanceIdentifier')} write"),
        ], minimum=0),
        timeseries(12, "Read / Write Latency", 6, 7, 6, 5, "s", [
            target("A", "ReadLatency", "Average", label="${PROP('Dim.DBInstanceIdentifier')} read"),
            target("B", "WriteLatency", "Average", label="${PROP('Dim.DBInstanceIdentifier')} write"),
        ], minimum=0),
        timeseries(13, "Disk Queue Depth", 12, 7, 6, 5, "short", [target("A", "DiskQueueDepth", "Average")], minimum=0),
        timeseries(14, "Network Throughput", 18, 7, 6, 5, "Bps", [
            target("A", "NetworkReceiveThroughput", "Average", label="${PROP('Dim.DBInstanceIdentifier')} receive"),
            target("B", "NetworkTransmitThroughput", "Average", label="${PROP('Dim.DBInstanceIdentifier')} transmit"),
        ], minimum=0),
    ] + engine_panels


mysql_panels = base_engine_panels([
    row(20, "MySQL Database Signals", 12),
    timeseries(21, "Binlog Disk Usage", 0, 13, 6, 5, "bytes", [target("A", "BinLogDiskUsage", "Maximum")], minimum=0),
    timeseries(22, "Active / Blocked Transactions", 6, 13, 6, 5, "short", [
        target("A", "ActiveTransactionsCount", "Maximum", label="${PROP('Dim.DBInstanceIdentifier')} active"),
        target("B", "BlockedTransactionsCount", "Maximum", label="${PROP('Dim.DBInstanceIdentifier')} blocked"),
    ], minimum=0),
    timeseries(23, "DB Load: CPU / Non-CPU", 12, 13, 6, 5, "short", [
        target("A", "DBLoadCPU", "Average", label="${PROP('Dim.DBInstanceIdentifier')} CPU"),
        target("B", "DBLoadNonCPU", "Average", label="${PROP('Dim.DBInstanceIdentifier')} waits"),
    ], minimum=0),
    timeseries(24, "InnoDB Deadlocks", 18, 13, 6, 5, "short", [target("A", "InnoDBDeadlocks", "Sum")], minimum=0),
    timeseries(25, "InnoDB Log Writes", 0, 18, 8, 5, "ops", [
        target("A", "InnoDBLogWrites", "Average", label="${PROP('Dim.DBInstanceIdentifier')} writes"),
        target("B", "InnoDBLogWriteRequests", "Average", label="${PROP('Dim.DBInstanceIdentifier')} requests"),
    ], minimum=0),
    timeseries(26, "Deadlocks", 8, 18, 8, 5, "short", [target("A", "Deadlocks", "Sum")], minimum=0),
    timeseries(27, "Swap Usage", 16, 18, 8, 5, "bytes", [target("A", "SwapUsage", "Maximum")], minimum=0),
])

postgres_panels = base_engine_panels([
    row(20, "PostgreSQL Database Signals", 12),
    timeseries(21, "WAL / Replication Slot Storage", 0, 13, 6, 5, "bytes", [
        target("A", "TransactionLogsDiskUsage", "Maximum", label="${PROP('Dim.DBInstanceIdentifier')} WAL"),
        target("B", "ReplicationSlotDiskUsage", "Maximum", label="${PROP('Dim.DBInstanceIdentifier')} slots"),
    ], minimum=0),
    timeseries(22, "WAL Generation", 6, 13, 6, 5, "Bps", [target("A", "TransactionLogsGeneration", "Average")], minimum=0),
    timeseries(23, "Replication Slot Lag", 12, 13, 6, 5, "bytes", [
        target("A", "OldestReplicationSlotLag", "Maximum", label="${PROP('Dim.DBInstanceIdentifier')} physical"),
        target("B", "OldestLogicalReplicationSlotLag", "Maximum", label="${PROP('Dim.DBInstanceIdentifier')} logical"),
    ], minimum=0),
    timeseries(24, "Active / Blocked Transactions", 18, 13, 6, 5, "short", [
        target("A", "ActiveTransactionsCount", "Maximum", label="${PROP('Dim.DBInstanceIdentifier')} active"),
        target("B", "BlockedTransactionsCount", "Maximum", label="${PROP('Dim.DBInstanceIdentifier')} blocked"),
    ], minimum=0),
    timeseries(25, "DB Load: CPU / Non-CPU", 0, 18, 6, 5, "short", [
        target("A", "DBLoadCPU", "Average", label="${PROP('Dim.DBInstanceIdentifier')} CPU"),
        target("B", "DBLoadNonCPU", "Average", label="${PROP('Dim.DBInstanceIdentifier')} waits"),
    ], minimum=0),
    timeseries(26, "Transaction ID Usage", 6, 18, 6, 5, "short", [target("A", "MaximumUsedTransactionIDs", "Maximum")], minimum=0),
    timeseries(27, "Deadlocks", 12, 18, 6, 5, "short", [target("A", "Deadlocks", "Sum")], minimum=0),
    timeseries(28, "Swap Usage", 18, 18, 6, 5, "bytes", [target("A", "SwapUsage", "Maximum")], minimum=0),
])


central = deepcopy(dashboard)
central["panels"] = [p for p in panels if p["id"] < 26]
central["links"] = [
    dashboard_link("MySQL Overview", "aws-rds-mysql-v1", "aws-rds-mysql-overview"),
    dashboard_link("PostgreSQL Overview", "aws-rds-postgresql-v1", "aws-rds-postgresql-overview"),
]

mysql = deepcopy(dashboard)
mysql.update({
    "description": "Centralized Amazon RDS MySQL operational overview.",
    "links": [dashboard_link("Central Overview", "aws-rds-central-v1", "aws-rds-central-overview"), dashboard_link("PostgreSQL Overview", "aws-rds-postgresql-v1", "aws-rds-postgresql-overview")],
    "panels": mysql_panels,
    "tags": ["aws", "rds", "mysql", "database"],
    "templating": engine_variables("mysql"),
    "title": "AWS RDS MySQL Overview",
    "uid": "aws-rds-mysql-v1",
})

postgres = deepcopy(dashboard)
postgres.update({
    "description": "Centralized Amazon RDS PostgreSQL operational overview.",
    "links": [dashboard_link("Central Overview", "aws-rds-central-v1", "aws-rds-central-overview"), dashboard_link("MySQL Overview", "aws-rds-mysql-v1", "aws-rds-mysql-overview")],
    "panels": postgres_panels,
    "tags": ["aws", "rds", "postgresql", "database"],
    "templating": engine_variables("pg"),
    "title": "AWS RDS PostgreSQL Overview",
    "uid": "aws-rds-postgresql-v1",
})

outputs = [
    (OUTPUT_DIR / "aws-rds-central-overview.json", central),
    (OUTPUT_DIR / "aws-rds-mysql-overview.json", mysql),
    (OUTPUT_DIR / "aws-rds-postgresql-overview.json", postgres),
]
for output, content in outputs:
    output.write_text(json.dumps(content, indent=2) + "\n")
    print(f"Wrote {output} with {len(content['panels'])} panels")
