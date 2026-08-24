-- One-time raw-data correction for the host-wide monitoring issue on
-- 2026-08-23. All retained observations for the date are UP, but only 18,700
-- of the expected 24,192 target/bucket combinations were observed.
--
-- The migration inserts one explicitly labelled synthetic UP row for every
-- missing five-minute bucket, preserving all original observations. Because
-- retries produced 249 additional raw rows inside already observed buckets,
-- daily KPI is rebuilt from one conservative value per target/bucket rather
-- than from the physical raw-row count.
--
-- Operational assumption: the monitoring host had a collection issue and no
-- target outage was reported. Synthetic rows have unknown latency (NULL) and
-- source `monitoring-gap-assumed-up-2026-08-23` so they remain auditable.
-- Downtime events and every other date are untouched.

BEGIN;

SET LOCAL TIME ZONE 'Asia/Jakarta';

LOCK TABLE
    monitoring.db_port_blackbox_probe_results,
    monitoring.db_port_blackbox_daily_kpi
IN SHARE ROW EXCLUSIVE MODE;

DO $validate_source$
DECLARE
    daily_target_count bigint;
    raw_target_count bigint;
    mismatched_target_count bigint;
    missing_inventory_count bigint;
    observed_down_count bigint;
BEGIN
    SELECT count(DISTINCT target_name)
    INTO raw_target_count
    FROM monitoring.db_port_blackbox_probe_results
    WHERE checked_at >= TIMESTAMPTZ '2026-08-23 00:00:00+07'
      AND checked_at <  TIMESTAMPTZ '2026-08-24 00:00:00+07';

    SELECT count(*)
    INTO daily_target_count
    FROM monitoring.db_port_blackbox_daily_kpi AS daily
    WHERE daily.period_start = DATE '2026-08-23'
      AND EXISTS (
          SELECT 1
          FROM monitoring.db_port_blackbox_probe_results AS raw
          WHERE raw.target_name = daily.target_name
            AND raw.checked_at >= TIMESTAMPTZ '2026-08-23 00:00:00+07'
            AND raw.checked_at <  TIMESTAMPTZ '2026-08-24 00:00:00+07'
      );

    IF daily_target_count <> 84 OR raw_target_count <> 84 THEN
        RAISE EXCEPTION
            'Cannot patch 2026-08-23: expected 84 daily/raw targets, found daily=% raw=%',
            daily_target_count,
            raw_target_count;
    END IF;

    SELECT count(*)
    INTO mismatched_target_count
    FROM (
        SELECT DISTINCT target_name
        FROM monitoring.db_port_blackbox_probe_results
        WHERE checked_at >= TIMESTAMPTZ '2026-08-23 00:00:00+07'
          AND checked_at <  TIMESTAMPTZ '2026-08-24 00:00:00+07'
        EXCEPT
        SELECT target_name
        FROM monitoring.db_port_blackbox_daily_kpi
        WHERE period_start = DATE '2026-08-23'
    ) AS differences;

    IF mismatched_target_count > 0 THEN
        RAISE EXCEPTION
            'Cannot patch 2026-08-23: % target names differ between raw and daily KPI',
            mismatched_target_count;
    END IF;

    SELECT count(*)
    INTO missing_inventory_count
    FROM monitoring.db_port_blackbox_daily_kpi AS daily
    LEFT JOIN monitoring.db_port_blackbox_targets AS inventory
        ON inventory.target_name = daily.target_name
    WHERE daily.period_start = DATE '2026-08-23'
      AND inventory.target_name IS NULL;

    IF missing_inventory_count > 0 THEN
        RAISE EXCEPTION
            'Cannot patch 2026-08-23: % targets are missing from inventory',
            missing_inventory_count;
    END IF;

    SELECT count(*)
    INTO observed_down_count
    FROM monitoring.db_port_blackbox_probe_results
    WHERE checked_at >= TIMESTAMPTZ '2026-08-23 00:00:00+07'
      AND checked_at <  TIMESTAMPTZ '2026-08-24 00:00:00+07'
      AND is_up = 0;

    IF observed_down_count > 0 THEN
        RAISE EXCEPTION
            'Cannot patch 2026-08-23 as all-UP: % observed raw probes are DOWN',
            observed_down_count;
    END IF;
END
$validate_source$;

CREATE TEMP TABLE expected_day_buckets ON COMMIT DROP AS
SELECT
    raw_targets.target_name,
    bucket_start
FROM (
    SELECT DISTINCT target_name
    FROM monitoring.db_port_blackbox_probe_results
    WHERE checked_at >= TIMESTAMPTZ '2026-08-23 00:00:00+07'
      AND checked_at <  TIMESTAMPTZ '2026-08-24 00:00:00+07'
) AS raw_targets
CROSS JOIN generate_series(
    TIMESTAMPTZ '2026-08-23 00:00:00+07',
    TIMESTAMPTZ '2026-08-23 23:55:00+07',
    interval '5 minutes'
) AS expected(bucket_start);

CREATE UNIQUE INDEX expected_day_buckets_key
ON expected_day_buckets (target_name, bucket_start);

CREATE TEMP TABLE observed_day_buckets ON COMMIT DROP AS
SELECT DISTINCT
    target_name,
    date_bin(
        interval '5 minutes',
        checked_at,
        TIMESTAMPTZ '2026-08-23 00:00:00+07'
    ) AS bucket_start
FROM monitoring.db_port_blackbox_probe_results
WHERE checked_at >= TIMESTAMPTZ '2026-08-23 00:00:00+07'
  AND checked_at <  TIMESTAMPTZ '2026-08-24 00:00:00+07';

CREATE UNIQUE INDEX observed_day_buckets_key
ON observed_day_buckets (target_name, bucket_start);

WITH missing_buckets AS (
    SELECT
        expected.target_name,
        expected.bucket_start
    FROM expected_day_buckets AS expected
    LEFT JOIN observed_day_buckets AS observed
        ON observed.target_name = expected.target_name
       AND observed.bucket_start = expected.bucket_start
    WHERE observed.target_name IS NULL
), inserted AS (
    INSERT INTO monitoring.db_port_blackbox_probe_results (
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
        missing.bucket_start,
        inventory.target_name,
        inventory.db_type,
        inventory.environment,
        inventory.host,
        inventory.port,
        inventory.instance,
        inventory.criticality,
        inventory.team,
        1,
        NULL,
        NULL,
        'monitoring-gap-assumed-up-2026-08-23',
        now()
    FROM missing_buckets AS missing
    INNER JOIN monitoring.db_port_blackbox_targets AS inventory
        ON inventory.target_name = missing.target_name
    ORDER BY missing.bucket_start, missing.target_name
    ON CONFLICT (checked_at, target_name) DO NOTHING
    RETURNING target_name
)
SELECT count(*) AS inserted_synthetic_raw_rows
FROM inserted;

-- Consolidate retries to one reporting observation per five-minute bucket.
-- Existing raw rows are preserved; this temporary relation is only used to
-- rebuild the daily aggregate with cadence-neutral weighting.
CREATE TEMP TABLE normalized_day_buckets ON COMMIT DROP AS
SELECT
    target_name,
    date_bin(
        interval '5 minutes',
        checked_at,
        TIMESTAMPTZ '2026-08-23 00:00:00+07'
    ) AS bucket_start,
    min(is_up) AS is_up,
    CASE
        WHEN min(is_up) = 1
        THEN avg(latency_ms) FILTER (WHERE latency_ms IS NOT NULL)
        ELSE NULL
    END AS latency_ms
FROM monitoring.db_port_blackbox_probe_results
WHERE checked_at >= TIMESTAMPTZ '2026-08-23 00:00:00+07'
  AND checked_at <  TIMESTAMPTZ '2026-08-24 00:00:00+07'
GROUP BY
    target_name,
    date_bin(
        interval '5 minutes',
        checked_at,
        TIMESTAMPTZ '2026-08-23 00:00:00+07'
    );

CREATE UNIQUE INDEX normalized_day_buckets_key
ON normalized_day_buckets (target_name, bucket_start);

WITH daily AS (
    SELECT
        target_name,
        count(*)::bigint AS probes,
        count(*) FILTER (WHERE is_up = 1)::bigint AS up_probes,
        count(*) FILTER (WHERE is_up = 0)::bigint AS down_probes,
        count(*) FILTER (
            WHERE is_up = 1 AND latency_ms > 3000
        )::bigint AS slow_probes,
        coalesce(
            sum(latency_ms) FILTER (
                WHERE is_up = 1 AND latency_ms IS NOT NULL
            ),
            0
        ) AS latency_ms_sum,
        count(latency_ms) FILTER (WHERE is_up = 1)::bigint
            AS latency_ms_count,
        coalesce(max(latency_ms) FILTER (WHERE is_up = 1), 0)
            AS max_latency_ms
    FROM normalized_day_buckets
    GROUP BY target_name
)
INSERT INTO monitoring.db_port_blackbox_daily_kpi AS kpi (
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
    last_probe_at,
    updated_at,
    slow_probes,
    max_latency_ms
)
SELECT
    DATE '2026-08-23',
    inventory.target_name,
    inventory.db_type,
    inventory.environment,
    inventory.host,
    inventory.port,
    inventory.instance,
    inventory.criticality,
    inventory.team,
    daily.probes,
    daily.up_probes,
    daily.down_probes,
    daily.latency_ms_sum,
    daily.latency_ms_count,
    TIMESTAMPTZ '2026-08-23 00:00:00+07',
    TIMESTAMPTZ '2026-08-23 23:59:59+07',
    now(),
    daily.slow_probes,
    daily.max_latency_ms
FROM daily
INNER JOIN monitoring.db_port_blackbox_targets AS inventory
    ON inventory.target_name = daily.target_name
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
    latency_ms_sum = EXCLUDED.latency_ms_sum,
    latency_ms_count = EXCLUDED.latency_ms_count,
    first_probe_at = EXCLUDED.first_probe_at,
    last_probe_at = EXCLUDED.last_probe_at,
    updated_at = EXCLUDED.updated_at,
    slow_probes = EXCLUDED.slow_probes,
    max_latency_ms = EXCLUDED.max_latency_ms;

DO $validate_result$
DECLARE
    invalid_raw_target_count bigint;
    invalid_daily_target_count bigint;
BEGIN
    SELECT count(*)
    INTO invalid_raw_target_count
    FROM (
        SELECT target_name
        FROM monitoring.db_port_blackbox_probe_results
        WHERE checked_at >= TIMESTAMPTZ '2026-08-23 00:00:00+07'
          AND checked_at <  TIMESTAMPTZ '2026-08-24 00:00:00+07'
        GROUP BY target_name
        HAVING count(DISTINCT date_bin(
            interval '5 minutes',
            checked_at,
            TIMESTAMPTZ '2026-08-23 00:00:00+07'
        )) <> 288
           OR min(is_up) <> 1
    ) AS invalid;

    IF invalid_raw_target_count > 0 THEN
        RAISE EXCEPTION
            'Patch validation failed: % raw targets do not have 288 UP buckets',
            invalid_raw_target_count;
    END IF;

    SELECT count(*)
    INTO invalid_daily_target_count
    FROM monitoring.db_port_blackbox_daily_kpi
    WHERE period_start = DATE '2026-08-23'
      AND target_name IN (
          SELECT DISTINCT target_name
          FROM monitoring.db_port_blackbox_probe_results
          WHERE checked_at >= TIMESTAMPTZ '2026-08-23 00:00:00+07'
            AND checked_at <  TIMESTAMPTZ '2026-08-24 00:00:00+07'
      )
      AND (
          probes <> 288
          OR up_probes <> 288
          OR down_probes <> 0
          OR first_probe_at <>
             TIMESTAMPTZ '2026-08-23 00:00:00+07'
          OR last_probe_at <>
             TIMESTAMPTZ '2026-08-23 23:59:59+07'
      );

    IF invalid_daily_target_count > 0 THEN
        RAISE EXCEPTION
            'Patch validation failed: % daily rows are not 288/288/0',
            invalid_daily_target_count;
    END IF;
END
$validate_result$;

SELECT
    count(*) FILTER (
        WHERE source = 'monitoring-gap-assumed-up-2026-08-23'
    )::bigint AS synthetic_raw_rows,
    count(DISTINCT target_name)::bigint AS raw_targets,
    count(DISTINCT (target_name, date_bin(
        interval '5 minutes',
        checked_at,
        TIMESTAMPTZ '2026-08-23 00:00:00+07'
    )))::bigint AS unique_target_buckets
FROM monitoring.db_port_blackbox_probe_results
WHERE checked_at >= TIMESTAMPTZ '2026-08-23 00:00:00+07'
  AND checked_at <  TIMESTAMPTZ '2026-08-24 00:00:00+07';

COMMIT;
