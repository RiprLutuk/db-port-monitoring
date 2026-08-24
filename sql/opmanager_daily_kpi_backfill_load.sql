/*
Idempotent PostgreSQL loader for OpManager daily KPI history.

Input:
  UTF-8 CSV with a header, exported from
  sql/opmanager_daily_kpi_backfill_extract.sql.

Safety:
  - Only the configured historical range is accepted.
  - Counts must be non-negative and probes must equal up + down.
  - Slow and latency counts cannot exceed successful probes.
  - Target dimensions must be stable across the staged history.
  - KPI conflicts are replaced, not added, so rerunning the same file does not
    double the totals.
  - New source-only targets are registered as inactive historical inventory.
  - Existing target activity and monitoring_excluded settings are preserved;
    newly discovered historical targets default to monitoring_excluded=false.
*/

\if :{?backfill_from_inclusive}
\else
\set backfill_from_inclusive '2024-07-29'
\endif

\if :{?backfill_to_exclusive}
\else
\set backfill_to_exclusive '2026-07-07'
\endif

BEGIN;

SET LOCAL search_path TO pg_temp, :"schema_name";

CREATE TEMP TABLE opmanager_daily_kpi_stage (
    period_start date NOT NULL,
    target_name text NOT NULL,
    db_type text NOT NULL,
    environment text NOT NULL,
    host text NOT NULL,
    port int NOT NULL,
    instance text NOT NULL,
    criticality text NULL,
    team text NULL,
    probes bigint NOT NULL,
    up_probes bigint NOT NULL,
    down_probes bigint NOT NULL,
    latency_ms_sum numeric NOT NULL,
    latency_ms_count bigint NOT NULL,
    first_probe_at timestamptz NOT NULL,
    last_probe_at timestamptz NOT NULL,
    updated_at timestamptz NOT NULL,
    slow_probes bigint NOT NULL,
    max_latency_ms numeric NOT NULL
);

CREATE TEMP TABLE opmanager_backfill_bounds AS
SELECT
    :'backfill_from_inclusive'::date AS from_inclusive,
    :'backfill_to_exclusive'::date AS to_exclusive;

\copy opmanager_daily_kpi_stage (period_start, target_name, db_type, environment, host, port, instance, criticality, team, probes, up_probes, down_probes, latency_ms_sum, latency_ms_count, first_probe_at, last_probe_at, updated_at, slow_probes, max_latency_ms) FROM '__STAGE_FILE__' WITH (FORMAT csv, HEADER true, NULL '')

DO $validation$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM opmanager_daily_kpi_stage) THEN
        RAISE EXCEPTION 'OpManager KPI stage file contains no rows';
    END IF;

    IF EXISTS (
        SELECT 1
        FROM opmanager_daily_kpi_stage AS stage
        CROSS JOIN opmanager_backfill_bounds AS bounds
        WHERE stage.period_start < bounds.from_inclusive
           OR stage.period_start >= bounds.to_exclusive
    ) THEN
        RAISE EXCEPTION 'OpManager KPI stage contains rows outside the configured range';
    END IF;

    IF EXISTS (
        SELECT 1
        FROM opmanager_daily_kpi_stage
        GROUP BY period_start, target_name
        HAVING count(*) > 1
    ) THEN
        RAISE EXCEPTION 'OpManager KPI stage contains duplicate (period_start, target_name) rows';
    END IF;

    IF EXISTS (
        SELECT 1
        FROM opmanager_daily_kpi_stage
        WHERE port NOT BETWEEN 1 AND 65535
           OR probes <= 0
           OR up_probes < 0
           OR down_probes < 0
           OR slow_probes < 0
           OR latency_ms_sum < 0
           OR latency_ms_count < 0
           OR probes <> up_probes + down_probes
           OR slow_probes > up_probes
           OR latency_ms_count > up_probes
           OR (latency_ms_count = 0 AND latency_ms_sum <> 0)
           OR (latency_ms_count = 0 AND max_latency_ms <> 0)
           OR (
               latency_ms_count > 0
               AND max_latency_ms < latency_ms_sum / latency_ms_count
           )
           OR max_latency_ms < 0
           OR first_probe_at <>
              (period_start::timestamp AT TIME ZONE 'Asia/Jakarta')
           OR last_probe_at <>
              (
                  ((period_start + 1)::timestamp - interval '1 second')
                  AT TIME ZONE 'Asia/Jakarta'
              )
    ) THEN
        RAISE EXCEPTION
            'OpManager KPI stage contains invalid ports, counters, latency, or daily boundaries';
    END IF;

    IF EXISTS (
        SELECT 1
        FROM opmanager_daily_kpi_stage
        GROUP BY target_name
        HAVING count(DISTINCT db_type) > 1
            OR count(DISTINCT environment) > 1
            OR count(DISTINCT host) > 1
            OR count(DISTINCT port) > 1
            OR count(DISTINCT instance) > 1
    ) THEN
        RAISE EXCEPTION 'OpManager KPI stage contains inconsistent target dimensions';
    END IF;
END
$validation$;

WITH source_targets AS (
    SELECT
        target_name,
        max(db_type) AS db_type,
        max(environment) AS environment,
        max(host) AS host,
        max(port) AS port,
        max(instance) AS instance,
        max(criticality) AS criticality,
        max(team) AS team,
        min(first_probe_at) AS first_seen_at,
        max(last_probe_at) AS last_seen_at
    FROM opmanager_daily_kpi_stage
    GROUP BY target_name
)
INSERT INTO :"schema_name".db_port_blackbox_targets AS inventory (
    target_name,
    db_type,
    environment,
    host,
    port,
    instance,
    criticality,
    team,
    monitoring_excluded,
    is_active,
    first_seen_at,
    last_seen_at
)
SELECT
    target_name,
    db_type,
    environment,
    host,
    port,
    instance,
    criticality,
    team,
    false,
    false,
    first_seen_at,
    last_seen_at
FROM source_targets
ON CONFLICT (target_name) DO UPDATE SET
    first_seen_at = least(inventory.first_seen_at, EXCLUDED.first_seen_at),
    last_seen_at = greatest(inventory.last_seen_at, EXCLUDED.last_seen_at),
    updated_at = now();

INSERT INTO :"schema_name".db_port_blackbox_daily_kpi AS kpi (
    period_start,
    target_name,
    db_type,
    environment,
    host,
    port,
    instance,
    criticality,
    team,
    probes,
    up_probes,
    down_probes,
    latency_ms_sum,
    latency_ms_count,
    first_probe_at,
    last_probe_at,
    updated_at,
    slow_probes,
    max_latency_ms
)
SELECT
    period_start,
    target_name,
    db_type,
    environment,
    host,
    port,
    instance,
    criticality,
    team,
    probes,
    up_probes,
    down_probes,
    latency_ms_sum,
    latency_ms_count,
    first_probe_at,
    last_probe_at,
    updated_at,
    slow_probes,
    max_latency_ms
FROM opmanager_daily_kpi_stage
ON CONFLICT (period_start, target_name) DO UPDATE SET
    db_type = EXCLUDED.db_type,
    environment = EXCLUDED.environment,
    host = EXCLUDED.host,
    port = EXCLUDED.port,
    instance = EXCLUDED.instance,
    criticality = EXCLUDED.criticality,
    team = EXCLUDED.team,
    probes = EXCLUDED.probes,
    up_probes = EXCLUDED.up_probes,
    down_probes = EXCLUDED.down_probes,
    slow_probes = EXCLUDED.slow_probes,
    latency_ms_sum = EXCLUDED.latency_ms_sum,
    latency_ms_count = EXCLUDED.latency_ms_count,
    max_latency_ms = EXCLUDED.max_latency_ms,
    first_probe_at = EXCLUDED.first_probe_at,
    last_probe_at = EXCLUDED.last_probe_at,
    updated_at = EXCLUDED.updated_at;

SELECT
    count(*)::bigint AS loaded_kpi_rows,
    count(DISTINCT target_name)::bigint AS loaded_targets,
    min(period_start) AS first_period,
    max(period_start) AS last_period,
    sum(probes)::bigint AS equivalent_probes,
    sum(up_probes)::bigint AS equivalent_up_probes,
    sum(down_probes)::bigint AS equivalent_down_probes
FROM opmanager_daily_kpi_stage;

COMMIT;
