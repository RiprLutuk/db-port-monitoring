/*
Fill historical daily-KPI outage gaps when raw probe timestamps are no longer
retained.

Policy approved for this one-time backfill:
  - only daily rows with down_probes > 0 and no overlapping event are eligible;
  - the estimated outage starts at 00:00 Asia/Jakarta;
  - duration remains down_probes * 5 minutes and must fit within 00:00-03:00;
  - existing observed or exact events are never replaced;
  - source is explicit so Grafana never presents the timestamp as observed.

This does not change daily KPI counters or create synthetic raw probe rows.
*/

\if :{?schema_name}
\else
\set schema_name monitoring
\endif

\if :{?estimated_from_inclusive}
\else
\set estimated_from_inclusive '2026-07-06'
\endif

\if :{?estimated_to_exclusive}
\else
\set estimated_to_exclusive '2026-07-21'
\endif

BEGIN;

SET LOCAL search_path TO pg_temp, :"schema_name";

CREATE TEMP TABLE estimated_downtime_candidates ON COMMIT DROP AS
WITH daily_down AS (
    SELECT
        d.*,
        d.period_start::timestamp AT TIME ZONE 'Asia/Jakarta' AS day_start,
        (d.period_start + 1)::timestamp AT TIME ZONE 'Asia/Jakarta' AS day_end
    FROM :"schema_name".db_port_blackbox_daily_kpi AS d
    WHERE d.period_start >= :'estimated_from_inclusive'::date
      AND d.period_start < :'estimated_to_exclusive'::date
      AND d.down_probes > 0
)
SELECT
    d.target_name,
    d.day_start AS down_start,
    d.day_start + make_interval(mins => (d.down_probes * 5)::int) AS down_end,
    d.db_type,
    d.environment,
    d.host,
    d.port,
    d.instance,
    d.criticality,
    d.team,
    d.down_probes AS down_samples
FROM daily_down AS d
WHERE NOT EXISTS (
    SELECT 1
    FROM :"schema_name".db_port_blackbox_downtime_events AS event
    WHERE event.target_name = d.target_name
      AND event.source <> 'daily-kpi-estimated-00-03'
      AND event.down_start < d.day_end
      AND coalesce(
            event.down_end,
            least(now(), event.last_down_at + interval '5 minutes')
          ) > d.day_start
);

DO $validation$
BEGIN
    IF EXISTS (
        SELECT 1
        FROM estimated_downtime_candidates
        WHERE down_samples > 36
           OR down_end > down_start + interval '3 hours'
    ) THEN
        RAISE EXCEPTION 'Estimated outage exceeds the approved 00:00-03:00 window';
    END IF;

    IF EXISTS (
        SELECT 1
        FROM estimated_downtime_candidates
        WHERE port NOT BETWEEN 1 AND 65535
           OR down_samples <= 0
           OR down_end <= down_start
    ) THEN
        RAISE EXCEPTION 'Estimated outage candidate contains invalid dimensions or duration';
    END IF;

    IF EXISTS (
        SELECT 1
        FROM estimated_downtime_candidates
        GROUP BY target_name, down_start
        HAVING count(*) > 1
    ) THEN
        RAISE EXCEPTION 'Estimated outage candidate contains duplicate target/day rows';
    END IF;

    IF EXISTS (
        SELECT 1
        FROM estimated_downtime_candidates AS candidate
        INNER JOIN db_port_blackbox_downtime_events AS event
            ON event.target_name = candidate.target_name
           AND event.source <> 'daily-kpi-estimated-00-03'
           AND event.down_start < candidate.down_end
           AND coalesce(
                event.down_end,
                least(now(), event.last_down_at + interval '5 minutes')
           ) > candidate.down_start
    ) THEN
        RAISE EXCEPTION 'Estimated outage candidate overlaps an observed or exact event';
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
    started_before_retention
)
SELECT
    candidate.target_name,
    candidate.down_start,
    candidate.down_end,
    greatest(candidate.down_start, candidate.down_end - interval '5 minutes'),
    candidate.db_type,
    candidate.environment,
    candidate.host,
    candidate.port,
    candidate.instance,
    candidate.criticality,
    candidate.team,
    candidate.down_samples,
    'Estimated from daily KPI; assumed start 00:00 Asia/Jakarta',
    'Estimated duration: ' || (candidate.down_samples * 5)::text || ' minutes',
    NULL,
    'daily-kpi-estimated-00-03',
    false
FROM estimated_downtime_candidates AS candidate
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
    updated_at = now()
WHERE event.source = 'daily-kpi-estimated-00-03';

DO $coverage_validation$
BEGIN
    IF EXISTS (
        SELECT 1
        FROM db_port_blackbox_daily_kpi AS daily
        WHERE daily.down_probes > 0
          AND NOT EXISTS (
              SELECT 1
              FROM db_port_blackbox_downtime_events AS event
              WHERE event.target_name = daily.target_name
                AND event.down_start
                    < (daily.period_start + 1)::timestamp AT TIME ZONE 'Asia/Jakarta'
                AND coalesce(
                    event.down_end,
                    least(now(), event.last_down_at + interval '5 minutes')
                ) > daily.period_start::timestamp AT TIME ZONE 'Asia/Jakarta'
          )
    ) THEN
        RAISE EXCEPTION 'Daily KPI still contains DOWN target-days without a downtime event';
    END IF;
END
$coverage_validation$;

SELECT
    count(*)::bigint AS estimated_events,
    count(DISTINCT target_name)::bigint AS affected_targets,
    min(down_start) AS first_estimated_start,
    max(down_end) AS last_estimated_end,
    sum(down_samples)::bigint AS represented_down_samples,
    sum(down_samples * 5)::bigint AS represented_down_minutes
FROM estimated_downtime_candidates;

COMMIT;
