BEGIN;

\if :{?schema_name}
\else
\set schema_name monitoring
\endif

CREATE SCHEMA IF NOT EXISTS :"schema_name";

-- KPI-only storage:
--   probe_results  raw samples for current status and short history
--   targets        target inventory and dashboard dimensions
--   daily_kpi      historical availability for the selected dashboard range
--   downtime events are added by 008_outage_events.sql
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
    monitoring_excluded boolean NOT NULL DEFAULT false,
    is_active boolean NOT NULL DEFAULT true,
    first_seen_at timestamptz NOT NULL DEFAULT now(),
    last_seen_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE :"schema_name".db_port_blackbox_targets
ADD COLUMN IF NOT EXISTS monitoring_excluded boolean NOT NULL DEFAULT false;

CREATE INDEX IF NOT EXISTS idx_db_port_blackbox_targets_active
ON :"schema_name".db_port_blackbox_targets (is_active, environment, db_type, target_name);

-- Durable progress for source windows that legitimately contain no samples.
-- Without this checkpoint, max(checked_at) cannot advance across a long
-- Prometheus gap and every writer restart would retry the same empty window.
CREATE TABLE IF NOT EXISTS :"schema_name".db_port_blackbox_writer_state (
    writer_name text PRIMARY KEY,
    cursor_at timestamptz NOT NULL,
    updated_at timestamptz NOT NULL DEFAULT now(),
    CHECK (btrim(writer_name) <> '')
);

COMMENT ON TABLE :"schema_name".db_port_blackbox_writer_state IS
'Durable Prometheus source-window cursor. This is operational state, not probe or KPI history.';

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
    last_seen_at = greatest(
        :"schema_name".db_port_blackbox_targets.last_seen_at,
        EXCLUDED.last_seen_at
    ),
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

CREATE OR REPLACE VIEW :"schema_name".db_port_blackbox_ingest_health AS
WITH active_targets AS (
    SELECT count(*)::bigint AS active_target_count
    FROM :"schema_name".db_port_blackbox_targets
    WHERE is_active = true
),
recent AS (
    SELECT count(DISTINCT probe.target_name)::bigint AS recent_target_count
    FROM :"schema_name".db_port_blackbox_probe_results probe
    INNER JOIN :"schema_name".db_port_blackbox_targets target
        ON target.target_name = probe.target_name
       AND target.is_active = true
    WHERE probe.checked_at >= now() - interval '10 minutes'
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
LEFT JOIN :"schema_name".db_port_blackbox_probe_results r
    ON r.target_name = t.target_name
WHERE t.is_active = true
GROUP BY t.target_name, t.db_type, t.environment, t.instance, t.criticality
HAVING max(r.checked_at) IS NULL
    OR max(r.checked_at) < now() - interval '10 minutes';

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

CREATE OR REPLACE VIEW :"schema_name".probe_history AS
SELECT
    checked_at,
    target_name AS host,
    host AS ip_address,
    port,
    db_type,
    environment,
    criticality,
    team,
    is_up = 1 AS probe_success,
    latency_ms,
    error_text
FROM :"schema_name".db_port_blackbox_probe_results;

CREATE OR REPLACE VIEW :"schema_name".probe_current_status AS
SELECT
    t.target_name AS host,
    t.host AS ip_address,
    t.port,
    t.db_type,
    t.environment,
    t.criticality,
    t.team,
    latest.checked_at,
    latest.is_up = 1 AS probe_success,
    latest.latency_ms,
    latest.error_text,
    t.monitoring_excluded
FROM :"schema_name".db_port_blackbox_targets t
JOIN LATERAL (
    SELECT
        r.checked_at,
        r.is_up,
        r.latency_ms,
        r.error_text
    FROM :"schema_name".db_port_blackbox_probe_results r
    WHERE r.target_name = t.target_name
    ORDER BY r.checked_at DESC
    LIMIT 1
) latest ON true;

CREATE OR REPLACE VIEW :"schema_name".probe_availability_30d AS
WITH availability AS (
    SELECT
        d.target_name AS host,
        sum(d.probes)::bigint AS observed_probes,
        round(sum(d.up_probes)::numeric / nullif(sum(d.probes), 0) * 100, 2) AS availability_pct
    FROM :"schema_name".db_port_blackbox_daily_kpi d
    WHERE d.period_start >= current_date - 29
    GROUP BY d.target_name
)
SELECT
    current_status.host,
    current_status.ip_address,
    current_status.port,
    current_status.db_type,
    current_status.environment,
    current_status.criticality,
    current_status.team,
    availability.observed_probes,
    availability.availability_pct,
    current_status.probe_success AS current_probe_success,
    current_status.checked_at AS last_probe_at,
    current_status.monitoring_excluded
FROM availability
JOIN :"schema_name".probe_current_status current_status USING (host);

COMMIT;
