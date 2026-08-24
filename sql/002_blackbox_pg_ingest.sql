\if :{?schema_name}
\else
\set schema_name monitoring
\endif

\if :{?raw_retention_days}
\else
\set raw_retention_days 30
\endif

\if :{?report_retention_days}
\else
\set report_retention_days 2192
\endif

\if :{?target_inactive_after_seconds}
\else
\set target_inactive_after_seconds 86400
\endif

\if :{?retention_delete_batch_size}
\else
\set retention_delete_batch_size 10000
\endif

BEGIN;

SET LOCAL search_path TO pg_temp, :"schema_name";

CREATE TEMP TABLE blackbox_probe_stage (
    checked_at_ms bigint NOT NULL,
    target_name text NOT NULL,
    db_type text NOT NULL,
    environment text NOT NULL,
    host text NOT NULL,
    port int NOT NULL,
    instance text NOT NULL,
    criticality text NULL,
    team text NULL,
    monitoring_excluded boolean NOT NULL,
    is_up int NOT NULL,
    latency_ms numeric NULL,
    error_text text NULL
);

\copy blackbox_probe_stage (checked_at_ms, target_name, db_type, environment, host, port, instance, criticality, team, monitoring_excluded, is_up, latency_ms, error_text) FROM '__STAGE_FILE__' WITH (FORMAT csv, DELIMITER E'\t', NULL '\N')

CREATE TEMP TABLE blackbox_target_stage AS
SELECT DISTINCT ON (target_name)
    target_name,
    db_type,
    environment,
    host,
    port,
    instance,
    criticality,
    team,
    monitoring_excluded,
    to_timestamp(checked_at_ms::numeric / 1000.0) AS checked_at
FROM blackbox_probe_stage
ORDER BY target_name, checked_at_ms DESC, monitoring_excluded DESC;

INSERT INTO :"schema_name".db_port_blackbox_targets AS target_inventory (
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
    monitoring_excluded,
    true,
    checked_at,
    checked_at
FROM blackbox_target_stage
ON CONFLICT (target_name) DO UPDATE SET
    db_type = EXCLUDED.db_type,
    environment = EXCLUDED.environment,
    host = EXCLUDED.host,
    port = EXCLUDED.port,
    instance = EXCLUDED.instance,
    criticality = EXCLUDED.criticality,
    team = EXCLUDED.team,
    monitoring_excluded = EXCLUDED.monitoring_excluded,
    is_active = true,
    last_seen_at = greatest(target_inventory.last_seen_at, EXCLUDED.last_seen_at),
    updated_at = now();

UPDATE :"schema_name".db_port_blackbox_targets AS target_inventory
SET
    is_active = false,
    updated_at = now()
WHERE is_active = true
  AND last_seen_at < now() - (:'target_inactive_after_seconds' || ' seconds')::interval
  AND NOT EXISTS (
      SELECT 1
      FROM blackbox_target_stage stage
      WHERE stage.target_name = target_inventory.target_name
  );

CREATE TEMP TABLE inserted_probe_rows AS
WITH inserted AS (
    INSERT INTO :"schema_name".db_port_blackbox_probe_results (
        checked_at,
        target_name,
        db_type,
        environment,
        host,
        port,
        instance,
        criticality,
        team,
        is_up,
        latency_ms,
        error_text
    )
    SELECT
        to_timestamp(checked_at_ms::numeric / 1000.0),
        target_name,
        db_type,
        environment,
        host,
        port,
        instance,
        criticality,
        team,
        is_up,
        latency_ms,
        error_text
    FROM blackbox_probe_stage
    ON CONFLICT (checked_at, target_name) DO NOTHING
    RETURNING
        checked_at,
        target_name,
        db_type,
        environment,
        host,
        port,
        instance,
        criticality,
        team,
        is_up,
        latency_ms,
        error_text
)
SELECT * FROM inserted;

WITH daily AS (
    SELECT
        checked_at::date AS period_start,
        target_name,
        max(db_type) AS db_type,
        max(environment) AS environment,
        max(host) AS host,
        max(port) AS port,
        max(instance) AS instance,
        max(criticality) AS criticality,
        max(team) AS team,
        count(*)::bigint AS probes,
        sum(CASE WHEN is_up = 1 THEN 1 ELSE 0 END)::bigint AS up_probes,
        sum(CASE WHEN is_up = 0 THEN 1 ELSE 0 END)::bigint AS down_probes,
        count(*) FILTER (WHERE is_up = 1 AND latency_ms > 3000)::bigint AS slow_probes,
        coalesce(sum(latency_ms) FILTER (WHERE is_up = 1 AND latency_ms IS NOT NULL), 0) AS latency_ms_sum,
        count(latency_ms) FILTER (WHERE is_up = 1)::bigint AS latency_ms_count,
        max(latency_ms) FILTER (WHERE is_up = 1) AS max_latency_ms,
        min(checked_at) AS first_probe_at,
        max(checked_at) AS last_probe_at
    FROM inserted_probe_rows
    GROUP BY checked_at::date, target_name
)
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
    slow_probes,
    latency_ms_sum,
    latency_ms_count,
    max_latency_ms,
    first_probe_at,
    last_probe_at
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
    slow_probes,
    latency_ms_sum,
    latency_ms_count,
    max_latency_ms,
    first_probe_at,
    last_probe_at
FROM daily
ON CONFLICT (period_start, target_name) DO UPDATE SET
    db_type = EXCLUDED.db_type,
    environment = EXCLUDED.environment,
    host = EXCLUDED.host,
    port = EXCLUDED.port,
    instance = EXCLUDED.instance,
    criticality = EXCLUDED.criticality,
    team = EXCLUDED.team,
    probes = kpi.probes + EXCLUDED.probes,
    up_probes = kpi.up_probes + EXCLUDED.up_probes,
    down_probes = kpi.down_probes + EXCLUDED.down_probes,
    slow_probes = kpi.slow_probes + EXCLUDED.slow_probes,
    latency_ms_sum = kpi.latency_ms_sum + EXCLUDED.latency_ms_sum,
    latency_ms_count = kpi.latency_ms_count + EXCLUDED.latency_ms_count,
    max_latency_ms = greatest(
        coalesce(kpi.max_latency_ms, EXCLUDED.max_latency_ms),
        EXCLUDED.max_latency_ms
    ),
    first_probe_at = least(
        coalesce(kpi.first_probe_at, EXCLUDED.first_probe_at),
        EXCLUDED.first_probe_at
    ),
    last_probe_at = greatest(
        coalesce(kpi.last_probe_at, EXCLUDED.last_probe_at),
        EXCLUDED.last_probe_at
    ),
    updated_at = now();

-- Only newly inserted raw rows are processed, so the writer's overlapping
-- Prometheus windows cannot increment an outage more than once.
DO $process_outage_events$
DECLARE
    probe record;
BEGIN
    FOR probe IN
        SELECT target_name, checked_at
        FROM inserted_probe_rows
        ORDER BY target_name, checked_at
    LOOP
        PERFORM record_db_port_blackbox_outage_sample(
            probe.target_name,
            probe.checked_at
        );
    END LOOP;
END
$process_outage_events$;

-- Keep cleanup transactions bounded. In steady state this removes roughly one
-- expired five-minute bucket per target; after an outage it catches up over
-- multiple cycles instead of locking and vacuuming a very large delete at once.
WITH expired AS (
    SELECT id
    FROM :"schema_name".db_port_blackbox_probe_results
    WHERE checked_at < now() - (:'raw_retention_days' || ' days')::interval
    ORDER BY checked_at
    LIMIT :retention_delete_batch_size
    FOR UPDATE SKIP LOCKED
)
DELETE FROM :"schema_name".db_port_blackbox_probe_results AS probe
USING expired
WHERE probe.id = expired.id;

WITH expired AS (
    SELECT period_start, target_name
    FROM :"schema_name".db_port_blackbox_daily_kpi
    WHERE period_start < (current_date - :report_retention_days::int)
    ORDER BY period_start, target_name
    LIMIT :retention_delete_batch_size
    FOR UPDATE SKIP LOCKED
)
DELETE FROM :"schema_name".db_port_blackbox_daily_kpi AS kpi
USING expired
WHERE kpi.period_start = expired.period_start
  AND kpi.target_name = expired.target_name;

WITH expired AS (
    SELECT target_name, down_start
    FROM :"schema_name".db_port_blackbox_downtime_events
    WHERE coalesce(down_end, last_down_at) <
        now() - (:'report_retention_days' || ' days')::interval
    ORDER BY coalesce(down_end, last_down_at), target_name, down_start
    LIMIT :retention_delete_batch_size
    FOR UPDATE SKIP LOCKED
)
DELETE FROM :"schema_name".db_port_blackbox_downtime_events AS event
USING expired
WHERE event.target_name = expired.target_name
  AND event.down_start = expired.down_start;

SELECT count(*)::bigint AS inserted_probe_rows
FROM inserted_probe_rows;

COMMIT;
