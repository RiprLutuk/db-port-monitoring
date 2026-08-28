#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

: "${ENV_FILE:=}"
: "${PROMETHEUS_URL:=http://prometheus:9090}"
: "${WRITE_INTERVAL_SECONDS:=300}"
: "${BLACKBOX_RAW_RETENTION_DAYS:=${BLACKBOX_RETENTION_DAYS:-30}}"
: "${BLACKBOX_REPORT_RETENTION_DAYS:=2192}"
: "${BLACKBOX_RETENTION_DELETE_BATCH_SIZE:=10000}"
: "${BLACKBOX_TARGET_INACTIVE_AFTER_SECONDS:=86400}"
: "${PROMETHEUS_QUERY_OVERLAP_SECONDS:=180}"
: "${PROMETHEUS_BACKFILL_CHUNK_SECONDS:=3600}"
: "${PROMETHEUS_INITIAL_BACKFILL_SECONDS:=3600}"
: "${PROMETHEUS_MAX_BACKFILL_SECONDS:=1296000}"
: "${PROMETHEUS_MAX_BACKFILL_CHUNKS_PER_CYCLE:=6}"
: "${WRITER_STATE_NAME:=prometheus-blackbox}"
: "${WRITER_METRICS_PORT:=8080}"
: "${BLACKBOX_DATA_FRESHNESS_SECONDS:=900}"
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

if ! positive_int "$BLACKBOX_REPORT_RETENTION_DAYS"; then
  log ERROR "BLACKBOX_REPORT_RETENTION_DAYS must be a positive integer"
  exit 1
fi

for numeric_setting in \
  PROMETHEUS_QUERY_OVERLAP_SECONDS \
  PROMETHEUS_BACKFILL_CHUNK_SECONDS \
  PROMETHEUS_INITIAL_BACKFILL_SECONDS \
  PROMETHEUS_MAX_BACKFILL_SECONDS \
  PROMETHEUS_MAX_BACKFILL_CHUNKS_PER_CYCLE \
  BLACKBOX_RETENTION_DELETE_BATCH_SIZE \
  BLACKBOX_TARGET_INACTIVE_AFTER_SECONDS \
  BLACKBOX_DATA_FRESHNESS_SECONDS \
  WRITER_METRICS_PORT; do
  if ! positive_int "${!numeric_setting}"; then
    log ERROR "${numeric_setting} must be a positive integer"
    exit 1
  fi
done

if [[ ! "$WRITER_STATE_NAME" =~ ^[A-Za-z0-9._:-]+$ ]]; then
  log ERROR "WRITER_STATE_NAME may contain only letters, numbers, dot, underscore, colon, and dash"
  exit 1
fi

if bool_enabled "$BLACKBOX_RUN_MIGRATIONS"; then
  "${SCRIPT_DIR}/run-psql.sh" -f /workspace/sql/001_blackbox_pg_schema.sql
  "${SCRIPT_DIR}/run-psql.sh" -f /workspace/sql/004_normalize_environment.sql
  "${SCRIPT_DIR}/run-psql.sh" -f /workspace/sql/005_kpi_only_cleanup.sql
  "${SCRIPT_DIR}/run-psql.sh" -f /workspace/sql/008_outage_events.sql
  "${SCRIPT_DIR}/run-psql.sh" -f /workspace/sql/012_storage_scalability_guards.sql
fi

METRICS_DIR="/tmp/blackbox-pg-writer-metrics"
METRICS_FILE="${METRICS_DIR}/metrics"
LAST_SUCCESS_TIMESTAMP_SECONDS=0
LAST_CYCLE_SAMPLES_FETCHED=0
LAST_CYCLE_ROWS_INSERTED=0
LAST_CYCLE_BACKFILL_REMAINING_SECONDS=0
LAST_CYCLE_EMPTY_WINDOWS=0
LAST_CYCLE_DURATION_SECONDS=0
LATEST_PROBE_TIMESTAMP_SECONDS=0
CHECKPOINT_TIMESTAMP_SECONDS=0
ACTIVE_TARGET_COUNT=0
RECENT_TARGET_COUNT=0
MISSING_RECENT_TARGET_COUNT=0
RAW_ESTIMATED_ROWS=0
RAW_TABLE_BYTES=0
RAW_RETENTION_OVERDUE_SECONDS=0
YESTERDAY_EXPECTED_TARGET_COUNT=0
YESTERDAY_MISSING_KPI_TARGET_COUNT=0
YESTERDAY_PARTIAL_KPI_TARGET_COUNT=0
METRICS_HTTPD_PID=""

write_writer_metrics() {
  local cycle_success="$1"
  local data_healthy=0 now_epoch
  local temp_file="${METRICS_FILE}.tmp.$$"

  now_epoch="$(date -u +%s)"
  if [[ "$cycle_success" -eq 1 ]] \
    && (( ACTIVE_TARGET_COUNT > 0 )) \
    && (( MISSING_RECENT_TARGET_COUNT == 0 )) \
    && (( LATEST_PROBE_TIMESTAMP_SECONDS > 0 )) \
    && (( now_epoch - LATEST_PROBE_TIMESTAMP_SECONDS <= BLACKBOX_DATA_FRESHNESS_SECONDS )); then
    data_healthy=1
  fi

  {
    printf '# HELP blackbox_pg_writer_cycle_success Whether the latest ingest cycle succeeded.\n'
    printf '# TYPE blackbox_pg_writer_cycle_success gauge\n'
    printf 'blackbox_pg_writer_cycle_success %s\n' "$cycle_success"
    printf '# HELP blackbox_pg_writer_data_healthy Whether PostgreSQL probe data is fresh and complete for active targets.\n'
    printf '# TYPE blackbox_pg_writer_data_healthy gauge\n'
    printf 'blackbox_pg_writer_data_healthy %s\n' "$data_healthy"
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
    printf '# HELP blackbox_pg_writer_empty_windows_last_cycle Empty Prometheus source windows skipped in the latest cycle.\n'
    printf '# TYPE blackbox_pg_writer_empty_windows_last_cycle gauge\n'
    printf 'blackbox_pg_writer_empty_windows_last_cycle %s\n' "$LAST_CYCLE_EMPTY_WINDOWS"
    printf '# HELP blackbox_pg_writer_cycle_duration_seconds Duration of the latest complete writer cycle.\n'
    printf '# TYPE blackbox_pg_writer_cycle_duration_seconds gauge\n'
    printf 'blackbox_pg_writer_cycle_duration_seconds %s\n' "$LAST_CYCLE_DURATION_SECONDS"
    printf '# HELP blackbox_pg_writer_interval_seconds Configured interval between writer cycle starts.\n'
    printf '# TYPE blackbox_pg_writer_interval_seconds gauge\n'
    printf 'blackbox_pg_writer_interval_seconds %s\n' "$WRITE_INTERVAL_SECONDS"
    printf '# HELP blackbox_pg_writer_latest_probe_timestamp_seconds Unix timestamp of the newest probe stored in PostgreSQL.\n'
    printf '# TYPE blackbox_pg_writer_latest_probe_timestamp_seconds gauge\n'
    printf 'blackbox_pg_writer_latest_probe_timestamp_seconds %s\n' "$LATEST_PROBE_TIMESTAMP_SECONDS"
    printf '# HELP blackbox_pg_writer_checkpoint_timestamp_seconds Unix timestamp of the durable processed-source cursor.\n'
    printf '# TYPE blackbox_pg_writer_checkpoint_timestamp_seconds gauge\n'
    printf 'blackbox_pg_writer_checkpoint_timestamp_seconds %s\n' "$CHECKPOINT_TIMESTAMP_SECONDS"
    printf '# HELP blackbox_pg_writer_active_targets Active targets registered in PostgreSQL.\n'
    printf '# TYPE blackbox_pg_writer_active_targets gauge\n'
    printf 'blackbox_pg_writer_active_targets %s\n' "$ACTIVE_TARGET_COUNT"
    printf '# HELP blackbox_pg_writer_recent_targets Active targets with a probe in the last ten minutes.\n'
    printf '# TYPE blackbox_pg_writer_recent_targets gauge\n'
    printf 'blackbox_pg_writer_recent_targets %s\n' "$RECENT_TARGET_COUNT"
    printf '# HELP blackbox_pg_writer_missing_recent_targets Active targets without a probe in the last ten minutes.\n'
    printf '# TYPE blackbox_pg_writer_missing_recent_targets gauge\n'
    printf 'blackbox_pg_writer_missing_recent_targets %s\n' "$MISSING_RECENT_TARGET_COUNT"
    printf '# HELP blackbox_pg_writer_raw_estimated_rows PostgreSQL estimated live rows in rolling raw probe history.\n'
    printf '# TYPE blackbox_pg_writer_raw_estimated_rows gauge\n'
    printf 'blackbox_pg_writer_raw_estimated_rows %s\n' "$RAW_ESTIMATED_ROWS"
    printf '# HELP blackbox_pg_writer_raw_table_bytes Total PostgreSQL bytes used by the raw table and its indexes.\n'
    printf '# TYPE blackbox_pg_writer_raw_table_bytes gauge\n'
    printf 'blackbox_pg_writer_raw_table_bytes %s\n' "$RAW_TABLE_BYTES"
    printf '# HELP blackbox_pg_writer_raw_retention_overdue_seconds Age beyond the configured raw retention boundary.\n'
    printf '# TYPE blackbox_pg_writer_raw_retention_overdue_seconds gauge\n'
    printf 'blackbox_pg_writer_raw_retention_overdue_seconds %s\n' "$RAW_RETENTION_OVERDUE_SECONDS"
    printf '# HELP blackbox_pg_writer_yesterday_expected_targets Non-excluded active targets expected in yesterday daily KPI.\n'
    printf '# TYPE blackbox_pg_writer_yesterday_expected_targets gauge\n'
    printf 'blackbox_pg_writer_yesterday_expected_targets %s\n' "$YESTERDAY_EXPECTED_TARGET_COUNT"
    printf '# HELP blackbox_pg_writer_yesterday_missing_kpi_targets Expected targets without a daily KPI row for yesterday.\n'
    printf '# TYPE blackbox_pg_writer_yesterday_missing_kpi_targets gauge\n'
    printf 'blackbox_pg_writer_yesterday_missing_kpi_targets %s\n' "$YESTERDAY_MISSING_KPI_TARGET_COUNT"
    printf '# HELP blackbox_pg_writer_yesterday_partial_kpi_targets Expected targets whose yesterday daily KPI does not contain 288 five-minute probes.\n'
    printf '# TYPE blackbox_pg_writer_yesterday_partial_kpi_targets gauge\n'
    printf 'blackbox_pg_writer_yesterday_partial_kpi_targets %s\n' "$YESTERDAY_PARTIAL_KPI_TARGET_COUNT"
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
    (($metric.env // "") | ascii_downcase) as $environment |
    [
      (($sample[0] * 1000) | round | tostring),
      ($metric.db_name // ""),
      ($metric.instance // ""),
      ($metric.db_type // ""),
      (if $environment == "qa" or $environment == "uat" or $environment == "development" then "dev" else $environment end),
      ($metric.criticality // ""),
      ($metric.team // ""),
      (if (($metric.monitoring_excluded // "false") | ascii_downcase) == "true" then "true" else "false" end),
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
      monitoring_excluded = $8
      is_up = int($9)

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

      print timestamp_ms, target_name, db_type, environment, host, port, instance, criticality, team, monitoring_excluded, is_up, latency_ms, error_text
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

latest_checkpoint_epoch() {
  local checkpoint_epoch quoted_schema sql

  quoted_schema="${PGSCHEMA//\"/\"\"}"
  sql="SELECT coalesce(floor(extract(epoch FROM cursor_at))::bigint, 0) FROM \"${quoted_schema}\".db_port_blackbox_writer_state WHERE writer_name = '${WRITER_STATE_NAME}';"

  if ! checkpoint_epoch="$("${SCRIPT_DIR}/run-psql.sh" -qAtc "$sql")"; then
    log ERROR "Failed to read the durable writer checkpoint"
    return 1
  fi

  checkpoint_epoch="${checkpoint_epoch:-0}"
  if [[ ! "$checkpoint_epoch" =~ ^[0-9]+$ ]]; then
    log ERROR "PostgreSQL returned an invalid writer checkpoint"
    return 1
  fi

  printf '%s\n' "$checkpoint_epoch"
}

persist_checkpoint_epoch() {
  local checkpoint_epoch="$1"
  local quoted_schema sql

  if [[ ! "$checkpoint_epoch" =~ ^[0-9]+$ ]]; then
    log ERROR "Refusing to persist an invalid writer checkpoint"
    return 1
  fi

  quoted_schema="${PGSCHEMA//\"/\"\"}"
  sql="INSERT INTO \"${quoted_schema}\".db_port_blackbox_writer_state AS state (writer_name, cursor_at, updated_at) VALUES ('${WRITER_STATE_NAME}', to_timestamp(${checkpoint_epoch}), now()) ON CONFLICT (writer_name) DO UPDATE SET cursor_at = greatest(state.cursor_at, EXCLUDED.cursor_at), updated_at = now();"

  if ! "${SCRIPT_DIR}/run-psql.sh" -qAtc "$sql" >/dev/null; then
    log ERROR "Failed to persist writer checkpoint ${checkpoint_epoch}"
    return 1
  fi
}

refresh_database_health_metrics() {
  local quoted_schema sql health_row latest_probe active recent missing checkpoint
  local raw_estimated_rows raw_table_bytes raw_retention_overdue
  local yesterday_expected yesterday_missing yesterday_partial

  quoted_schema="${PGSCHEMA//\"/\"\"}"
  sql="WITH target_day AS (SELECT ((now() AT TIME ZONE 'Asia/Jakarta')::date - 1) AS day), expected_targets AS (SELECT target.target_name FROM \"${quoted_schema}\".db_port_blackbox_targets target CROSS JOIN target_day WHERE target.is_active = true AND target.monitoring_excluded = false AND (target.first_seen_at AT TIME ZONE 'Asia/Jakarta')::date <= target_day.day), coverage AS (SELECT expected.target_name, daily.target_name AS daily_target_name, daily.probes FROM expected_targets expected CROSS JOIN target_day LEFT JOIN \"${quoted_schema}\".db_port_blackbox_daily_kpi daily ON daily.target_name = expected.target_name AND daily.period_start = target_day.day), daily_health AS (SELECT count(*)::bigint AS expected_target_count, count(*) FILTER (WHERE daily_target_name IS NULL)::bigint AS missing_target_count, count(*) FILTER (WHERE daily_target_name IS NOT NULL AND probes <> 288)::bigint AS partial_target_count FROM coverage) SELECT coalesce(floor(extract(epoch FROM health.latest_checked_at))::bigint, 0), health.active_target_count, health.recent_target_count, health.missing_recent_target_count, coalesce(floor(extract(epoch FROM state.cursor_at))::bigint, 0), coalesce((SELECT greatest(n_live_tup::bigint, 0) FROM pg_stat_user_tables WHERE relid = '\"${quoted_schema}\".db_port_blackbox_probe_results'::regclass), 0), pg_total_relation_size('\"${quoted_schema}\".db_port_blackbox_probe_results'::regclass)::bigint, coalesce(greatest(floor(extract(epoch FROM ((now() - interval '${BLACKBOX_RAW_RETENTION_DAYS} days') - (SELECT min(checked_at) FROM \"${quoted_schema}\".db_port_blackbox_probe_results))))::bigint, 0), 0), daily_health.expected_target_count, daily_health.missing_target_count, daily_health.partial_target_count FROM \"${quoted_schema}\".db_port_blackbox_ingest_health health LEFT JOIN \"${quoted_schema}\".db_port_blackbox_writer_state state ON state.writer_name = '${WRITER_STATE_NAME}' CROSS JOIN daily_health;"

  if ! health_row="$("${SCRIPT_DIR}/run-psql.sh" -qAtc "$sql")"; then
    log ERROR "Failed to read PostgreSQL ingest health"
    return 1
  fi

  IFS='|' read -r latest_probe active recent missing checkpoint \
    raw_estimated_rows raw_table_bytes raw_retention_overdue \
    yesterday_expected yesterday_missing yesterday_partial <<< "$health_row"
  for health_value in \
    "$latest_probe" "$active" "$recent" "$missing" "$checkpoint" \
    "$raw_estimated_rows" "$raw_table_bytes" "$raw_retention_overdue" \
    "$yesterday_expected" "$yesterday_missing" "$yesterday_partial"; do
    if [[ ! "$health_value" =~ ^[0-9]+$ ]]; then
      log ERROR "PostgreSQL returned invalid ingest health values"
      return 1
    fi
  done

  LATEST_PROBE_TIMESTAMP_SECONDS="$latest_probe"
  ACTIVE_TARGET_COUNT="$active"
  RECENT_TARGET_COUNT="$recent"
  MISSING_RECENT_TARGET_COUNT="$missing"
  CHECKPOINT_TIMESTAMP_SECONDS="$checkpoint"
  RAW_ESTIMATED_ROWS="$raw_estimated_rows"
  RAW_TABLE_BYTES="$raw_table_bytes"
  RAW_RETENTION_OVERDUE_SECONDS="$raw_retention_overdue"
  YESTERDAY_EXPECTED_TARGET_COUNT="$yesterday_expected"
  YESTERDAY_MISSING_KPI_TARGET_COUNT="$yesterday_missing"
  YESTERDAY_PARTIAL_KPI_TARGET_COUNT="$yesterday_partial"
}

ingest_window() {
  local window_start_epoch="$1"
  local window_end_epoch="$2"
  local lookback_seconds=$((window_end_epoch - window_start_epoch))
  local success_json duration_json success_tsv duration_tsv stage_file ingest_sql
  local source_sample_count fetched_count duplicate_key endpoint_changes
  local stage_file_sql psql_output inserted_count

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

  if ! jq -e '
    [.data.result[].values[] | (.[1] | tonumber) | select(. != 0 and . != 1)]
    | length == 0
  ' "$success_json" >/dev/null; then
    log ERROR "Prometheus returned a probe_success value other than 0 or 1"
    cleanup_window_files
    return 1
  fi

  if ! jq -e '
    [
      .data.result[].metric |
      ((.env // "") | ascii_downcase) as $environment |
      select(
        (.db_name // "") == "" or
        (.instance // "") == "" or
        (.db_type // "") == "" or
        ($environment != "dev" and
         $environment != "prod" and
         $environment != "qa" and
         $environment != "uat" and
         $environment != "development")
      )
    ] | length == 0
  ' "$success_json" >/dev/null; then
    log ERROR "Prometheus returned a target with missing labels or an environment outside dev/prod"
    cleanup_window_files
    return 1
  fi

  if ! jq -e '
    [
      .data.result[] |
      select((.values | length) > 0) |
      {
        target: .metric.db_name,
        instance: .metric.instance,
        first: (.values[0][0] | tonumber),
        last: (.values[-1][0] | tonumber)
      }
    ]
    | group_by(.target)
    | map(
        . as $series |
        [
          range(0; $series | length) as $left |
          range($left + 1; $series | length) as $right |
          select(
            $series[$left].instance != $series[$right].instance and
            $series[$left].first <= $series[$right].last and
            $series[$right].first <= $series[$left].last
          )
        ] | length
      )
    | (add // 0) == 0
  ' "$success_json" >/dev/null; then
    log ERROR "A db_name has overlapping instances in Prometheus"
    cleanup_window_files
    return 1
  fi

  endpoint_changes="$(jq -r '
    [
      .data.result[].metric |
      {target: .db_name, instance: .instance}
    ]
    | unique_by([.target, .instance])
    | group_by(.target)
    | map(select(length > 1) | .[0].target)
    | join(", ")
  ' "$success_json")"
  if [[ -n "$endpoint_changes" ]]; then
    log WARN "Sequential endpoint change detected for db_name: ${endpoint_changes}"
  fi

  source_sample_count="$(jq '[.data.result[].values[]] | length' "$success_json")"
  fetched_count="$(wc -l < "$stage_file" | tr -d ' ')"
  if [[ ! "$source_sample_count" =~ ^[0-9]+$ || ! "$fetched_count" =~ ^[0-9]+$ ]]; then
    log ERROR "Unable to count Prometheus or staged probe samples"
    cleanup_window_files
    return 1
  fi

  if [[ "$fetched_count" -ne "$source_sample_count" ]]; then
    log ERROR "Converted ${fetched_count} of ${source_sample_count} probe_success samples; check db_name and instance labels"
    cleanup_window_files
    return 1
  fi

  if [[ "$fetched_count" -eq 0 ]]; then
    # A real Prometheus scrape gap must not pin recovery to the same empty
    # window forever. Advance the in-memory cursor without fabricating rows;
    # the next chunk can then ingest samples that resumed after the gap.
    WINDOW_FETCHED_COUNT=0
    WINDOW_INSERTED_COUNT=0
    log WARN "No blackbox probe samples found for epoch window ${window_start_epoch}-${window_end_epoch}; skipping empty source window"
    cleanup_window_files
    return 0
  fi

  duplicate_key="$(
    awk -F '\t' '{ print $1 "\t" $2 }' "$stage_file" \
      | LC_ALL=C sort \
      | uniq -d \
      | sed -n '1p'
  )"
  if [[ -n "$duplicate_key" ]]; then
    log ERROR "Duplicate PostgreSQL probe key in source window: ${duplicate_key}"
    cleanup_window_files
    return 1
  fi

  stage_file_sql="${stage_file//\'/\'\'}"
  awk -v stage_file="$stage_file_sql" '{ gsub("__STAGE_FILE__", stage_file); print }' /workspace/sql/002_blackbox_pg_ingest.sql > "$ingest_sql"

  if ! psql_output="$("${SCRIPT_DIR}/run-psql.sh" \
    -qAt \
    -v raw_retention_days="$BLACKBOX_RAW_RETENTION_DAYS" \
    -v report_retention_days="$BLACKBOX_REPORT_RETENTION_DAYS" \
    -v retention_delete_batch_size="$BLACKBOX_RETENTION_DELETE_BATCH_SIZE" \
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
  local cycle_now latest_epoch checkpoint_epoch backfill_floor cursor window_start window_end
  local chunk_count=0 total_fetched=0 total_inserted=0

  cycle_now="$(date -u +%s)"
  if ! latest_epoch="$(latest_database_epoch)"; then
    return 1
  fi
  if ! checkpoint_epoch="$(latest_checkpoint_epoch)"; then
    return 1
  fi

  backfill_floor=$((cycle_now - PROMETHEUS_MAX_BACKFILL_SECONDS))
  if (( latest_epoch == 0 && checkpoint_epoch == 0 )); then
    cursor=$((cycle_now - PROMETHEUS_INITIAL_BACKFILL_SECONDS))
  elif (( latest_epoch > checkpoint_epoch )); then
    cursor="$latest_epoch"
  else
    cursor="$checkpoint_epoch"
  fi

  if (( cursor < backfill_floor )); then
    cursor="$backfill_floor"
  elif (( cursor > cycle_now )); then
    cursor="$cycle_now"
  fi

  CHECKPOINT_TIMESTAMP_SECONDS="$checkpoint_epoch"
  LAST_CYCLE_EMPTY_WINDOWS=0

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
    if (( WINDOW_FETCHED_COUNT == 0 )); then
      LAST_CYCLE_EMPTY_WINDOWS=$((LAST_CYCLE_EMPTY_WINDOWS + 1))
    fi

    if ! persist_checkpoint_epoch "$window_end"; then
      return 1
    fi

    cursor="$window_end"
    CHECKPOINT_TIMESTAMP_SECONDS="$cursor"
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

  if ! refresh_database_health_metrics; then
    return 1
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

  cycle_end_ms="$(date +%s%3N)"
  elapsed_ms=$((cycle_end_ms - cycle_start_ms))
  LAST_CYCLE_DURATION_SECONDS="$(awk -v elapsed_ms="$elapsed_ms" 'BEGIN { printf "%.3f", elapsed_ms / 1000 }')"

  if [[ "$cycle_status" -eq 0 ]]; then
    LAST_SUCCESS_TIMESTAMP_SECONDS="$(date -u +%s)"
    write_writer_metrics 1
  else
    write_writer_metrics 0
  fi

  if bool_enabled "$BLACKBOX_RUN_ONCE"; then
    exit "$cycle_status"
  fi

  sleep_seconds="$(awk -v interval="$WRITE_INTERVAL_SECONDS" -v elapsed_ms="$elapsed_ms" 'BEGIN { seconds = interval - (elapsed_ms / 1000); if (seconds < 1) seconds = 1; printf "%.3f", seconds }')"
  sleep "$sleep_seconds"
done
