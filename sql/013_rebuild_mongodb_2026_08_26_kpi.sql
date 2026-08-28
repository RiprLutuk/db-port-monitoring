BEGIN;

\if :{?schema_name}
\else
\set schema_name monitoring
\endif

SET LOCAL search_path TO pg_temp, :"schema_name";

-- The MongoDB endpoint moved during this day. Both scrape phases are retained
-- in raw history, so rebuild the KPI as one conservative sample per 5-minute
-- bucket instead of counting 289 physical rows.
CREATE TEMP TABLE normalized_five_minute ON COMMIT DROP AS
SELECT
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
FROM :"schema_name".db_port_blackbox_probe_results probe
WHERE probe.target_name = 'mongodb'
  AND probe.checked_at >= timestamptz '2026-08-26 00:00:00+07'
  AND probe.checked_at < timestamptz '2026-08-27 00:00:00+07'
GROUP BY date_bin(
    interval '5 minutes',
    probe.checked_at,
    timestamptz '2001-01-01 00:00:00+00'
);

DO $guard$
DECLARE
    bucket_count bigint;
    state_count bigint;
BEGIN
    SELECT
        count(*),
        count(*) FILTER (WHERE is_up IN (0, 1))
    INTO bucket_count, state_count
    FROM normalized_five_minute;

    IF bucket_count <> 288 OR state_count <> bucket_count THEN
        RAISE EXCEPTION
            'Expected 288 valid MongoDB buckets for 2026-08-26, found %',
            bucket_count;
    END IF;
END
$guard$;

WITH daily AS (
    SELECT
        date '2026-08-26' AS period_start,
        'mongodb'::text AS target_name,
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
        coalesce(sum(latency_ms) FILTER (WHERE is_up = 1), 0) AS latency_ms_sum,
        count(latency_ms) FILTER (WHERE is_up = 1)::bigint AS latency_ms_count,
        max(latency_ms) FILTER (WHERE is_up = 1) AS max_latency_ms,
        min(first_probe_at) AS first_probe_at,
        max(last_probe_at) AS last_probe_at
    FROM normalized_five_minute
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

DO $verify$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM db_port_blackbox_daily_kpi
        WHERE period_start = date '2026-08-26'
          AND target_name = 'mongodb'
          AND probes = 288
          AND probes = up_probes + down_probes
    ) THEN
        RAISE EXCEPTION 'MongoDB daily KPI verification failed';
    END IF;
END
$verify$;

COMMIT;
