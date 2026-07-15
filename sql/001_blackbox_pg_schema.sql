BEGIN;

\if :{?schema_name}
\else
\set schema_name monitoring
\endif

CREATE SCHEMA IF NOT EXISTS :"schema_name";

CREATE TABLE IF NOT EXISTS :"schema_name".db_port_blackbox_probe_results (
    id bigserial PRIMARY KEY,
    checked_at timestamptz NOT NULL,
    target_name text NOT NULL,
    db_type text NOT NULL,
    environment text NOT NULL,
    host text NOT NULL,
    port int NOT NULL CHECK (port BETWEEN 1 AND 65535),
    instance text NOT NULL,
    criticality text NULL,
    team text NULL,
    is_up int NOT NULL CHECK (is_up IN (0, 1)),
    latency_ms numeric NULL CHECK (latency_ms IS NULL OR latency_ms >= 0),
    error_text text NULL,
    source text NOT NULL DEFAULT 'prometheus-blackbox',
    created_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE (checked_at, target_name)
);

CREATE INDEX IF NOT EXISTS idx_db_port_blackbox_probe_results_checked_at
ON :"schema_name".db_port_blackbox_probe_results (checked_at DESC);

CREATE INDEX IF NOT EXISTS idx_db_port_blackbox_probe_results_target_time
ON :"schema_name".db_port_blackbox_probe_results (target_name, checked_at DESC);

CREATE INDEX IF NOT EXISTS idx_db_port_blackbox_probe_results_env_time
ON :"schema_name".db_port_blackbox_probe_results (environment, checked_at DESC);

CREATE TABLE IF NOT EXISTS :"schema_name".db_port_blackbox_targets (
    target_name text PRIMARY KEY,
    db_type text NOT NULL,
    environment text NOT NULL,
    host text NOT NULL,
    port int NOT NULL CHECK (port BETWEEN 1 AND 65535),
    instance text NOT NULL,
    criticality text NULL,
    team text NULL,
    is_active boolean NOT NULL DEFAULT true,
    first_seen_at timestamptz NOT NULL DEFAULT now(),
    last_seen_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_db_port_blackbox_targets_active
ON :"schema_name".db_port_blackbox_targets (is_active, environment, db_type, target_name);

WITH latest AS (
    SELECT DISTINCT ON (target_name)
        target_name,
        db_type,
        environment,
        host,
        port,
        instance,
        criticality,
        team,
        checked_at
    FROM :"schema_name".db_port_blackbox_probe_results
    ORDER BY target_name, checked_at DESC
)
INSERT INTO :"schema_name".db_port_blackbox_targets (
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
FROM latest
ON CONFLICT (target_name) DO UPDATE SET
    db_type = EXCLUDED.db_type,
    environment = EXCLUDED.environment,
    host = EXCLUDED.host,
    port = EXCLUDED.port,
    instance = EXCLUDED.instance,
    criticality = EXCLUDED.criticality,
    team = EXCLUDED.team,
    is_active = true,
    last_seen_at = greatest(:"schema_name".db_port_blackbox_targets.last_seen_at, EXCLUDED.last_seen_at),
    updated_at = now();

CREATE TABLE IF NOT EXISTS :"schema_name".db_port_blackbox_daily_kpi (
    period_start date NOT NULL,
    target_name text NOT NULL,
    db_type text NOT NULL,
    environment text NOT NULL,
    host text NOT NULL,
    port int NOT NULL CHECK (port BETWEEN 1 AND 65535),
    instance text NOT NULL,
    criticality text NULL,
    team text NULL,
    probes bigint NOT NULL DEFAULT 0,
    up_probes bigint NOT NULL DEFAULT 0,
    down_probes bigint NOT NULL DEFAULT 0,
    slow_probes bigint NOT NULL DEFAULT 0,
    latency_ms_sum numeric NOT NULL DEFAULT 0,
    latency_ms_count bigint NOT NULL DEFAULT 0,
    max_latency_ms numeric NULL,
    first_probe_at timestamptz NULL,
    last_probe_at timestamptz NULL,
    updated_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (period_start, target_name)
);

ALTER TABLE :"schema_name".db_port_blackbox_daily_kpi
ADD COLUMN IF NOT EXISTS slow_probes bigint NOT NULL DEFAULT 0;

ALTER TABLE :"schema_name".db_port_blackbox_daily_kpi
ADD COLUMN IF NOT EXISTS max_latency_ms numeric NULL;

CREATE INDEX IF NOT EXISTS idx_db_port_blackbox_daily_kpi_target_period
ON :"schema_name".db_port_blackbox_daily_kpi (target_name, period_start DESC);

CREATE INDEX IF NOT EXISTS idx_db_port_blackbox_daily_kpi_env_period
ON :"schema_name".db_port_blackbox_daily_kpi (environment, period_start DESC);

CREATE TABLE IF NOT EXISTS :"schema_name".db_port_blackbox_hourly_kpi (
    period_hour timestamptz NOT NULL,
    target_name text NOT NULL,
    db_type text NOT NULL,
    environment text NOT NULL,
    host text NOT NULL,
    port int NOT NULL CHECK (port BETWEEN 1 AND 65535),
    instance text NOT NULL,
    criticality text NULL,
    team text NULL,
    probes bigint NOT NULL DEFAULT 0,
    up_probes bigint NOT NULL DEFAULT 0,
    down_probes bigint NOT NULL DEFAULT 0,
    slow_probes bigint NOT NULL DEFAULT 0,
    latency_ms_sum numeric NOT NULL DEFAULT 0,
    latency_ms_count bigint NOT NULL DEFAULT 0,
    max_latency_ms numeric NULL,
    first_probe_at timestamptz NULL,
    last_probe_at timestamptz NULL,
    updated_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (period_hour, target_name)
);

CREATE INDEX IF NOT EXISTS idx_db_port_blackbox_hourly_kpi_target_period
ON :"schema_name".db_port_blackbox_hourly_kpi (target_name, period_hour DESC);

CREATE INDEX IF NOT EXISTS idx_db_port_blackbox_hourly_kpi_env_period
ON :"schema_name".db_port_blackbox_hourly_kpi (environment, period_hour DESC);

CREATE TABLE IF NOT EXISTS :"schema_name".db_port_blackbox_status_events (
    event_at timestamptz NOT NULL,
    target_name text NOT NULL,
    db_type text NOT NULL,
    environment text NOT NULL,
    host text NOT NULL,
    port int NOT NULL CHECK (port BETWEEN 1 AND 65535),
    instance text NOT NULL,
    criticality text NULL,
    team text NULL,
    previous_is_up int NULL CHECK (previous_is_up IS NULL OR previous_is_up IN (0, 1)),
    current_is_up int NOT NULL CHECK (current_is_up IN (0, 1)),
    latency_ms numeric NULL CHECK (latency_ms IS NULL OR latency_ms >= 0),
    error_text text NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (target_name, event_at)
);

CREATE INDEX IF NOT EXISTS idx_db_port_blackbox_status_events_event_at
ON :"schema_name".db_port_blackbox_status_events (event_at DESC);

CREATE INDEX IF NOT EXISTS idx_db_port_blackbox_status_events_env_event
ON :"schema_name".db_port_blackbox_status_events (environment, event_at DESC);

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
    down_samples bigint NOT NULL DEFAULT 0,
    first_error_text text NULL,
    last_error_text text NULL,
    max_latency_ms numeric NULL CHECK (max_latency_ms IS NULL OR max_latency_ms >= 0),
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (target_name, down_start)
);

CREATE INDEX IF NOT EXISTS idx_db_port_blackbox_downtime_events_start
ON :"schema_name".db_port_blackbox_downtime_events (down_start DESC);

CREATE INDEX IF NOT EXISTS idx_db_port_blackbox_downtime_events_env_start
ON :"schema_name".db_port_blackbox_downtime_events (environment, down_start DESC);

CREATE INDEX IF NOT EXISTS idx_db_port_blackbox_downtime_events_open
ON :"schema_name".db_port_blackbox_downtime_events (target_name)
WHERE down_end IS NULL;

CREATE UNIQUE INDEX IF NOT EXISTS uq_db_port_blackbox_downtime_events_one_open
ON :"schema_name".db_port_blackbox_downtime_events (target_name)
WHERE down_end IS NULL;

CREATE TABLE IF NOT EXISTS :"schema_name".db_port_blackbox_latency_events (
    target_name text NOT NULL,
    slow_start timestamptz NOT NULL,
    slow_end timestamptz NULL,
    last_slow_at timestamptz NOT NULL,
    threshold_ms numeric NOT NULL DEFAULT 3000,
    db_type text NOT NULL,
    environment text NOT NULL,
    host text NOT NULL,
    port int NOT NULL CHECK (port BETWEEN 1 AND 65535),
    instance text NOT NULL,
    criticality text NULL,
    team text NULL,
    slow_samples bigint NOT NULL DEFAULT 0,
    latency_ms_sum numeric NOT NULL DEFAULT 0,
    latency_ms_count bigint NOT NULL DEFAULT 0,
    max_latency_ms numeric NULL CHECK (max_latency_ms IS NULL OR max_latency_ms >= 0),
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (target_name, slow_start, threshold_ms)
);

CREATE INDEX IF NOT EXISTS idx_db_port_blackbox_latency_events_start
ON :"schema_name".db_port_blackbox_latency_events (slow_start DESC);

CREATE INDEX IF NOT EXISTS idx_db_port_blackbox_latency_events_env_start
ON :"schema_name".db_port_blackbox_latency_events (environment, slow_start DESC);

CREATE INDEX IF NOT EXISTS idx_db_port_blackbox_latency_events_open
ON :"schema_name".db_port_blackbox_latency_events (target_name, threshold_ms)
WHERE slow_end IS NULL;

CREATE UNIQUE INDEX IF NOT EXISTS uq_db_port_blackbox_latency_events_one_open
ON :"schema_name".db_port_blackbox_latency_events (target_name, threshold_ms)
WHERE slow_end IS NULL;

CREATE TABLE IF NOT EXISTS :"schema_name".db_port_blackbox_daily_error_summary (
    period_start date NOT NULL,
    target_name text NOT NULL,
    db_type text NOT NULL,
    environment text NOT NULL,
    host text NOT NULL,
    port int NOT NULL CHECK (port BETWEEN 1 AND 65535),
    instance text NOT NULL,
    criticality text NULL,
    team text NULL,
    error_text text NOT NULL,
    error_count bigint NOT NULL DEFAULT 0,
    first_seen_at timestamptz NOT NULL,
    last_seen_at timestamptz NOT NULL,
    updated_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (period_start, target_name, error_text)
);

CREATE INDEX IF NOT EXISTS idx_db_port_blackbox_daily_error_summary_target_period
ON :"schema_name".db_port_blackbox_daily_error_summary (target_name, period_start DESC);

CREATE INDEX IF NOT EXISTS idx_db_port_blackbox_daily_error_summary_env_period
ON :"schema_name".db_port_blackbox_daily_error_summary (environment, period_start DESC);

CREATE OR REPLACE VIEW :"schema_name".db_port_blackbox_ingest_health AS
WITH active_targets AS (
    SELECT count(*)::bigint AS active_target_count
    FROM :"schema_name".db_port_blackbox_targets
    WHERE is_active = true
),
recent AS (
    SELECT count(DISTINCT target_name)::bigint AS recent_target_count
    FROM :"schema_name".db_port_blackbox_probe_results
    WHERE checked_at >= now() - interval '3 minutes'
),
latest AS (
    SELECT max(checked_at) AS latest_checked_at
    FROM :"schema_name".db_port_blackbox_probe_results
)
SELECT
    active_targets.active_target_count,
    coalesce(recent.recent_target_count, 0) AS recent_target_count,
    active_targets.active_target_count - coalesce(recent.recent_target_count, 0) AS missing_recent_target_count,
    latest.latest_checked_at,
    extract(epoch FROM now() - latest.latest_checked_at)::bigint AS ingest_lag_seconds
FROM active_targets
CROSS JOIN recent
CROSS JOIN latest;

CREATE OR REPLACE VIEW :"schema_name".db_port_blackbox_missing_recent_targets AS
SELECT
    t.target_name,
    t.db_type,
    t.environment,
    t.instance,
    t.criticality,
    max(r.checked_at) AS last_probe_at,
    extract(epoch FROM now() - max(r.checked_at))::bigint AS seconds_since_last_probe
FROM :"schema_name".db_port_blackbox_targets t
LEFT JOIN :"schema_name".db_port_blackbox_probe_results r ON r.target_name = t.target_name
WHERE t.is_active = true
GROUP BY t.target_name, t.db_type, t.environment, t.instance, t.criticality
HAVING max(r.checked_at) IS NULL
    OR max(r.checked_at) < now() - interval '3 minutes';

CREATE TEMP TABLE blackbox_normalized_minute_samples ON COMMIT DROP AS
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
FROM :"schema_name".db_port_blackbox_probe_results
GROUP BY date_trunc('minute', checked_at), target_name;

INSERT INTO :"schema_name".db_port_blackbox_daily_kpi (
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
    sum(CASE WHEN is_up = 1 THEN 1 ELSE 0 END)::bigint,
    sum(CASE WHEN is_up = 0 THEN 1 ELSE 0 END)::bigint,
    count(*) FILTER (WHERE is_slow)::bigint,
    coalesce(sum(latency_ms) FILTER (WHERE is_up = 1 AND latency_ms IS NOT NULL), 0),
    count(latency_ms) FILTER (WHERE is_up = 1)::bigint,
    max(max_latency_ms) FILTER (WHERE is_up = 1),
    min(first_probe_at),
    max(last_probe_at)
FROM blackbox_normalized_minute_samples
GROUP BY period_minute::date, target_name
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

INSERT INTO :"schema_name".db_port_blackbox_hourly_kpi (
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
    sum(CASE WHEN is_up = 1 THEN 1 ELSE 0 END)::bigint,
    sum(CASE WHEN is_up = 0 THEN 1 ELSE 0 END)::bigint,
    count(*) FILTER (WHERE is_slow)::bigint,
    coalesce(sum(latency_ms) FILTER (WHERE is_up = 1 AND latency_ms IS NOT NULL), 0),
    count(latency_ms) FILTER (WHERE is_up = 1)::bigint,
    max(max_latency_ms) FILTER (WHERE is_up = 1),
    min(first_probe_at),
    max(last_probe_at)
FROM blackbox_normalized_minute_samples
GROUP BY date_trunc('hour', period_minute), target_name
ON CONFLICT (period_hour, target_name) DO UPDATE SET
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

WITH ordered AS (
    SELECT
        r.*,
        lag(r.is_up) OVER (PARTITION BY r.target_name ORDER BY r.checked_at) AS previous_is_up
    FROM :"schema_name".db_port_blackbox_probe_results r
)
INSERT INTO :"schema_name".db_port_blackbox_status_events (
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
    previous_is_up,
    is_up,
    latency_ms,
    error_text
FROM ordered
WHERE previous_is_up IS DISTINCT FROM is_up
ON CONFLICT (target_name, event_at) DO UPDATE SET
    db_type = EXCLUDED.db_type,
    environment = EXCLUDED.environment,
    host = EXCLUDED.host,
    port = EXCLUDED.port,
    instance = EXCLUDED.instance,
    criticality = EXCLUDED.criticality,
    team = EXCLUDED.team,
    previous_is_up = EXCLUDED.previous_is_up,
    current_is_up = EXCLUDED.current_is_up,
    latency_ms = EXCLUDED.latency_ms,
    error_text = EXCLUDED.error_text;

WITH ordered AS (
    SELECT
        r.*,
        lag(r.is_up) OVER (PARTITION BY r.target_name ORDER BY r.checked_at) AS previous_is_up
    FROM :"schema_name".db_port_blackbox_probe_results r
),
grouped AS (
    SELECT
        *,
        sum(CASE WHEN previous_is_up IS DISTINCT FROM is_up THEN 1 ELSE 0 END)
            OVER (PARTITION BY target_name ORDER BY checked_at) AS group_id
    FROM ordered
),
periods AS (
    SELECT
        target_name,
        min(checked_at) AS down_start,
        max(checked_at) AS last_down_at,
        max(db_type) AS db_type,
        max(environment) AS environment,
        max(host) AS host,
        max(port) AS port,
        max(instance) AS instance,
        max(criticality) AS criticality,
        max(team) AS team,
        count(*)::bigint AS down_samples,
        (array_remove(array_agg(error_text ORDER BY checked_at), NULL))[1] AS first_error_text,
        (array_remove(array_agg(error_text ORDER BY checked_at DESC), NULL))[1] AS last_error_text,
        max(latency_ms) AS max_latency_ms
    FROM grouped
    WHERE is_up = 0
    GROUP BY target_name, group_id
),
with_recovery AS (
    SELECT
        p.*,
        (
            SELECT min(r.checked_at)
            FROM :"schema_name".db_port_blackbox_probe_results r
            WHERE r.target_name = p.target_name
              AND r.checked_at > p.last_down_at
              AND r.is_up = 1
        ) AS down_end
    FROM periods p
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
    max_latency_ms
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
    max_latency_ms
FROM with_recovery
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
    updated_at = now();

WITH raw AS (
    SELECT
        r.*,
        (r.is_up = 1 AND r.latency_ms > 3000) AS is_slow
    FROM :"schema_name".db_port_blackbox_probe_results r
),
ordered AS (
    SELECT
        raw.*,
        lag(is_slow) OVER (PARTITION BY target_name ORDER BY checked_at) AS previous_is_slow
    FROM raw
),
grouped AS (
    SELECT
        *,
        sum(CASE WHEN previous_is_slow IS DISTINCT FROM is_slow THEN 1 ELSE 0 END)
            OVER (PARTITION BY target_name ORDER BY checked_at) AS group_id
    FROM ordered
),
periods AS (
    SELECT
        target_name,
        min(checked_at) AS slow_start,
        max(checked_at) AS last_slow_at,
        3000::numeric AS threshold_ms,
        max(db_type) AS db_type,
        max(environment) AS environment,
        max(host) AS host,
        max(port) AS port,
        max(instance) AS instance,
        max(criticality) AS criticality,
        max(team) AS team,
        count(*)::bigint AS slow_samples,
        coalesce(sum(latency_ms), 0) AS latency_ms_sum,
        count(latency_ms)::bigint AS latency_ms_count,
        max(latency_ms) AS max_latency_ms
    FROM grouped
    WHERE is_slow = true
    GROUP BY target_name, group_id
),
with_recovery AS (
    SELECT
        p.*,
        (
            SELECT min(r.checked_at)
            FROM :"schema_name".db_port_blackbox_probe_results r
            WHERE r.target_name = p.target_name
              AND r.checked_at > p.last_slow_at
              AND NOT (r.is_up = 1 AND r.latency_ms > p.threshold_ms)
        ) AS slow_end
    FROM periods p
)
INSERT INTO :"schema_name".db_port_blackbox_latency_events (
    target_name,
    slow_start,
    slow_end,
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
)
SELECT
    target_name,
    slow_start,
    slow_end,
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
FROM with_recovery
ON CONFLICT (target_name, slow_start, threshold_ms) DO UPDATE SET
    slow_end = EXCLUDED.slow_end,
    last_slow_at = EXCLUDED.last_slow_at,
    db_type = EXCLUDED.db_type,
    environment = EXCLUDED.environment,
    host = EXCLUDED.host,
    port = EXCLUDED.port,
    instance = EXCLUDED.instance,
    criticality = EXCLUDED.criticality,
    team = EXCLUDED.team,
    slow_samples = EXCLUDED.slow_samples,
    latency_ms_sum = EXCLUDED.latency_ms_sum,
    latency_ms_count = EXCLUDED.latency_ms_count,
    max_latency_ms = EXCLUDED.max_latency_ms,
    updated_at = now();

INSERT INTO :"schema_name".db_port_blackbox_daily_error_summary (
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
    coalesce(error_text, 'blackbox probe failed') AS error_text,
    count(*)::bigint,
    min(first_down_at),
    max(last_down_at)
FROM blackbox_normalized_minute_samples
WHERE is_up = 0
GROUP BY period_minute::date, target_name, coalesce(error_text, 'blackbox probe failed')
ON CONFLICT (period_start, target_name, error_text) DO UPDATE SET
    db_type = EXCLUDED.db_type,
    environment = EXCLUDED.environment,
    host = EXCLUDED.host,
    port = EXCLUDED.port,
    instance = EXCLUDED.instance,
    criticality = EXCLUDED.criticality,
    team = EXCLUDED.team,
    error_count = EXCLUDED.error_count,
    first_seen_at = EXCLUDED.first_seen_at,
    last_seen_at = EXCLUDED.last_seen_at,
    updated_at = now();

CREATE OR REPLACE VIEW :"schema_name".db_port_blackbox_daily_availability AS
SELECT
    period_start::timestamptz AS period_start,
    target_name,
    db_type,
    environment,
    criticality,
    probes,
    up_probes,
    down_probes,
    round(up_probes::numeric / nullif(probes, 0) * 100, 2) AS availability_pct,
    round(latency_ms_sum / nullif(latency_ms_count, 0), 2) AS avg_latency_ms,
    last_probe_at,
    slow_probes,
    round(max_latency_ms, 2) AS max_latency_ms
FROM :"schema_name".db_port_blackbox_daily_kpi;

CREATE OR REPLACE VIEW :"schema_name".db_port_blackbox_monthly_availability AS
SELECT
    date_trunc('month', period_start::timestamptz) AS period_start,
    target_name,
    db_type,
    environment,
    criticality,
    sum(probes)::bigint AS probes,
    sum(up_probes)::bigint AS up_probes,
    sum(down_probes)::bigint AS down_probes,
    round(sum(up_probes)::numeric / nullif(sum(probes), 0) * 100, 2) AS availability_pct,
    round(sum(latency_ms_sum) / nullif(sum(latency_ms_count), 0), 2) AS avg_latency_ms,
    max(last_probe_at) AS last_probe_at,
    sum(slow_probes)::bigint AS slow_probes,
    round(max(max_latency_ms), 2) AS max_latency_ms
FROM :"schema_name".db_port_blackbox_daily_kpi
GROUP BY 1, 2, 3, 4, 5;

CREATE OR REPLACE VIEW :"schema_name".db_port_blackbox_yearly_availability AS
SELECT
    date_trunc('year', period_start::timestamptz) AS period_start,
    target_name,
    db_type,
    environment,
    criticality,
    sum(probes)::bigint AS probes,
    sum(up_probes)::bigint AS up_probes,
    sum(down_probes)::bigint AS down_probes,
    round(sum(up_probes)::numeric / nullif(sum(probes), 0) * 100, 2) AS availability_pct,
    round(sum(latency_ms_sum) / nullif(sum(latency_ms_count), 0), 2) AS avg_latency_ms,
    max(last_probe_at) AS last_probe_at,
    sum(slow_probes)::bigint AS slow_probes,
    round(max(max_latency_ms), 2) AS max_latency_ms
FROM :"schema_name".db_port_blackbox_daily_kpi
GROUP BY 1, 2, 3, 4, 5;

CREATE OR REPLACE VIEW :"schema_name".db_port_blackbox_hourly_availability AS
SELECT
    period_hour,
    target_name,
    db_type,
    environment,
    criticality,
    probes,
    up_probes,
    down_probes,
    slow_probes,
    round(up_probes::numeric / nullif(probes, 0) * 100, 2) AS availability_pct,
    round(latency_ms_sum / nullif(latency_ms_count, 0), 2) AS avg_latency_ms,
    round(max_latency_ms, 2) AS max_latency_ms,
    last_probe_at
FROM :"schema_name".db_port_blackbox_hourly_kpi;

CREATE OR REPLACE VIEW :"schema_name".db_port_blackbox_downtime_event_history AS
SELECT
    target_name,
    environment,
    db_type,
    instance,
    criticality,
    team,
    down_start,
    down_end,
    last_down_at,
    CASE WHEN down_end IS NULL THEN 'OPEN' ELSE 'CLOSED' END AS event_status,
    round(extract(epoch FROM coalesce(down_end, now()) - down_start)::numeric, 2) AS duration_seconds,
    round(extract(epoch FROM coalesce(down_end, now()) - down_start)::numeric / 60.0, 2) AS duration_minutes,
    down_samples,
    first_error_text,
    last_error_text,
    round(max_latency_ms, 2) AS max_latency_ms
FROM :"schema_name".db_port_blackbox_downtime_events;

CREATE OR REPLACE VIEW :"schema_name".db_port_blackbox_latency_event_history AS
SELECT
    target_name,
    environment,
    db_type,
    instance,
    criticality,
    team,
    threshold_ms,
    slow_start,
    slow_end,
    last_slow_at,
    CASE WHEN slow_end IS NULL THEN 'OPEN' ELSE 'CLOSED' END AS event_status,
    round(extract(epoch FROM coalesce(slow_end, now()) - slow_start)::numeric, 2) AS duration_seconds,
    round(extract(epoch FROM coalesce(slow_end, now()) - slow_start)::numeric / 60.0, 2) AS duration_minutes,
    slow_samples,
    round(latency_ms_sum / nullif(latency_ms_count, 0), 2) AS avg_latency_ms,
    round(max_latency_ms, 2) AS max_latency_ms
FROM :"schema_name".db_port_blackbox_latency_events;

COMMIT;
