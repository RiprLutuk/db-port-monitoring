\if :{?schema_name}
\else
\set schema_name monitoring
\endif

\if :{?raw_retention_days}
\else
\set raw_retention_days 30
\endif

\if :{?kpi_retention_days}
\else
\set kpi_retention_days 400
\endif

\if :{?target_inactive_after_seconds}
\else
\set target_inactive_after_seconds 86400
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
    is_up int NOT NULL,
    latency_ms numeric NULL,
    error_text text NULL
);

\copy blackbox_probe_stage (checked_at_ms, target_name, db_type, environment, host, port, instance, criticality, team, is_up, latency_ms, error_text) FROM '__STAGE_FILE__' WITH (FORMAT csv, DELIMITER E'\t', NULL '\N')

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
    to_timestamp(checked_at_ms::numeric / 1000.0) AS checked_at
FROM blackbox_probe_stage
ORDER BY target_name, checked_at_ms DESC;

INSERT INTO :"schema_name".db_port_blackbox_targets AS target_inventory (
    target_name,
    db_type,
    environment,
    host,
    port,
    instance,
    criticality,
    team,
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
        coalesce(sum(latency_ms) FILTER (WHERE is_up = 1 AND latency_ms IS NOT NULL), 0) AS latency_ms_sum,
        count(latency_ms) FILTER (WHERE is_up = 1)::bigint AS latency_ms_count,
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
    latency_ms_sum,
    latency_ms_count,
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
    latency_ms_sum,
    latency_ms_count,
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
    latency_ms_sum = kpi.latency_ms_sum + EXCLUDED.latency_ms_sum,
    latency_ms_count = kpi.latency_ms_count + EXCLUDED.latency_ms_count,
    first_probe_at = least(coalesce(kpi.first_probe_at, EXCLUDED.first_probe_at), EXCLUDED.first_probe_at),
    last_probe_at = greatest(coalesce(kpi.last_probe_at, EXCLUDED.last_probe_at), EXCLUDED.last_probe_at),
    updated_at = now();

WITH hourly AS (
    SELECT
        date_trunc('hour', checked_at) AS period_hour,
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
    GROUP BY date_trunc('hour', checked_at), target_name
)
INSERT INTO :"schema_name".db_port_blackbox_hourly_kpi AS kpi (
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
FROM hourly
ON CONFLICT (period_hour, target_name) DO UPDATE SET
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
    max_latency_ms = greatest(coalesce(kpi.max_latency_ms, EXCLUDED.max_latency_ms), EXCLUDED.max_latency_ms),
    first_probe_at = least(coalesce(kpi.first_probe_at, EXCLUDED.first_probe_at), EXCLUDED.first_probe_at),
    last_probe_at = greatest(coalesce(kpi.last_probe_at, EXCLUDED.last_probe_at), EXCLUDED.last_probe_at),
    updated_at = now();

DO $events$
DECLARE
    sample record;
    previous_status int;
BEGIN
    FOR sample IN
        SELECT *
        FROM inserted_probe_rows
        ORDER BY checked_at, target_name
    LOOP
        previous_status := NULL;
        SELECT r.is_up
        INTO previous_status
        FROM db_port_blackbox_probe_results r
        WHERE r.target_name = sample.target_name
          AND r.checked_at < sample.checked_at
        ORDER BY r.checked_at DESC
        LIMIT 1;

        IF previous_status IS DISTINCT FROM sample.is_up THEN
            INSERT INTO db_port_blackbox_status_events (
                event_at,
                target_name,
                db_type,
                environment,
                host,
                port,
                instance,
                criticality,
                team,
                previous_is_up,
                current_is_up,
                latency_ms,
                error_text
            ) VALUES (
                sample.checked_at,
                sample.target_name,
                sample.db_type,
                sample.environment,
                sample.host,
                sample.port,
                sample.instance,
                sample.criticality,
                sample.team,
                previous_status,
                sample.is_up,
                sample.latency_ms,
                sample.error_text
            )
            ON CONFLICT (target_name, event_at) DO NOTHING;
        END IF;

        IF sample.is_up = 0 THEN
            UPDATE db_port_blackbox_downtime_events AS event
            SET
                last_down_at = greatest(event.last_down_at, sample.checked_at),
                db_type = sample.db_type,
                environment = sample.environment,
                host = sample.host,
                port = sample.port,
                instance = sample.instance,
                criticality = sample.criticality,
                team = sample.team,
                down_samples = event.down_samples + CASE WHEN sample.checked_at > event.last_down_at THEN 1 ELSE 0 END,
                last_error_text = coalesce(sample.error_text, event.last_error_text),
                max_latency_ms = CASE
                    WHEN sample.latency_ms IS NULL THEN event.max_latency_ms
                    WHEN event.max_latency_ms IS NULL THEN sample.latency_ms
                    ELSE greatest(event.max_latency_ms, sample.latency_ms)
                END,
                updated_at = now()
            WHERE event.target_name = sample.target_name
              AND event.down_end IS NULL;

            IF NOT FOUND THEN
                INSERT INTO db_port_blackbox_downtime_events (
                    target_name,
                    down_start,
                    last_down_at,
                    db_type,
                    environment,
                    host,
                    port,
                    instance,
                    criticality,
                    team,
                    down_samples,
                    first_error_text,
                    last_error_text,
                    max_latency_ms
                ) VALUES (
                    sample.target_name,
                    sample.checked_at,
                    sample.checked_at,
                    sample.db_type,
                    sample.environment,
                    sample.host,
                    sample.port,
                    sample.instance,
                    sample.criticality,
                    sample.team,
                    1,
                    sample.error_text,
                    sample.error_text,
                    sample.latency_ms
                )
                ON CONFLICT (target_name, down_start) DO NOTHING;
            END IF;
        ELSE
            UPDATE db_port_blackbox_downtime_events AS event
            SET
                down_end = sample.checked_at,
                updated_at = now()
            WHERE event.target_name = sample.target_name
              AND event.down_end IS NULL
              AND sample.checked_at >= event.down_start;
        END IF;

        IF sample.is_up = 1 AND sample.latency_ms > 3000 THEN
            UPDATE db_port_blackbox_latency_events AS event
            SET
                last_slow_at = greatest(event.last_slow_at, sample.checked_at),
                db_type = sample.db_type,
                environment = sample.environment,
                host = sample.host,
                port = sample.port,
                instance = sample.instance,
                criticality = sample.criticality,
                team = sample.team,
                slow_samples = event.slow_samples + CASE WHEN sample.checked_at > event.last_slow_at THEN 1 ELSE 0 END,
                latency_ms_sum = event.latency_ms_sum + CASE WHEN sample.checked_at > event.last_slow_at THEN sample.latency_ms ELSE 0 END,
                latency_ms_count = event.latency_ms_count + CASE WHEN sample.checked_at > event.last_slow_at THEN 1 ELSE 0 END,
                max_latency_ms = CASE
                    WHEN event.max_latency_ms IS NULL THEN sample.latency_ms
                    ELSE greatest(event.max_latency_ms, sample.latency_ms)
                END,
                updated_at = now()
            WHERE event.target_name = sample.target_name
              AND event.threshold_ms = 3000
              AND event.slow_end IS NULL;

            IF NOT FOUND THEN
                INSERT INTO db_port_blackbox_latency_events (
                    target_name,
                    slow_start,
                    last_slow_at,
                    threshold_ms,
                    db_type,
                    environment,
                    host,
                    port,
                    instance,
                    criticality,
                    team,
                    slow_samples,
                    latency_ms_sum,
                    latency_ms_count,
                    max_latency_ms
                ) VALUES (
                    sample.target_name,
                    sample.checked_at,
                    sample.checked_at,
                    3000,
                    sample.db_type,
                    sample.environment,
                    sample.host,
                    sample.port,
                    sample.instance,
                    sample.criticality,
                    sample.team,
                    1,
                    sample.latency_ms,
                    1,
                    sample.latency_ms
                )
                ON CONFLICT (target_name, slow_start, threshold_ms) DO NOTHING;
            END IF;
        ELSE
            UPDATE db_port_blackbox_latency_events AS event
            SET
                slow_end = sample.checked_at,
                updated_at = now()
            WHERE event.target_name = sample.target_name
              AND event.slow_end IS NULL
              AND sample.checked_at >= event.slow_start;
        END IF;
    END LOOP;
END
$events$;

WITH errors AS (
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
        coalesce(error_text, 'blackbox probe failed') AS error_text,
        count(*)::bigint AS error_count,
        min(checked_at) AS first_seen_at,
        max(checked_at) AS last_seen_at
    FROM inserted_probe_rows
    WHERE is_up = 0
    GROUP BY checked_at::date, target_name, coalesce(error_text, 'blackbox probe failed')
)
INSERT INTO :"schema_name".db_port_blackbox_daily_error_summary AS summary (
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
FROM errors
ON CONFLICT (period_start, target_name, error_text) DO UPDATE SET
    db_type = EXCLUDED.db_type,
    environment = EXCLUDED.environment,
    host = EXCLUDED.host,
    port = EXCLUDED.port,
    instance = EXCLUDED.instance,
    criticality = EXCLUDED.criticality,
    team = EXCLUDED.team,
    error_count = summary.error_count + EXCLUDED.error_count,
    first_seen_at = least(summary.first_seen_at, EXCLUDED.first_seen_at),
    last_seen_at = greatest(summary.last_seen_at, EXCLUDED.last_seen_at),
    updated_at = now();

DELETE FROM :"schema_name".db_port_blackbox_probe_results
WHERE checked_at < now() - (:'raw_retention_days' || ' days')::interval;

DELETE FROM :"schema_name".db_port_blackbox_daily_kpi
WHERE period_start < (current_date - :kpi_retention_days::int);

DELETE FROM :"schema_name".db_port_blackbox_hourly_kpi
WHERE period_hour < now() - (:'kpi_retention_days' || ' days')::interval;

DELETE FROM :"schema_name".db_port_blackbox_status_events
WHERE event_at < now() - (:'kpi_retention_days' || ' days')::interval;

DELETE FROM :"schema_name".db_port_blackbox_downtime_events
WHERE down_start < now() - (:'kpi_retention_days' || ' days')::interval;

DELETE FROM :"schema_name".db_port_blackbox_latency_events
WHERE slow_start < now() - (:'kpi_retention_days' || ' days')::interval;

DELETE FROM :"schema_name".db_port_blackbox_daily_error_summary
WHERE period_start < (current_date - :kpi_retention_days::int);

SELECT count(*)::bigint AS inserted_probe_rows
FROM inserted_probe_rows;

COMMIT;
