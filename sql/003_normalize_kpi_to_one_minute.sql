BEGIN;

\if :{?schema_name}
\else
\set schema_name monitoring
\endif

SET LOCAL search_path TO pg_temp, :"schema_name";

DO $guard$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM db_port_blackbox_probe_results) THEN
        RAISE EXCEPTION 'Cannot normalize KPI because raw probe data is empty';
    END IF;
END
$guard$;

LOCK TABLE
    db_port_blackbox_hourly_kpi,
    db_port_blackbox_daily_kpi,
    db_port_blackbox_daily_error_summary
IN ACCESS EXCLUSIVE MODE;

CREATE TABLE IF NOT EXISTS :"schema_name".db_port_blackbox_hourly_kpi_pre_1m
AS TABLE :"schema_name".db_port_blackbox_hourly_kpi;

CREATE TABLE IF NOT EXISTS :"schema_name".db_port_blackbox_daily_kpi_pre_1m
AS TABLE :"schema_name".db_port_blackbox_daily_kpi;

CREATE TABLE IF NOT EXISTS :"schema_name".db_port_blackbox_daily_error_summary_pre_1m
AS TABLE :"schema_name".db_port_blackbox_daily_error_summary;

CREATE TEMP TABLE normalized_minute_samples ON COMMIT DROP AS
SELECT
    date_trunc('minute', checked_at) AS period_minute,
    target_name,
    max(db_type) AS db_type,
    max(environment) AS environment,
    max(host) AS host,
    max(port) AS port,
    max(instance) AS instance,
    max(criticality) AS criticality,
    max(team) AS team,
    min(is_up) AS is_up,
    CASE
        WHEN min(is_up) = 1
        THEN avg(latency_ms) FILTER (WHERE is_up = 1 AND latency_ms IS NOT NULL)
        ELSE NULL
    END AS latency_ms,
    CASE
        WHEN min(is_up) = 1
        THEN max(latency_ms) FILTER (WHERE is_up = 1 AND latency_ms IS NOT NULL)
        ELSE NULL
    END AS max_latency_ms,
    CASE
        WHEN min(is_up) = 1
        THEN bool_or(latency_ms > 3000) FILTER (WHERE is_up = 1 AND latency_ms IS NOT NULL)
        ELSE false
    END AS is_slow,
    coalesce(
        (array_remove(array_agg(error_text ORDER BY checked_at)
            FILTER (WHERE is_up = 0), NULL))[1],
        'blackbox probe failed'
    ) AS error_text,
    min(checked_at) AS first_probe_at,
    max(checked_at) AS last_probe_at,
    min(checked_at) FILTER (WHERE is_up = 0) AS first_down_at,
    max(checked_at) FILTER (WHERE is_up = 0) AS last_down_at
FROM db_port_blackbox_probe_results
GROUP BY date_trunc('minute', checked_at), target_name;

ANALYZE normalized_minute_samples;

DELETE FROM db_port_blackbox_hourly_kpi
WHERE period_hour >= (
    SELECT date_trunc('hour', min(period_minute))
    FROM normalized_minute_samples
);

DELETE FROM db_port_blackbox_daily_kpi
WHERE period_start >= (
    SELECT min(period_minute)::date
    FROM normalized_minute_samples
);

DELETE FROM db_port_blackbox_daily_error_summary
WHERE period_start >= (
    SELECT min(period_minute)::date
    FROM normalized_minute_samples
);

INSERT INTO db_port_blackbox_hourly_kpi (
    period_hour,
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
    date_trunc('hour', period_minute),
    target_name,
    max(db_type),
    max(environment),
    max(host),
    max(port),
    max(instance),
    max(criticality),
    max(team),
    count(*)::bigint,
    count(*) FILTER (WHERE is_up = 1)::bigint,
    count(*) FILTER (WHERE is_up = 0)::bigint,
    count(*) FILTER (WHERE is_slow)::bigint,
    coalesce(sum(latency_ms) FILTER (WHERE is_up = 1 AND latency_ms IS NOT NULL), 0),
    count(latency_ms) FILTER (WHERE is_up = 1)::bigint,
    max(max_latency_ms) FILTER (WHERE is_up = 1),
    min(first_probe_at),
    max(last_probe_at)
FROM normalized_minute_samples
GROUP BY date_trunc('hour', period_minute), target_name;

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
    period_minute::date,
    target_name,
    max(db_type),
    max(environment),
    max(host),
    max(port),
    max(instance),
    max(criticality),
    max(team),
    count(*)::bigint,
    count(*) FILTER (WHERE is_up = 1)::bigint,
    count(*) FILTER (WHERE is_up = 0)::bigint,
    count(*) FILTER (WHERE is_slow)::bigint,
    coalesce(sum(latency_ms) FILTER (WHERE is_up = 1 AND latency_ms IS NOT NULL), 0),
    count(latency_ms) FILTER (WHERE is_up = 1)::bigint,
    max(max_latency_ms) FILTER (WHERE is_up = 1),
    min(first_probe_at),
    max(last_probe_at)
FROM normalized_minute_samples
GROUP BY period_minute::date, target_name;

INSERT INTO db_port_blackbox_daily_error_summary (
    period_start,
    target_name,
    db_type,
    environment,
    host,
    port,
    instance,
    criticality,
    team,
    error_text,
    error_count,
    first_seen_at,
    last_seen_at
)
SELECT
    period_minute::date,
    target_name,
    max(db_type),
    max(environment),
    max(host),
    max(port),
    max(instance),
    max(criticality),
    max(team),
    error_text,
    count(*)::bigint,
    min(first_down_at),
    max(last_down_at)
FROM normalized_minute_samples
WHERE is_up = 0
GROUP BY period_minute::date, target_name, error_text;

SELECT
    (SELECT count(*) FROM normalized_minute_samples) AS normalized_minute_samples,
    (SELECT count(*) FROM db_port_blackbox_hourly_kpi) AS hourly_kpi_rows,
    (SELECT count(*) FROM db_port_blackbox_daily_kpi) AS daily_kpi_rows,
    (SELECT count(*) FROM db_port_blackbox_daily_error_summary) AS daily_error_rows;

COMMIT;
