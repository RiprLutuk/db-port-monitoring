#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

: "${ENV_FILE:=}"
: "${PROMETHEUS_URL:=http://prometheus:9090}"
: "${ALERTMANAGER_URL:=http://alertmanager:9093}"
: "${WRITER_METRICS_URL:=http://blackbox-pg-writer:8080/metrics}"
: "${BLACKBOX_DATA_FRESHNESS_SECONDS:=900}"
: "${BLACKBOX_RAW_TABLE_MAX_BYTES:=2147483648}"
: "${BLACKBOX_RETENTION_GRACE_SECONDS:=3600}"
: "${BLACKBOX_WRITER_CYCLE_MAX_SECONDS:=240}"
: "${WRITER_STATE_NAME:=prometheus-blackbox}"

load_env_file_raw "$ENV_FILE"
map_pg_env
require_pg_env

failures=0

pass() {
  printf 'PASS  %s\n' "$*"
}

fail() {
  printf 'FAIL  %s\n' "$*" >&2
  failures=$((failures + 1))
}

prometheus_value() {
  local query="$1"
  local encoded_query response

  encoded_query="$(jq -nr --arg query "$query" '$query | @uri')"
  if ! response="$(wget -q --timeout=15 --tries=2 -O- "${PROMETHEUS_URL%/}/api/v1/query?query=${encoded_query}")"; then
    return 1
  fi

  jq -e '.status == "success" and (.data.result | length) == 1' \
    <<< "$response" >/dev/null 2>&1 || return 1
  jq -er '.data.result[0].value[1]' <<< "$response"
}

if wget -q --timeout=10 --tries=2 -O- "${PROMETHEUS_URL%/}/-/ready" >/dev/null; then
  pass "Prometheus is ready"
else
  fail "Prometheus is not ready"
fi

if wget -q --timeout=10 --tries=2 -O- "${ALERTMANAGER_URL%/}/-/ready" >/dev/null; then
  pass "Alertmanager is ready"
else
  fail "Alertmanager is not ready"
fi

prometheus_targets="$(prometheus_value 'count(probe_success{job="db-port-availability"})' 2>/dev/null || true)"
prometheus_scrape_min="$(prometheus_value 'min(up{job="db-port-availability"})' 2>/dev/null || true)"

quoted_schema="${PGSCHEMA//\"/\"\"}"
health_sql="
WITH health AS (
    SELECT * FROM \"${quoted_schema}\".db_port_blackbox_ingest_health
), integrity AS (
    SELECT
        count(*) FILTER (
            WHERE probes < 0
               OR up_probes < 0
               OR down_probes < 0
               OR probes <> up_probes + down_probes
        )::bigint AS invalid_daily_rows
    FROM \"${quoted_schema}\".db_port_blackbox_daily_kpi
), event_integrity AS (
    SELECT count(*)::bigint AS invalid_gap_events
    FROM \"${quoted_schema}\".db_port_blackbox_downtime_events
    WHERE source = 'prometheus-blackbox'
      AND down_end > last_down_at + interval '10 minutes'
), event_overlap AS (
    SELECT count(*)::bigint AS overlapping_events
    FROM \"${quoted_schema}\".db_port_blackbox_downtime_events left_event
    INNER JOIN \"${quoted_schema}\".db_port_blackbox_downtime_events right_event
        ON right_event.target_name = left_event.target_name
       AND right_event.down_start > left_event.down_start
       AND right_event.down_start < coalesce(
            left_event.down_end,
            least(now(), left_event.last_down_at + interval '5 minutes')
       )
), future_rows AS (
    SELECT count(*)::bigint AS future_probe_rows
    FROM \"${quoted_schema}\".db_port_blackbox_probe_results
    WHERE checked_at > now() + interval '5 minutes'
), checkpoint AS (
    SELECT
        coalesce(floor(extract(epoch FROM cursor_at))::bigint, 0) AS checkpoint_epoch,
        coalesce(greatest(floor(extract(epoch FROM now() - cursor_at))::bigint, 0), 0) AS checkpoint_lag_seconds
    FROM \"${quoted_schema}\".db_port_blackbox_writer_state
    WHERE writer_name = '${WRITER_STATE_NAME}'
)
SELECT
    health.active_target_count,
    health.recent_target_count,
    health.missing_recent_target_count,
    coalesce(floor(extract(epoch FROM health.latest_checked_at))::bigint, 0),
    coalesce(health.ingest_lag_seconds, 2147483647),
    integrity.invalid_daily_rows,
    event_integrity.invalid_gap_events,
    event_overlap.overlapping_events,
    future_rows.future_probe_rows,
    coalesce(checkpoint.checkpoint_epoch, 0),
    coalesce(checkpoint.checkpoint_lag_seconds, 2147483647)
FROM health
CROSS JOIN integrity
CROSS JOIN event_integrity
CROSS JOIN event_overlap
CROSS JOIN future_rows
LEFT JOIN checkpoint ON true;"

if ! health_row="$("${SCRIPT_DIR}/run-psql.sh" -qAtc "$health_sql")"; then
  fail "PostgreSQL integrity query failed"
  health_row=""
fi

IFS='|' read -r \
  active_targets recent_targets missing_targets latest_probe_epoch ingest_lag \
  invalid_daily invalid_gap_events overlapping_events future_rows checkpoint_epoch checkpoint_lag \
  <<< "$health_row"

if [[ "$active_targets" =~ ^[0-9]+$ ]] && (( active_targets > 0 )); then
  pass "PostgreSQL inventory has ${active_targets} active targets"
else
  fail "PostgreSQL active-target count is invalid: ${active_targets:-missing}"
fi

if [[ "$prometheus_targets" =~ ^[0-9]+([.][0-9]+)?$ ]] \
  && [[ "$active_targets" =~ ^[0-9]+$ ]] \
  && (( ${prometheus_targets%.*} == active_targets )); then
  pass "Prometheus and PostgreSQL target counts match (${active_targets})"
else
  fail "Prometheus target count (${prometheus_targets:-missing}) differs from PostgreSQL (${active_targets:-missing})"
fi

if [[ "$prometheus_scrape_min" == "1" ]]; then
  pass "Every DB target scrape is currently successful"
else
  fail "At least one DB target scrape is failing (min up=${prometheus_scrape_min:-missing})"
fi

if [[ "$missing_targets" == "0" ]] && [[ "$recent_targets" == "$active_targets" ]]; then
  pass "Every active target has a PostgreSQL sample in the last 10 minutes"
else
  fail "Recent PostgreSQL coverage is ${recent_targets:-missing}/${active_targets:-missing}; missing=${missing_targets:-missing}"
fi

if [[ "$ingest_lag" =~ ^[0-9]+$ ]] && (( ingest_lag <= BLACKBOX_DATA_FRESHNESS_SECONDS )); then
  pass "Latest PostgreSQL probe is ${ingest_lag}s old"
else
  fail "Latest PostgreSQL probe is stale (${ingest_lag:-missing}s)"
fi

if [[ "$checkpoint_epoch" =~ ^[0-9]+$ ]] && (( checkpoint_epoch > 0 )) \
  && [[ "$checkpoint_lag" =~ ^[0-9]+$ ]] && (( checkpoint_lag <= BLACKBOX_DATA_FRESHNESS_SECONDS )); then
  pass "Durable writer checkpoint is ${checkpoint_lag}s behind now"
else
  fail "Durable writer checkpoint is missing or stale (${checkpoint_lag:-missing}s)"
fi

if [[ "$invalid_daily" == "0" ]]; then
  pass "Daily KPI counters satisfy probes = up + down"
else
  fail "${invalid_daily:-missing} daily KPI rows have invalid counters"
fi

if [[ "$invalid_gap_events" == "0" ]]; then
  pass "Downtime events do not count unobserved gaps as downtime"
else
  fail "${invalid_gap_events:-missing} downtime events extend across unobserved gaps"
fi

if [[ "$overlapping_events" == "0" ]]; then
  pass "Downtime events do not overlap per target"
else
  fail "${overlapping_events:-missing} downtime-event overlaps found"
fi

if [[ "$future_rows" == "0" ]]; then
  pass "No future-dated probe rows found"
else
  fail "${future_rows:-missing} future-dated probe rows found"
fi

if writer_metrics="$(wget -q --timeout=10 --tries=2 -O- "$WRITER_METRICS_URL")"; then
  writer_cycle="$(awk '$1 == "blackbox_pg_writer_cycle_success" { print $2 }' <<< "$writer_metrics")"
  writer_data="$(awk '$1 == "blackbox_pg_writer_data_healthy" { print $2 }' <<< "$writer_metrics")"
  writer_backlog="$(awk '$1 == "blackbox_pg_writer_backfill_remaining_seconds" { print $2 }' <<< "$writer_metrics")"
  writer_cycle_duration="$(awk '$1 == "blackbox_pg_writer_cycle_duration_seconds" { print $2 }' <<< "$writer_metrics")"
  raw_estimated_rows="$(awk '$1 == "blackbox_pg_writer_raw_estimated_rows" { print $2 }' <<< "$writer_metrics")"
  raw_table_bytes="$(awk '$1 == "blackbox_pg_writer_raw_table_bytes" { print $2 }' <<< "$writer_metrics")"
  raw_retention_overdue="$(awk '$1 == "blackbox_pg_writer_raw_retention_overdue_seconds" { print $2 }' <<< "$writer_metrics")"
  yesterday_expected="$(awk '$1 == "blackbox_pg_writer_yesterday_expected_targets" { print $2 }' <<< "$writer_metrics")"
  yesterday_missing="$(awk '$1 == "blackbox_pg_writer_yesterday_missing_kpi_targets" { print $2 }' <<< "$writer_metrics")"
  yesterday_partial="$(awk '$1 == "blackbox_pg_writer_yesterday_partial_kpi_targets" { print $2 }' <<< "$writer_metrics")"

  if [[ "$writer_cycle" == "1" && "$writer_data" == "1" && "$writer_backlog" == "0" ]]; then
    pass "Writer reports successful cycle, healthy data, and zero backlog"
  else
    fail "Writer metrics are unhealthy (cycle=${writer_cycle:-missing}, data=${writer_data:-missing}, backlog=${writer_backlog:-missing})"
  fi

  if [[ "$writer_cycle_duration" =~ ^[0-9]+([.][0-9]+)?$ ]] \
    && awk -v actual="$writer_cycle_duration" -v maximum="$BLACKBOX_WRITER_CYCLE_MAX_SECONDS" \
      'BEGIN { exit !(actual <= maximum) }'; then
    pass "Latest writer cycle completed in ${writer_cycle_duration}s"
  else
    fail "Writer cycle is too slow (${writer_cycle_duration:-missing}s; max ${BLACKBOX_WRITER_CYCLE_MAX_SECONDS}s)"
  fi

  if [[ "$raw_estimated_rows" =~ ^[0-9]+$ ]] \
    && [[ "$raw_table_bytes" =~ ^[0-9]+$ ]] \
    && (( raw_table_bytes <= BLACKBOX_RAW_TABLE_MAX_BYTES )); then
    pass "Raw storage is ${raw_estimated_rows} estimated rows / ${raw_table_bytes} bytes"
  else
    fail "Raw storage exceeds its guard or is invalid (rows=${raw_estimated_rows:-missing}, bytes=${raw_table_bytes:-missing}, max=${BLACKBOX_RAW_TABLE_MAX_BYTES})"
  fi

  if [[ "$raw_retention_overdue" =~ ^[0-9]+$ ]] \
    && (( raw_retention_overdue <= BLACKBOX_RETENTION_GRACE_SECONDS )); then
    pass "Raw retention is within its grace window (${raw_retention_overdue}s overdue)"
  else
    fail "Raw retention is behind (${raw_retention_overdue:-missing}s; grace ${BLACKBOX_RETENTION_GRACE_SECONDS}s)"
  fi

  if [[ "$yesterday_expected" =~ ^[0-9]+$ ]] \
    && (( yesterday_expected > 0 )) \
    && [[ "$yesterday_missing" == "0" ]] \
    && [[ "$yesterday_partial" == "0" ]]; then
    pass "Yesterday daily KPI is complete for ${yesterday_expected} dashboard targets"
  else
    fail "Yesterday daily KPI coverage is unhealthy (expected=${yesterday_expected:-missing}, missing=${yesterday_missing:-missing}, partial=${yesterday_partial:-missing})"
  fi
else
  fail "Writer metrics endpoint is unreachable"
fi

if (( failures > 0 )); then
  printf '\nVerification failed with %d problem(s).\n' "$failures" >&2
  exit 1
fi

printf '\nAll blackbox pipeline checks passed.\n'
