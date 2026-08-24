\if :{?schema_name}
\else
\set schema_name monitoring
\endif

BEGIN;

SET LOCAL search_path TO pg_temp, :"schema_name";

CREATE TABLE IF NOT EXISTS :"schema_name".db_port_blackbox_downtime_events (
    target_name text NOT NULL,
    down_start timestamptz NOT NULL,
    down_end timestamptz NULL,
    last_down_at timestamptz NOT NULL,
    db_type text NOT NULL,
    environment text NOT NULL,
    host text NOT NULL,
    port int NOT NULL CHECK (port BETWEEN 1 AND 65535),
    instance text NOT NULL,
    criticality text NULL,
    team text NULL,
    down_samples bigint NOT NULL DEFAULT 1 CHECK (down_samples > 0),
    first_error_text text NULL,
    last_error_text text NULL,
    max_latency_ms numeric NULL CHECK (max_latency_ms IS NULL OR max_latency_ms >= 0),
    source text NOT NULL DEFAULT 'prometheus-blackbox',
    started_before_retention boolean NOT NULL DEFAULT false,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (target_name, down_start),
    CHECK (last_down_at >= down_start),
    CHECK (down_end IS NULL OR down_end > last_down_at)
);

ALTER TABLE :"schema_name".db_port_blackbox_downtime_events
ADD COLUMN IF NOT EXISTS source text NOT NULL DEFAULT 'prometheus-blackbox';

ALTER TABLE :"schema_name".db_port_blackbox_downtime_events
ADD COLUMN IF NOT EXISTS started_before_retention boolean NOT NULL DEFAULT false;

CREATE INDEX IF NOT EXISTS idx_db_port_blackbox_downtime_events_start
ON :"schema_name".db_port_blackbox_downtime_events (down_start DESC);

CREATE INDEX IF NOT EXISTS idx_db_port_blackbox_downtime_events_target_start
ON :"schema_name".db_port_blackbox_downtime_events (target_name, down_start DESC);

CREATE UNIQUE INDEX IF NOT EXISTS uq_db_port_blackbox_downtime_events_one_open
ON :"schema_name".db_port_blackbox_downtime_events (target_name)
WHERE down_end IS NULL;

COMMENT ON TABLE :"schema_name".db_port_blackbox_downtime_events IS
'One row per contiguous DOWN run. Times are bounded by five-minute probe observations.';

COMMENT ON COLUMN :"schema_name".db_port_blackbox_downtime_events.started_before_retention IS
'True when the first retained sample was already DOWN, so the real outage may have started earlier.';

CREATE OR REPLACE FUNCTION :"schema_name".record_db_port_blackbox_outage_sample(
    p_target_name text,
    p_checked_at timestamptz
)
RETURNS void
LANGUAGE plpgsql
VOLATILE
SET search_path = :"schema_name", pg_catalog
AS $function$
DECLARE
    sample record;
    next_observation record;
BEGIN
    SELECT
        r.checked_at,
        r.target_name,
        r.db_type,
        r.environment,
        r.host,
        r.port,
        r.instance,
        r.criticality,
        r.team,
        r.is_up,
        r.latency_ms,
        r.error_text,
        r.source
    INTO sample
    FROM db_port_blackbox_probe_results r
    WHERE r.target_name = p_target_name
      AND r.checked_at = p_checked_at;

    IF NOT FOUND THEN
        RETURN;
    END IF;

    -- Do not turn a monitoring-data gap into reported database downtime. One
    -- final five-minute bucket is observable; everything after that is unknown.
    UPDATE db_port_blackbox_downtime_events AS event
    SET
        down_end = event.last_down_at + interval '5 minutes',
        updated_at = now()
    WHERE event.target_name = sample.target_name
      AND event.down_end IS NULL
      AND sample.checked_at > event.last_down_at + interval '10 minutes';

    IF sample.is_up = 1 THEN
        UPDATE db_port_blackbox_downtime_events AS event
        SET
            down_end = sample.checked_at,
            updated_at = now()
        WHERE event.target_name = sample.target_name
          AND event.down_end IS NULL
          AND sample.checked_at > event.last_down_at;

        RETURN;
    END IF;

    UPDATE db_port_blackbox_downtime_events AS event
    SET
        last_down_at = sample.checked_at,
        db_type = sample.db_type,
        environment = sample.environment,
        host = sample.host,
        port = sample.port,
        instance = sample.instance,
        criticality = sample.criticality,
        team = sample.team,
        down_samples = event.down_samples + 1,
        last_error_text = coalesce(sample.error_text, event.last_error_text),
        max_latency_ms = CASE
            WHEN sample.latency_ms IS NULL THEN event.max_latency_ms
            WHEN event.max_latency_ms IS NULL THEN sample.latency_ms
            ELSE greatest(event.max_latency_ms, sample.latency_ms)
        END,
        updated_at = now()
    WHERE event.target_name = sample.target_name
      AND event.down_end IS NULL
      AND sample.checked_at > event.last_down_at
      AND sample.checked_at <= event.last_down_at + interval '10 minutes';

    IF FOUND THEN
        RETURN;
    END IF;

    -- A delayed sample can belong to a closed run that was already reconstructed.
    UPDATE db_port_blackbox_downtime_events AS event
    SET
        last_down_at = greatest(event.last_down_at, sample.checked_at),
        down_samples = event.down_samples + 1,
        last_error_text = coalesce(sample.error_text, event.last_error_text),
        max_latency_ms = CASE
            WHEN sample.latency_ms IS NULL THEN event.max_latency_ms
            WHEN event.max_latency_ms IS NULL THEN sample.latency_ms
            ELSE greatest(event.max_latency_ms, sample.latency_ms)
        END,
        updated_at = now()
    WHERE event.target_name = sample.target_name
      AND event.down_end IS NOT NULL
      AND sample.checked_at > event.down_start
      AND sample.checked_at < event.down_end;

    IF FOUND THEN
        RETURN;
    END IF;

    -- Extend an open run backwards when a delayed DOWN sample precedes it and no
    -- successful observation exists between the two samples.
    UPDATE db_port_blackbox_downtime_events AS event
    SET
        down_start = sample.checked_at,
        db_type = sample.db_type,
        environment = sample.environment,
        host = sample.host,
        port = sample.port,
        instance = sample.instance,
        criticality = sample.criticality,
        team = sample.team,
        down_samples = event.down_samples + 1,
        first_error_text = coalesce(sample.error_text, event.first_error_text),
        max_latency_ms = CASE
            WHEN sample.latency_ms IS NULL THEN event.max_latency_ms
            WHEN event.max_latency_ms IS NULL THEN sample.latency_ms
            ELSE greatest(event.max_latency_ms, sample.latency_ms)
        END,
        started_before_retention = event.started_before_retention OR NOT EXISTS (
            SELECT 1
            FROM db_port_blackbox_probe_results previous
            WHERE previous.target_name = sample.target_name
              AND previous.checked_at < sample.checked_at
        ),
        updated_at = now()
    WHERE event.target_name = sample.target_name
      AND event.down_end IS NULL
      AND sample.checked_at < event.down_start
      AND event.down_start <= sample.checked_at + interval '10 minutes'
      AND NOT EXISTS (
          SELECT 1
          FROM db_port_blackbox_probe_results recovered
          WHERE recovered.target_name = sample.target_name
            AND recovered.checked_at > sample.checked_at
            AND recovered.checked_at < event.down_start
            AND recovered.is_up = 1
      );

    IF FOUND THEN
        RETURN;
    END IF;

    SELECT r.checked_at, r.is_up
    INTO next_observation
    FROM db_port_blackbox_probe_results r
    WHERE r.target_name = sample.target_name
      AND r.checked_at > sample.checked_at
    ORDER BY r.checked_at
    LIMIT 1;

    INSERT INTO db_port_blackbox_downtime_events (
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
    ) VALUES (
        sample.target_name,
        sample.checked_at,
        CASE
            WHEN next_observation.checked_at IS NULL THEN NULL
            WHEN next_observation.checked_at > sample.checked_at + interval '10 minutes'
                THEN sample.checked_at + interval '5 minutes'
            WHEN next_observation.is_up = 1 THEN next_observation.checked_at
            ELSE NULL
        END,
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
        sample.latency_ms,
        sample.source,
        NOT EXISTS (
            SELECT 1
            FROM db_port_blackbox_probe_results previous
            WHERE previous.target_name = sample.target_name
              AND previous.checked_at < sample.checked_at
        )
    )
    ON CONFLICT (target_name, down_start) DO NOTHING;
END
$function$;

-- Initial one-time reconstruction from retained raw samples. Once events exist,
-- subsequent samples are maintained incrementally by the writer.
WITH ordered AS (
    SELECT
        r.*,
        lag(r.is_up) OVER (
            PARTITION BY r.target_name
            ORDER BY r.checked_at
        ) AS previous_is_up,
        lag(r.checked_at) OVER (
            PARTITION BY r.target_name
            ORDER BY r.checked_at
        ) AS previous_checked_at
    FROM :"schema_name".db_port_blackbox_probe_results r
),
grouped AS (
    SELECT
        *,
        sum(
            CASE
                WHEN previous_is_up IS DISTINCT FROM is_up THEN 1
                WHEN checked_at > previous_checked_at + interval '10 minutes' THEN 1
                ELSE 0
            END
        )
            OVER (PARTITION BY target_name ORDER BY checked_at) AS group_id
    FROM ordered
),
periods AS (
    SELECT
        target_name,
        min(checked_at) AS down_start,
        max(checked_at) AS last_down_at,
        (array_agg(db_type ORDER BY checked_at DESC))[1] AS db_type,
        (array_agg(environment ORDER BY checked_at DESC))[1] AS environment,
        (array_agg(host ORDER BY checked_at DESC))[1] AS host,
        (array_agg(port ORDER BY checked_at DESC))[1] AS port,
        (array_agg(instance ORDER BY checked_at DESC))[1] AS instance,
        (array_agg(criticality ORDER BY checked_at DESC))[1] AS criticality,
        (array_agg(team ORDER BY checked_at DESC))[1] AS team,
        count(*)::bigint AS down_samples,
        (array_remove(array_agg(error_text ORDER BY checked_at), NULL))[1] AS first_error_text,
        (array_remove(array_agg(error_text ORDER BY checked_at DESC), NULL))[1] AS last_error_text,
        max(latency_ms) AS max_latency_ms,
        (array_agg(source ORDER BY checked_at))[1] AS source,
        bool_or(previous_is_up IS NULL) AS started_before_retention
    FROM grouped
    WHERE is_up = 0
    GROUP BY target_name, group_id
),
with_recovery AS (
    SELECT
        periods.*,
        CASE
            WHEN next_sample.checked_at IS NULL THEN NULL
            WHEN next_sample.checked_at > periods.last_down_at + interval '10 minutes'
                THEN periods.last_down_at + interval '5 minutes'
            WHEN next_sample.is_up = 1 THEN next_sample.checked_at
            ELSE NULL
        END AS down_end
    FROM periods
    LEFT JOIN LATERAL (
        SELECT recovered.checked_at, recovered.is_up
        FROM :"schema_name".db_port_blackbox_probe_results recovered
        WHERE recovered.target_name = periods.target_name
          AND recovered.checked_at > periods.last_down_at
        ORDER BY recovered.checked_at
        LIMIT 1
    ) AS next_sample ON true
)
INSERT INTO :"schema_name".db_port_blackbox_downtime_events (
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
FROM with_recovery
WHERE NOT EXISTS (
    SELECT 1
    FROM :"schema_name".db_port_blackbox_downtime_events existing
)
ORDER BY target_name, down_start;

-- Correct legacy events that previously counted an unobserved monitoring gap
-- all the way through the next successful probe.
UPDATE :"schema_name".db_port_blackbox_downtime_events
SET
    down_end = last_down_at + interval '5 minutes',
    updated_at = now()
WHERE source = 'prometheus-blackbox'
  AND down_end > last_down_at + interval '10 minutes';

COMMIT;
