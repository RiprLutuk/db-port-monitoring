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

-- Recompute every affected target-day from all retained raw rows. Prometheus may
-- briefly return the old and new scrape phase after an endpoint change, so raw
-- row counts are not guaranteed to equal the five-minute reporting cadence.
CREATE TEMP TABLE affected_target_days ON COMMIT DROP AS
SELECT DISTINCT
    checked_at::date AS period_start,
    target_name
FROM inserted_probe_rows;

CREATE UNIQUE INDEX ON affected_target_days (period_start, target_name);

WITH normalized_five_minute AS (
    SELECT
        affected.period_start,
        probe.target_name,
        date_bin(
            interval '5 minutes',
            probe.checked_at,
            timestamptz '2001-01-01 00:00:00+00'
        ) AS bucket_start,
        (array_agg(probe.db_type ORDER BY probe.checked_at DESC))[1] AS db_type,
        (array_agg(probe.environment ORDER BY probe.checked_at DESC))[1] AS environment,
        (array_agg(probe.host ORDER BY probe.checked_at DESC))[1] AS host,
        (array_agg(probe.port ORDER BY probe.checked_at DESC))[1] AS port,
        (array_agg(probe.instance ORDER BY probe.checked_at DESC))[1] AS instance,
        (array_agg(probe.criticality ORDER BY probe.checked_at DESC))[1] AS criticality,
        (array_agg(probe.team ORDER BY probe.checked_at DESC))[1] AS team,
        min(probe.is_up) AS is_up,
        CASE
            WHEN min(probe.is_up) = 1
            THEN avg(probe.latency_ms) FILTER (WHERE probe.latency_ms IS NOT NULL)
            ELSE NULL
        END AS latency_ms,
        min(probe.checked_at) AS first_probe_at,
        max(probe.checked_at) AS last_probe_at
    FROM affected_target_days affected
    INNER JOIN :"schema_name".db_port_blackbox_probe_results probe
        ON probe.target_name = affected.target_name
       AND probe.checked_at >= affected.period_start::timestamptz
       AND probe.checked_at < (affected.period_start + 1)::timestamptz
    GROUP BY
        affected.period_start,
        probe.target_name,
        date_bin(
            interval '5 minutes',
            probe.checked_at,
            timestamptz '2001-01-01 00:00:00+00'
        )
),
daily AS (
    SELECT
        period_start,
        target_name,
        (array_agg(db_type ORDER BY last_probe_at DESC))[1] AS db_type,
        (array_agg(environment ORDER BY last_probe_at DESC))[1] AS environment,
        (array_agg(host ORDER BY last_probe_at DESC))[1] AS host,
        (array_agg(port ORDER BY last_probe_at DESC))[1] AS port,
        (array_agg(instance ORDER BY last_probe_at DESC))[1] AS instance,
        (array_agg(criticality ORDER BY last_probe_at DESC))[1] AS criticality,
        (array_agg(team ORDER BY last_probe_at DESC))[1] AS team,
        count(*)::bigint AS probes,
        count(*) FILTER (WHERE is_up = 1)::bigint AS up_probes,
        count(*) FILTER (WHERE is_up = 0)::bigint AS down_probes,
        count(*) FILTER (WHERE is_up = 1 AND latency_ms > 3000)::bigint AS slow_probes,
        coalesce(sum(latency_ms) FILTER (WHERE is_up = 1 AND latency_ms IS NOT NULL), 0) AS latency_ms_sum,
        count(latency_ms) FILTER (WHERE is_up = 1)::bigint AS latency_ms_count,
        max(latency_ms) FILTER (WHERE is_up = 1) AS max_latency_ms,
        min(first_probe_at) AS first_probe_at,
        max(last_probe_at) AS last_probe_at
    FROM normalized_five_minute
    GROUP BY period_start, target_name
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
    probes = EXCLUDED.probes,
    up_probes = EXCLUDED.up_probes,
    down_probes = EXCLUDED.down_probes,
    slow_probes = EXCLUDED.slow_probes,
    latency_ms_sum = EXCLUDED.latency_ms_sum,
    latency_ms_count = EXCLUDED.latency_ms_count,
    max_latency_ms = EXCLUDED.max_latency_ms,
    first_probe_at = EXCLUDED.first_probe_at,
    last_probe_at = EXCLUDED.last_probe_at,
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
