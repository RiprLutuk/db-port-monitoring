BEGIN;

\if :{?schema_name}
\else
\set schema_name monitoring
\endif

SET LOCAL search_path TO :"schema_name";

-- These views only supported the retired reporting/event dashboards.
DROP VIEW IF EXISTS db_port_blackbox_hourly_availability CASCADE;
DROP VIEW IF EXISTS db_port_blackbox_downtime_event_history CASCADE;
DROP VIEW IF EXISTS db_port_blackbox_latency_event_history CASCADE;

-- Keep only targets, raw probe samples, and daily KPI for the KPI dashboard.
DROP TABLE IF EXISTS db_port_blackbox_daily_error_summary_pre_1m CASCADE;
DROP TABLE IF EXISTS db_port_blackbox_daily_kpi_pre_1m CASCADE;
DROP TABLE IF EXISTS db_port_blackbox_hourly_kpi_pre_1m CASCADE;
DROP TABLE IF EXISTS db_port_blackbox_daily_error_summary CASCADE;
DROP TABLE IF EXISTS db_port_blackbox_hourly_kpi CASCADE;
DROP TABLE IF EXISTS db_port_blackbox_status_events CASCADE;
DROP TABLE IF EXISTS db_port_blackbox_downtime_events CASCADE;
DROP TABLE IF EXISTS db_port_blackbox_latency_events CASCADE;

COMMIT;
