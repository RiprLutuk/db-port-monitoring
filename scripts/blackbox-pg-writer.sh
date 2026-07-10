#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

: "${ENV_FILE:=}"
: "${PROMETHEUS_URL:=http://prometheus:9090}"
: "${WRITE_INTERVAL_SECONDS:=10}"
: "${BLACKBOX_RAW_RETENTION_DAYS:=${BLACKBOX_RETENTION_DAYS:-30}}"
: "${BLACKBOX_KPI_RETENTION_DAYS:=400}"
: "${BLACKBOX_TARGET_INACTIVE_AFTER_SECONDS:=86400}"
: "${PROMETHEUS_QUERY_OVERLAP_SECONDS:=60}"
: "${PROMETHEUS_BACKFILL_CHUNK_SECONDS:=3600}"
: "${PROMETHEUS_INITIAL_BACKFILL_SECONDS:=3600}"
: "${PROMETHEUS_MAX_BACKFILL_SECONDS:=1296000}"
: "${PROMETHEUS_MAX_BACKFILL_CHUNKS_PER_CYCLE:=6}"
: "${WRITER_METRICS_PORT:=8080}"
: "${BLACKBOX_RUN_ONCE:=false}"
: "${BLACKBOX_RUN_MIGRATIONS:=false}"

load_env_file_raw "$ENV_FILE"
map_pg_env
require_pg_env

if ! positive_int "$WRITE_INTERVAL_SECONDS"; then
  log ERROR "WRITE_INTERVAL_SECONDS must be a positive integer"
  exit 1
fi

if ! positive_int "$BLACKBOX_RAW_RETENTION_DAYS"; then
  log ERROR "BLACKBOX_RAW_RETENTION_DAYS must be a positive integer"
  exit 1
fi

if ! positive_int "$BLACKBOX_KPI_RETENTION_DAYS"; then
  log ERROR "BLACKBOX_KPI_RETENTION_DAYS must be a positive integer"
  exit 1
fi

for numeric_setting in \
  PROMETHEUS_QUERY_OVERLAP_SECONDS \
  PROMETHEUS_BACKFILL_CHUNK_SECONDS \
  PROMETHEUS_INITIAL_BACKFILL_SECONDS \
  PROMETHEUS_MAX_BACKFILL_SECONDS \
  PROMETHEUS_MAX_BACKFILL_CHUNKS_PER_CYCLE \
  BLACKBOX_TARGET_INACTIVE_AFTER_SECONDS \
  WRITER_METRICS_PORT; do
  if ! positive_int "${!numeric_setting}"; then
    log ERROR "${numeric_setting} must be a positive integer"
    exit 1
  fi
done

if bool_enabled "$BLACKBOX_RUN_MIGRATIONS"; then
  "${SCRIPT_DIR}/run-psql.sh" -f /workspace/sql/001_blackbox_pg_schema.sql
fi

METRICS_DIR="/tmp/blackbox-pg-writer-metrics"
METRICS_FILE="${METRICS_DIR}/metrics"
LAST_SUCCESS_TIMESTAMP_SECONDS=0
LAST_CYCLE_SAMPLES_FETCHED=0
LAST_CYCLE_ROWS_INSERTED=0
LAST_CYCLE_BACKFILL_REMAINING_SECONDS=0
METRICS_HTTPD_PID=""

write_writer_metrics() {
  local cycle_success="$1"
  local temp_file="${METRICS_FILE}.tmp.$$"

  {
    printf '# HELP blackbox_pg_writer_cycle_success Whether the latest ingest cycle succeeded.\n'
    printf '# TYPE blackbox_pg_writer_cycle_success gauge\n'
    printf 'blackbox_pg_writer_cycle_success %s\n' "$cycle_success"
    printf '# HELP blackbox_pg_writer_last_success_timestamp_seconds Unix timestamp of the latest successful ingest cycle.\n'
    printf '# TYPE blackbox_pg_writer_last_success_timestamp_seconds gauge\n'
    printf 'blackbox_pg_writer_last_success_timestamp_seconds %s\n' "$LAST_SUCCESS_TIMESTAMP_SECONDS"
    printf '# HELP blackbox_pg_writer_samples_fetched_last_cycle Samples fetched from Prometheus in the latest cycle.\n'
    printf '# TYPE blackbox_pg_writer_samples_fetched_last_cycle gauge\n'
    printf 'blackbox_pg_writer_samples_fetched_last_cycle %s\n' "$LAST_CYCLE_SAMPLES_FETCHED"
    printf '# HELP blackbox_pg_writer_rows_inserted_last_cycle New PostgreSQL raw rows inserted in the latest cycle.\n'
    printf '# TYPE blackbox_pg_writer_rows_inserted_last_cycle gauge\n'
    printf 'blackbox_pg_writer_rows_inserted_last_cycle %s\n' "$LAST_CYCLE_ROWS_INSERTED"
    printf '# HELP blackbox_pg_writer_backfill_remaining_seconds Remaining historical backlog after the latest cycle.\n'
    printf '# TYPE blackbox_pg_writer_backfill_remaining_seconds gauge\n'
    printf 'blackbox_pg_writer_backfill_remaining_seconds %s\n' "$LAST_CYCLE_BACKFILL_REMAINING_SECONDS"
  } > "$temp_file"

  mv "$temp_file" "$METRICS_FILE"
}

start_metrics_server() {
  mkdir -p "$METRICS_DIR"
  write_writer_metrics 0
  httpd -f -p "$WRITER_METRICS_PORT" -h "$METRICS_DIR" &
  METRICS_HTTPD_PID="$!"
}

stop_metrics_server() {
  if [[ -n "$METRICS_HTTPD_PID" ]]; then
    kill "$METRICS_HTTPD_PID" 2>/dev/null || true
  fi
}

shutdown() {
  exit 0
}

fetch_metric_range() {
  local metric_name="$1"
  local lookback_seconds="$2"
  local evaluation_epoch="$3"
  local output_file="$4"
  local query encoded_query url

  query="${metric_name}{job=\"db-port-availability\"}[${lookback_seconds}s]"
  encoded_query="$(jq -nr --arg query "$query" '$query | @uri')"
  url="${PROMETHEUS_URL%/}/api/v1/query?query=${encoded_query}&time=${evaluation_epoch}"

  if ! wget -q --timeout=20 --tries=2 -O "$output_file" "$url"; then
    log ERROR "Failed to fetch ${metric_name} from Prometheus"
    return 1
  fi

  if ! jq -e '.status == "success" and (.data.result | type == "array")' "$output_file" >/dev/null; then
    log ERROR "Prometheus returned an invalid response for ${metric_name}"
    return 1
  fi
}

metrics_to_tsv() {
  local success_json="$1"
  local duration_json="$2"
  local success_tsv="$3"
  local duration_tsv="$4"
  local stage_file="$5"

  jq -r '
    .data.result[] |
    .metric as $metric |
    .values[] as $sample |
    [
      (($sample[0] * 1000) | round | tostring),
      ($metric.db_name // ""),
      ($metric.instance // ""),
      ($metric.db_type // ""),
      ($metric.env // ""),
      ($metric.criticality // ""),
      ($metric.team // ""),
      (($sample[1] | tonumber | floor) | tostring)
    ] | @tsv
  ' "$success_json" > "$success_tsv"

  jq -r '
    .data.result[] |
    .metric as $metric |
    .values[] as $sample |
    [
      (($sample[0] * 1000) | round | tostring),
      ($metric.db_name // ""),
      ($metric.instance // ""),
      (($sample[1] | tonumber) * 1000 | tostring)
    ] | @tsv
  ' "$duration_json" > "$duration_tsv"

  gawk -F '\t' 'BEGIN { OFS = "\t" }
    FNR == NR {
      duration[$1 SUBSEP $2 SUBSEP $3] = $4
      next
    }
    {
      timestamp_ms = $1
      target_name = $2
      instance = $3
      db_type = $4
      environment = $5
      criticality = $6
      team = $7
      is_up = int($8)

      host = instance
      port = ""
      if (match(instance, /:[0-9]+$/)) {
        port = substr(instance, RSTART + 1)
        host = substr(instance, 1, RSTART - 1)
      }

      if (target_name == "" || instance == "" || port == "") {
        next
      }

      key = timestamp_ms SUBSEP target_name SUBSEP instance
      latency_ms = "\\N"
      if (key in duration) {
        latency_ms = sprintf("%.6f", duration[key] + 0)
      }

      error_text = "\\N"
      if (is_up != 1) {
        error_text = "blackbox probe failed"
      }

      print timestamp_ms, target_name, db_type, environment, host, port, instance, criticality, team, is_up, latency_ms, error_text
    }
  ' "$duration_tsv" "$success_tsv" > "$stage_file"
}

latest_database_epoch() {
  local latest_epoch quoted_schema sql

  quoted_schema="${PGSCHEMA//\"/\"\"}"
  sql="SELECT coalesce(floor(extract(epoch FROM max(checked_at)))::bigint, 0) FROM \"${quoted_schema}\".db_port_blackbox_probe_results;"

  if ! latest_epoch="$("${SCRIPT_DIR}/run-psql.sh" -qAtc \
    "$sql")"; then
    log ERROR "Failed to read the latest PostgreSQL probe timestamp"
    return 1
  fi

  if [[ ! "$latest_epoch" =~ ^[0-9]+$ ]]; then
    log ERROR "PostgreSQL returned an invalid latest probe timestamp"
    return 1
  fi

  printf '%s\n' "$latest_epoch"
}

ingest_window() {
  local window_start_epoch="$1"
  local window_end_epoch="$2"
  local lookback_seconds=$((window_end_epoch - window_start_epoch))
  local success_json duration_json success_tsv duration_tsv stage_file ingest_sql
  local fetched_count stage_file_sql psql_output inserted_count

  success_json="$(mktemp)"
  duration_json="$(mktemp)"
  success_tsv="$(mktemp)"
  duration_tsv="$(mktemp)"
  stage_file="$(mktemp)"
  ingest_sql="$(mktemp)"

  cleanup_window_files() {
    rm -f "$success_json" "$duration_json" "$success_tsv" "$duration_tsv" "$stage_file" "$ingest_sql"
  }

  if ! fetch_metric_range probe_success "$lookback_seconds" "$window_end_epoch" "$success_json"; then
    cleanup_window_files
    return 1
  fi

  if ! fetch_metric_range probe_duration_seconds "$lookback_seconds" "$window_end_epoch" "$duration_json"; then
    cleanup_window_files
    return 1
  fi

  if ! metrics_to_tsv "$success_json" "$duration_json" "$success_tsv" "$duration_tsv" "$stage_file"; then
    log ERROR "Failed to convert Prometheus range samples"
    cleanup_window_files
    return 1
  fi

  fetched_count="$(wc -l < "$stage_file" | tr -d ' ')"
  if [[ "$fetched_count" -eq 0 ]]; then
    log ERROR "No blackbox probe samples found for epoch window ${window_start_epoch}-${window_end_epoch}"
    cleanup_window_files
    return 1
  fi

  stage_file_sql="${stage_file//\'/\'\'}"
  awk -v stage_file="$stage_file_sql" '{ gsub("__STAGE_FILE__", stage_file); print }' /workspace/sql/002_blackbox_pg_ingest.sql > "$ingest_sql"

  if ! psql_output="$("${SCRIPT_DIR}/run-psql.sh" \
    -qAt \
    -v raw_retention_days="$BLACKBOX_RAW_RETENTION_DAYS" \
    -v kpi_retention_days="$BLACKBOX_KPI_RETENTION_DAYS" \
    -v target_inactive_after_seconds="$BLACKBOX_TARGET_INACTIVE_AFTER_SECONDS" \
    -f "$ingest_sql")"; then
    log ERROR "PostgreSQL ingest failed for epoch window ${window_start_epoch}-${window_end_epoch}"
    cleanup_window_files
    return 1
  fi

  inserted_count="$(printf '%s\n' "$psql_output" | awk 'NF { value = $0 } END { print value }')"
  if [[ ! "$inserted_count" =~ ^[0-9]+$ ]]; then
    log ERROR "PostgreSQL ingest returned an invalid inserted row count"
    cleanup_window_files
    return 1
  fi

  WINDOW_FETCHED_COUNT="$fetched_count"
  WINDOW_INSERTED_COUNT="$inserted_count"
  cleanup_window_files
}

ingest_once() {
  local cycle_now latest_epoch backfill_floor cursor window_start window_end
  local chunk_count=0 total_fetched=0 total_inserted=0

  cycle_now="$(date -u +%s)"
  if ! latest_epoch="$(latest_database_epoch)"; then
    return 1
  fi

  backfill_floor=$((cycle_now - PROMETHEUS_MAX_BACKFILL_SECONDS))
  if (( latest_epoch == 0 )); then
    cursor=$((cycle_now - PROMETHEUS_INITIAL_BACKFILL_SECONDS))
  elif (( latest_epoch < backfill_floor )); then
    cursor="$backfill_floor"
  elif (( latest_epoch > cycle_now )); then
    cursor="$cycle_now"
  else
    cursor="$latest_epoch"
  fi

  while (( chunk_count < PROMETHEUS_MAX_BACKFILL_CHUNKS_PER_CYCLE )); do
    window_start=$((cursor - PROMETHEUS_QUERY_OVERLAP_SECONDS))
    if (( window_start < backfill_floor )); then
      window_start="$backfill_floor"
    fi

    window_end=$((cursor + PROMETHEUS_BACKFILL_CHUNK_SECONDS))
    if (( window_end > cycle_now )); then
      window_end="$cycle_now"
    fi

    if (( window_end <= window_start )); then
      window_start=$((window_end - 1))
    fi

    WINDOW_FETCHED_COUNT=0
    WINDOW_INSERTED_COUNT=0
    if ! ingest_window "$window_start" "$window_end"; then
      return 1
    fi

    total_fetched=$((total_fetched + WINDOW_FETCHED_COUNT))
    total_inserted=$((total_inserted + WINDOW_INSERTED_COUNT))
    cursor="$window_end"
    chunk_count=$((chunk_count + 1))

    if (( cursor >= cycle_now )); then
      break
    fi
  done

  LAST_CYCLE_SAMPLES_FETCHED="$total_fetched"
  LAST_CYCLE_ROWS_INSERTED="$total_inserted"
  LAST_CYCLE_BACKFILL_REMAINING_SECONDS=$((cycle_now - cursor))

  if (( LAST_CYCLE_BACKFILL_REMAINING_SECONDS > 0 )); then
    log WARN "Backfill still has ${LAST_CYCLE_BACKFILL_REMAINING_SECONDS}s remaining"
  fi

  log INFO "Fetched ${total_fetched} samples and inserted ${total_inserted} new PostgreSQL rows"
}

start_metrics_server
trap stop_metrics_server EXIT
trap shutdown INT TERM

while true; do
  cycle_start_ms="$(date +%s%3N)"
  cycle_status=0
  if ! ingest_once; then
    log ERROR "Blackbox PostgreSQL ingest failed"
    cycle_status=1
  fi

  if [[ "$cycle_status" -eq 0 ]]; then
    LAST_SUCCESS_TIMESTAMP_SECONDS="$(date -u +%s)"
    write_writer_metrics 1
  else
    write_writer_metrics 0
  fi

  if bool_enabled "$BLACKBOX_RUN_ONCE"; then
    exit "$cycle_status"
  fi

  cycle_end_ms="$(date +%s%3N)"
  elapsed_ms=$((cycle_end_ms - cycle_start_ms))
  sleep_seconds="$(awk -v interval="$WRITE_INTERVAL_SECONDS" -v elapsed_ms="$elapsed_ms" 'BEGIN { seconds = interval - (elapsed_ms / 1000); if (seconds < 1) seconds = 1; printf "%.3f", seconds }')"
  sleep "$sleep_seconds"
done
