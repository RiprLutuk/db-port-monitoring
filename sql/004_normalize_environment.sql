BEGIN;

\if :{?schema_name}
\else
\set schema_name monitoring
\endif

-- Environment is a source dimension, not a dashboard presentation rule.
-- QA and UAT are part of DEV and are normalized before new rows are stored.
SET LOCAL search_path TO :"schema_name";

DO $$
DECLARE
    table_name text;
BEGIN
    FOREACH table_name IN ARRAY ARRAY[
        'db_port_blackbox_probe_results',
        'db_port_blackbox_targets',
        'db_port_blackbox_daily_kpi',
        'db_port_blackbox_hourly_kpi',
        'db_port_blackbox_status_events',
        'db_port_blackbox_downtime_events',
        'db_port_blackbox_latency_events',
        'db_port_blackbox_daily_error_summary',
        'db_port_blackbox_hourly_kpi_pre_1m',
        'db_port_blackbox_daily_kpi_pre_1m',
        'db_port_blackbox_daily_error_summary_pre_1m'
    ] LOOP
        IF to_regclass(table_name) IS NOT NULL THEN
            EXECUTE format(
                'UPDATE %I SET environment = ''dev'' WHERE lower(environment) IN (''qa'', ''uat'', ''development'')',
                table_name
            );
            EXECUTE format(
                'UPDATE %I SET environment = lower(environment) WHERE environment <> lower(environment)',
                table_name
            );
        END IF;
    END LOOP;
END
$$;

COMMIT;
