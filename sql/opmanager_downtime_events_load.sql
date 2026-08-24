/*
Idempotent PostgreSQL loader for exact OpManager downtime events.

Input:
  UTF-8 CSV with a header, exported from
  sql/opmanager_downtime_events_extract.sql.

Prerequisite:
  sql/008_outage_events.sql has created
  monitoring.db_port_blackbox_downtime_events.

Safety:
  - accepts only the configured historical range and OpManager exact sources;
  - rejects duplicate, invalid, or overlapping staged events;
  - rejects overlap with existing Prometheus events;
  - updates only an existing OpManager row with the same primary key;
  - does not delete stale rows and does not create raw probe history.

Replace __STAGE_FILE__ with the exported CSV path before running with psql.
*/

\if :{?schema_name}
\else
\set schema_name monitoring
\endif

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

CREATE TEMP TABLE opmanager_downtime_event_stage (
    target_name text NOT NULL,
    down_start timestamptz NOT NULL,
    down_end timestamptz NOT NULL,
    last_down_at timestamptz NOT NULL,
    db_type text NOT NULL,
    environment text NOT NULL,
    host text NOT NULL,
    port int NOT NULL,
    instance text NOT NULL,
    criticality text NULL,
    team text NULL,
    down_samples bigint NOT NULL,
    first_error_text text NULL,
    last_error_text text NULL,
    max_latency_ms numeric NOT NULL,
    source text NOT NULL,
    started_before_retention boolean NOT NULL,
    created_at timestamptz NOT NULL,
    updated_at timestamptz NOT NULL
);

CREATE TEMP TABLE opmanager_event_backfill_bounds AS
SELECT
    (:'backfill_from_inclusive'::date::timestamp AT TIME ZONE 'Asia/Jakarta') AS from_at,
    (:'backfill_to_exclusive'::date::timestamp AT TIME ZONE 'Asia/Jakarta') AS to_at;

\copy opmanager_downtime_event_stage (target_name, down_start, down_end, last_down_at, db_type, environment, host, port, instance, criticality, team, down_samples, first_error_text, last_error_text, max_latency_ms, source, started_before_retention, created_at, updated_at) FROM '__STAGE_FILE__' WITH (FORMAT csv, HEADER true, NULL '')

DO $validation$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM opmanager_downtime_event_stage) THEN
        RAISE EXCEPTION 'OpManager downtime-event stage file contains no rows';
    END IF;

    IF EXISTS (
        SELECT 1
        FROM opmanager_downtime_event_stage AS stage
        CROSS JOIN opmanager_event_backfill_bounds AS bounds
        WHERE stage.down_start < bounds.from_at
           OR stage.down_end > bounds.to_at
    ) THEN
        RAISE EXCEPTION 'OpManager event stage contains rows outside the configured range';
    END IF;

    IF EXISTS (
        SELECT 1
        FROM opmanager_downtime_event_stage
        GROUP BY target_name, down_start
        HAVING count(*) > 1
    ) THEN
        RAISE EXCEPTION 'OpManager event stage contains duplicate (target_name, down_start) rows';
    END IF;

    IF EXISTS (
        SELECT 1
        FROM opmanager_downtime_event_stage
        WHERE btrim(target_name) = ''
           OR btrim(db_type) = ''
           OR btrim(environment) = ''
           OR btrim(host) = ''
           OR btrim(instance) = ''
           OR port NOT BETWEEN 1 AND 65535
           OR down_end <= down_start
           OR last_down_at < down_start
           OR last_down_at >= down_end
           OR down_samples <= 0
           OR btrim(coalesce(first_error_text, '')) = ''
           OR btrim(coalesce(last_error_text, '')) = ''
           OR max_latency_ms < 0
           OR source NOT IN ('opmanager-exact', 'opmanager-exact-clipped')
           OR (source = 'opmanager-exact' AND started_before_retention)
    ) THEN
        RAISE EXCEPTION 'OpManager event stage contains invalid dimensions, timestamps, counters, or source labels';
    END IF;

    IF EXISTS (
        SELECT 1
        FROM opmanager_downtime_event_stage
        GROUP BY target_name
        HAVING count(DISTINCT db_type) > 1
            OR count(DISTINCT environment) > 1
            OR count(DISTINCT host) > 1
            OR count(DISTINCT port) > 1
            OR count(DISTINCT instance) > 1
    ) THEN
        RAISE EXCEPTION 'OpManager event stage contains inconsistent target dimensions';
    END IF;

    IF EXISTS (
        SELECT 1
        FROM (
            SELECT
                stage.*,
                max(stage.down_end) OVER (
                    PARTITION BY stage.target_name
                    ORDER BY stage.down_start, stage.down_end
                    ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING
                ) AS prior_max_end
            FROM opmanager_downtime_event_stage AS stage
        ) AS ordered
        WHERE ordered.down_start < ordered.prior_max_end
    ) THEN
        RAISE EXCEPTION 'OpManager event stage contains overlapping events for one target';
    END IF;

    IF EXISTS (
        SELECT 1
        FROM opmanager_downtime_event_stage AS stage
        INNER JOIN db_port_blackbox_downtime_events AS existing
            ON existing.target_name = stage.target_name
           AND existing.down_start < stage.down_end
           AND coalesce(
                existing.down_end,
                least(now(), existing.last_down_at + interval '5 minutes')
           ) > stage.down_start
           AND NOT (
                existing.down_start = stage.down_start
                AND existing.source IN ('opmanager-exact', 'opmanager-exact-clipped')
           )
    ) THEN
        RAISE EXCEPTION 'OpManager event stage overlaps an existing event; reconcile the source boundary before loading';
    END IF;
END
$validation$;

INSERT INTO :"schema_name".db_port_blackbox_downtime_events AS event (
    target_name,
    down_start,
    down_end,
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
    max_latency_ms,
    source,
    started_before_retention,
    created_at,
    updated_at
)
SELECT
    stage.target_name,
    stage.down_start,
    stage.down_end,
    stage.last_down_at,
    stage.db_type,
    stage.environment,
    stage.host,
    stage.port,
    stage.instance,
    stage.criticality,
    stage.team,
    stage.down_samples,
    stage.first_error_text,
    stage.last_error_text,
    stage.max_latency_ms,
    stage.source,
    stage.started_before_retention,
    stage.created_at,
    stage.updated_at
FROM opmanager_downtime_event_stage AS stage
ON CONFLICT (target_name, down_start) DO UPDATE SET
    down_end = EXCLUDED.down_end,
    last_down_at = EXCLUDED.last_down_at,
    db_type = EXCLUDED.db_type,
    environment = EXCLUDED.environment,
    host = EXCLUDED.host,
    port = EXCLUDED.port,
    instance = EXCLUDED.instance,
    criticality = EXCLUDED.criticality,
    team = EXCLUDED.team,
    down_samples = EXCLUDED.down_samples,
    first_error_text = EXCLUDED.first_error_text,
    last_error_text = EXCLUDED.last_error_text,
    max_latency_ms = EXCLUDED.max_latency_ms,
    source = EXCLUDED.source,
    started_before_retention = EXCLUDED.started_before_retention,
    updated_at = EXCLUDED.updated_at
WHERE event.source IN ('opmanager-exact', 'opmanager-exact-clipped');

SELECT
    count(*)::bigint AS loaded_events,
    count(DISTINCT target_name)::bigint AS loaded_targets,
    min(down_start) AS first_down_start,
    max(down_end) AS last_down_end,
    round(sum(extract(epoch FROM down_end - down_start))::numeric, 3) AS exact_downtime_seconds,
    sum(down_samples)::bigint AS equivalent_five_minute_down_samples,
    count(*) FILTER (WHERE source = 'opmanager-exact-clipped')::bigint AS boundary_clipped_events
FROM opmanager_downtime_event_stage;

COMMIT;
