BEGIN;

\if :{?schema_name}
\else
\set schema_name monitoring
\endif

ALTER TABLE :"schema_name".db_port_blackbox_targets
ADD COLUMN IF NOT EXISTS monitoring_excluded boolean NOT NULL DEFAULT false;

UPDATE :"schema_name".db_port_blackbox_targets
SET
    monitoring_excluded = true,
    updated_at = now()
WHERE target_name IN ('bmgcp-011-qa', 'bmjkt-000197')
  AND NOT monitoring_excluded;

COMMIT;
