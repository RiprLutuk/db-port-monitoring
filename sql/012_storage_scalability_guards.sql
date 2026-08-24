\if :{?schema_name}
\else
\set schema_name monitoring
\endif

BEGIN;

SET LOCAL lock_timeout = '5s';

-- Raw history is append/delete heavy. Vacuum before dead tuples become a
-- material fraction of the rolling 30-day table.
ALTER TABLE :"schema_name".db_port_blackbox_probe_results SET (
    autovacuum_vacuum_scale_factor = 0.02,
    autovacuum_vacuum_threshold = 5000,
    autovacuum_analyze_scale_factor = 0.05,
    autovacuum_analyze_threshold = 5000
);

-- The current daily row is updated every probe cycle. Leave page room for HOT
-- updates and vacuum it in smaller, predictable batches.
ALTER TABLE :"schema_name".db_port_blackbox_daily_kpi SET (
    fillfactor = 80,
    autovacuum_vacuum_scale_factor = 0.05,
    autovacuum_vacuum_threshold = 500,
    autovacuum_analyze_scale_factor = 0.10,
    autovacuum_analyze_threshold = 500
);

-- Retention filters on the effective event end, not only down_start.
CREATE INDEX IF NOT EXISTS idx_db_port_blackbox_downtime_events_retention
ON :"schema_name".db_port_blackbox_downtime_events (
    (coalesce(down_end, last_down_at))
);

COMMIT;
