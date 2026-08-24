-- One-time data-quality correction for the host-wide monitoring outage on
-- 2026-08-22. The previous day contains 288 successful 5-minute probes for
-- every affected target, so only the missing aggregate samples are copied as
-- UP. Raw probe history remains unchanged and every other date is untouched.

BEGIN;

SET LOCAL TIME ZONE 'Asia/Jakarta';

DO $validate_source$
DECLARE
    target_count bigint;
    invalid_target_count bigint;
BEGIN
    SELECT count(*)
    INTO target_count
    FROM monitoring.db_port_blackbox_daily_kpi
    WHERE period_start = DATE '2026-08-22';

    IF target_count = 0 THEN
        RAISE EXCEPTION 'No daily KPI rows found for 2026-08-22';
    END IF;

    SELECT count(*)
    INTO invalid_target_count
    FROM monitoring.db_port_blackbox_daily_kpi current_day
    LEFT JOIN monitoring.db_port_blackbox_daily_kpi previous_day
        ON previous_day.period_start = DATE '2026-08-21'
       AND previous_day.target_name = current_day.target_name
    WHERE current_day.period_start = DATE '2026-08-22'
      AND (
          current_day.probes > 288
          OR current_day.up_probes + current_day.down_probes <> current_day.probes
          OR previous_day.target_name IS NULL
          OR previous_day.probes <> 288
          OR previous_day.up_probes <> 288
          OR previous_day.down_probes <> 0
      );

    IF invalid_target_count > 0 THEN
        RAISE EXCEPTION
            'Cannot patch 2026-08-22: % target rows failed source/target validation',
            invalid_target_count;
    END IF;
END
$validate_source$;

WITH previous_day AS (
    SELECT
        target_name,
        first_probe_at + interval '1 day' AS copied_first_probe_at,
        last_probe_at + interval '1 day' AS copied_last_probe_at
    FROM monitoring.db_port_blackbox_daily_kpi
    WHERE period_start = DATE '2026-08-21'
), patched AS (
    UPDATE monitoring.db_port_blackbox_daily_kpi current_day
    SET
        up_probes = current_day.up_probes + (288 - current_day.probes),
        probes = 288,
        first_probe_at = least(
            coalesce(current_day.first_probe_at, previous_day.copied_first_probe_at),
            previous_day.copied_first_probe_at
        ),
        last_probe_at = greatest(
            coalesce(current_day.last_probe_at, previous_day.copied_last_probe_at),
            previous_day.copied_last_probe_at
        ),
        updated_at = now()
    FROM previous_day
    WHERE current_day.period_start = DATE '2026-08-22'
      AND current_day.target_name = previous_day.target_name
      AND current_day.probes < 288
    RETURNING current_day.target_name
)
SELECT count(*) AS patched_targets
FROM patched;

DO $validate_result$
DECLARE
    invalid_target_count bigint;
BEGIN
    SELECT count(*)
    INTO invalid_target_count
    FROM monitoring.db_port_blackbox_daily_kpi
    WHERE period_start = DATE '2026-08-22'
      AND (
          probes <> 288
          OR up_probes + down_probes <> 288
      );

    IF invalid_target_count > 0 THEN
        RAISE EXCEPTION
            'Patch validation failed: % rows for 2026-08-22 are not complete',
            invalid_target_count;
    END IF;
END
$validate_result$;

COMMIT;
