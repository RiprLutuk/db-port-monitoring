BEGIN;

\if :{?schema_name}
\else
\set schema_name monitoring
\endif

SET LOCAL search_path TO pg_temp, :"schema_name";

DO $guard$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM db_port_blackbox_probe_results) THEN
        RAISE EXCEPTION 'Cannot normalize history because raw probe data is empty';
    END IF;
END
$guard$;

LOCK TABLE
    db_port_blackbox_probe_results,
    db_port_blackbox_daily_kpi
IN ACCESS EXCLUSIVE MODE;

CREATE TEMP TABLE normalization_stats ON COMMIT DROP AS
SELECT
    count(*)::bigint AS raw_rows_before,
    min(checked_at) AS oldest_probe_at,
    max(checked_at) AS newest_probe_at
FROM db_port_blackbox_probe_results;

-- Keep one conservative observation per target per five-minute bucket. A bucket is
-- DOWN when any source observation in that bucket is DOWN, matching the previous
-- minute-normalization rule while removing cadence-dependent KPI weighting.
CREATE TEMP TABLE normalized_five_minute_samples ON COMMIT DROP AS
SELECT
    max(checked_at) AS checked_at,
    target_name,
    (array_agg(db_type ORDER BY checked_at DESC))[1] AS db_type,
    (array_agg(environment ORDER BY checked_at DESC))[1] AS environment,
    (array_agg(host ORDER BY checked_at DESC))[1] AS host,
    (array_agg(port ORDER BY checked_at DESC))[1] AS port,
    (array_agg(instance ORDER BY checked_at DESC))[1] AS instance,
    (array_agg(criticality ORDER BY checked_at DESC))[1] AS criticality,
    (array_agg(team ORDER BY checked_at DESC))[1] AS team,
    min(is_up) AS is_up,
    CASE
        WHEN min(is_up) = 1
        THEN avg(latency_ms) FILTER (WHERE latency_ms IS NOT NULL)
        ELSE NULL
    END AS latency_ms,
    CASE
        WHEN min(is_up) = 0
        THEN coalesce(
            (array_remove(
                array_agg(error_text ORDER BY checked_at) FILTER (WHERE is_up = 0),
                NULL
            ))[1],
            'blackbox probe failed'
        )
        ELSE NULL
    END AS error_text,
    (array_agg(source ORDER BY checked_at DESC))[1] AS source,
    max(created_at) AS created_at
FROM db_port_blackbox_probe_results
GROUP BY
    target_name,
    date_bin(
        interval '5 minutes',
        checked_at,
        timestamptz '2001-01-01 00:00:00+00'
    );

ANALYZE normalized_five_minute_samples;

TRUNCATE TABLE db_port_blackbox_probe_results RESTART IDENTITY;

INSERT INTO db_port_blackbox_probe_results (
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
    error_text,
    source,
    created_at
)
SELECT
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
    error_text,
    source,
    created_at
FROM normalized_five_minute_samples
ORDER BY checked_at, target_name;

-- Preserve daily KPI older than raw retention and rebuild every date represented by
-- normalized raw data.
DELETE FROM db_port_blackbox_daily_kpi
WHERE period_start >= (
    SELECT min(checked_at)::date
    FROM normalized_five_minute_samples
);

INSERT INTO db_port_blackbox_daily_kpi (
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
    checked_at::date AS period_start,
    target_name,
    max(db_type),
    max(environment),
    max(host),
    max(port),
    max(instance),
    max(criticality),
    max(team),
    count(*)::bigint AS probes,
    count(*) FILTER (WHERE is_up = 1)::bigint AS up_probes,
    count(*) FILTER (WHERE is_up = 0)::bigint AS down_probes,
    count(*) FILTER (WHERE is_up = 1 AND latency_ms > 3000)::bigint AS slow_probes,
    coalesce(
        sum(latency_ms) FILTER (WHERE is_up = 1 AND latency_ms IS NOT NULL),
        0
    ) AS latency_ms_sum,
    count(latency_ms) FILTER (WHERE is_up = 1)::bigint AS latency_ms_count,
    max(latency_ms) FILTER (WHERE is_up = 1) AS max_latency_ms,
    min(checked_at) AS first_probe_at,
    max(checked_at) AS last_probe_at
FROM normalized_five_minute_samples
GROUP BY checked_at::date, target_name;

ANALYZE db_port_blackbox_probe_results;
ANALYZE db_port_blackbox_daily_kpi;

SELECT
    stats.raw_rows_before,
    count(*)::bigint AS raw_rows_after,
    stats.raw_rows_before - count(*)::bigint AS raw_rows_removed,
    min(samples.checked_at) AS oldest_probe_at,
    max(samples.checked_at) AS newest_probe_at
FROM normalized_five_minute_samples samples
CROSS JOIN normalization_stats stats
GROUP BY stats.raw_rows_before;

COMMIT;
