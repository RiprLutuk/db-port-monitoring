#!/usr/bin/env bash
set -euo pipefail

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_FILE="${BASE_DIR}/docker-compose.yml"
WRITER_ENV_FILE="${WRITER_ENV_FILE:-.env}"
PROMETHEUS_URL="${PROMETHEUS_URL:-http://127.0.0.1:9090}"
ALERTMANAGER_URL="${ALERTMANAGER_URL:-http://127.0.0.1:9093}"
BLACKBOX_URL="${BLACKBOX_URL:-http://127.0.0.1:9115}"
DEFAULT_TARGET="${TARGET:-db-postgres.example.com:5432}"
PROMETHEUS_IMAGE="${PROMETHEUS_IMAGE:-prom/prometheus:v3.13.0}"

cd "$BASE_DIR"

compose() {
  WRITER_ENV_FILE="$WRITER_ENV_FILE" docker compose -f "$COMPOSE_FILE" "$@"
}

usage() {
  cat <<'EOF'
Usage: ./promeblackbox.sh COMMAND [OPTIONS]

Commands:
  config                    Validate docker compose config
  start                     Start Alertmanager, Prometheus, Blackbox Exporter, and writer
  stop                      Stop project containers only
  restart                   Restart project containers
  status                    Show container status
  logs [service]            Follow logs. Optional service: alertmanager, prometheus, blackbox-exporter, blackbox-pg-writer
  build-writer              Build blackbox-pg-writer image
  validate                  Validate shell scripts and Prometheus config/rules
  verify                    Verify live Prometheus-to-PostgreSQL completeness
  reload                    Reload Prometheus config
  deploy-grafana-alerts [--dry-run]
                            Generate, validate, and deploy Grafana alert provisioning
  targets                   Show active Prometheus targets
  probe [host:port]         Run one Blackbox TCP probe
  query                     Query probe_success from Prometheus
  pg-schema                 Run PostgreSQL schema and outage-event migrations
  outage-events             Create/backfill compact downtime events
  storage-guards            Apply bounded-growth PostgreSQL maintenance settings
  normalize-environment     Normalize legacy QA/UAT rows to DEV
  normalize-5m              Normalize existing raw history and KPI to 5-minute buckets
  cleanup-unused            Drop tables not used by active dashboards
  writer-start              Recreate/start writer only
  writer-stop               Stop writer only
  writer-restart            Restart writer only
  writer-logs               Follow writer logs
  writer-run-once           Run writer once
  writer-query              Query SQL raw row count and time range

Examples:
  ./promeblackbox.sh validate
  ./promeblackbox.sh start
  ./promeblackbox.sh probe db-postgres.example.com:5432
  ./promeblackbox.sh deploy-grafana-alerts --dry-run
EOF
}

deploy_grafana_alerts() {
  local dry_run=false
  local deploy_env_file source_dir target_dir compose_file
  local -a alert_files=() changed_files=()

  if [[ "${1:-}" == "--dry-run" ]]; then
    dry_run=true
    shift
  fi
  if [[ $# -gt 0 ]]; then
    echo "Unknown deploy-grafana-alerts option: $1" >&2
    return 2
  fi

  deploy_env_file="${GRAFANA_DEPLOY_ENV_FILE:-$WRITER_ENV_FILE}"
  if [[ "$deploy_env_file" != /* ]]; then
    deploy_env_file="$BASE_DIR/$deploy_env_file"
  fi
  if [[ -f "$deploy_env_file" ]]; then
    # Parse only KEY=VALUE lines; never execute a local environment file as shell.
    # shellcheck source=scripts/common.sh
    source "$BASE_DIR/scripts/common.sh"
    load_env_file_raw "$deploy_env_file"
  fi

  : "${GRAFANA_PROJECT_DIR:?Set GRAFANA_PROJECT_DIR in .env or the environment.}"
  source_dir="${GRAFANA_ALERTING_SOURCE_DIR:-$BASE_DIR/grafana/provisioning/alerting}"
  target_dir="$GRAFANA_PROJECT_DIR/provisioning/alerting"
  compose_file="${GRAFANA_COMPOSE_FILE:-$GRAFANA_PROJECT_DIR/docker-compose.yml}"
  alert_files=(mssql-all-paused.yml mssql-bmgcp-011-qa-pilot.yml)

  [[ -d "$source_dir" ]] || { echo "Missing alert source directory: $source_dir" >&2; return 1; }
  [[ -d "$target_dir" ]] || { echo "Missing Grafana alert directory: $target_dir" >&2; return 1; }
  [[ -f "$compose_file" ]] || { echo "Missing Grafana compose file: $compose_file" >&2; return 1; }

  if [[ ! -f "$BASE_DIR/scripts/generate_mssql_grafana_rules.py" ]]; then
    echo "Missing private MSSQL rule generator: scripts/generate_mssql_grafana_rules.py" >&2
    echo "Provide a deployment-specific generator and alert source directory first." >&2
    return 1
  fi
  python3 "$BASE_DIR/scripts/generate_mssql_grafana_rules.py"
  python3 -c 'import sys, yaml; [yaml.safe_load(open(path, encoding="utf-8")) for path in sys.argv[1:]]' \
    "$source_dir/${alert_files[0]}" "$source_dir/${alert_files[1]}"

  for alert_file in "${alert_files[@]}"; do
    if cmp -s "$source_dir/$alert_file" "$target_dir/$alert_file"; then
      echo "Unchanged: $alert_file"
    else
      changed_files+=("$alert_file")
    fi
  done

  if [[ ${#changed_files[@]} -eq 0 ]]; then
    echo "Grafana alert provisioning is already up to date; no restart needed."
    return 0
  fi

  printf 'Changed provisioning files:\n'
  printf ' - %s\n' "${changed_files[@]}"
  if [[ "$dry_run" == true ]]; then
    echo "Dry run only; Grafana was not changed."
    return 0
  fi

  for alert_file in "${changed_files[@]}"; do
    sudo install -m 0644 "$source_dir/$alert_file" "$target_dir/$alert_file"
  done
  sudo docker compose -f "$compose_file" restart grafana
  echo "Grafana alert provisioning deployed. Grafana alert timers start fresh after the restart."
}

cmd="${1:-help}"
shift || true

case "$cmd" in
  config)
    compose config --quiet
    ;;

  start)
    compose up -d
    compose ps
    ;;

  stop)
    compose stop alertmanager prometheus blackbox-exporter blackbox-pg-writer
    ;;

  restart)
    compose restart alertmanager prometheus blackbox-exporter blackbox-pg-writer
    ;;

  status)
    compose ps
    ;;

  logs)
    if [[ $# -gt 0 ]]; then
      compose logs -f --tail=200 "$1"
    else
      compose logs -f --tail=200 alertmanager prometheus blackbox-exporter blackbox-pg-writer
    fi
    ;;

  build-writer)
    DOCKER_BUILDKIT=0 docker build -t blackbox-pg-writer:latest -f Dockerfile.writer .
    ;;

  validate)
    bash -n "$0" scripts/*.sh
    for dashboard in grafana/*.json; do
      jq -e . "$dashboard" >/dev/null
    done
    compose config --quiet
    docker run --rm --entrypoint promtool \
      -v "${BASE_DIR}/prometheus:/etc/prometheus:ro" \
      "$PROMETHEUS_IMAGE" check config /etc/prometheus/prometheus.yml
    docker run --rm --entrypoint promtool \
      -v "${BASE_DIR}/prometheus:/etc/prometheus:ro" \
      "$PROMETHEUS_IMAGE" check rules /etc/prometheus/alert-rules.yml
    compose run --rm --no-deps --entrypoint /bin/amtool \
      alertmanager check-config /etc/alertmanager/alertmanager.yml
    ;;

  verify)
    compose run --rm --no-deps \
      --entrypoint /workspace/scripts/verify-blackbox-pipeline.sh \
      blackbox-pg-writer
    ;;

  reload)
    curl -sf -X POST "${PROMETHEUS_URL}/-/reload"
    curl -sf -X POST "${ALERTMANAGER_URL}/-/reload"
    echo "Prometheus and Alertmanager reload requested."
    ;;

  deploy-grafana-alerts)
    deploy_grafana_alerts "$@"
    ;;

  targets)
    curl -sf "${PROMETHEUS_URL}/api/v1/targets?state=active"
    ;;

  probe)
    target="${1:-$DEFAULT_TARGET}"
    curl -sf "${BLACKBOX_URL}/probe?target=${target}&module=tcp_connect" \
      | grep -E "^(probe_success|probe_duration_seconds)"
    ;;

  query)
    curl -sfG "${PROMETHEUS_URL}/api/v1/query" \
      --data-urlencode 'query=probe_success{job="db-port-availability"}'
    ;;

  pg-schema)
    compose run --rm --no-deps \
      --entrypoint /workspace/scripts/run-psql.sh \
      blackbox-pg-writer \
      -f /workspace/sql/001_blackbox_pg_schema.sql \
      -f /workspace/sql/008_outage_events.sql \
      -f /workspace/sql/012_storage_scalability_guards.sql
    ;;

  outage-events)
    compose run --rm --no-deps \
      --entrypoint /workspace/scripts/run-psql.sh \
      blackbox-pg-writer -f /workspace/sql/008_outage_events.sql
    ;;

  storage-guards)
    compose run --rm --no-deps \
      --entrypoint /workspace/scripts/run-psql.sh \
      blackbox-pg-writer -f /workspace/sql/012_storage_scalability_guards.sql
    ;;

  normalize-environment)
    compose run --rm --no-deps \
      --entrypoint /workspace/scripts/run-psql.sh \
      blackbox-pg-writer -f /workspace/sql/004_normalize_environment.sql
    ;;

  normalize-5m)
    if compose ps --status running --services | grep -qx 'blackbox-pg-writer'; then
      echo "Stop blackbox-pg-writer before normalizing historical data." >&2
      exit 1
    fi
    compose run --rm --no-deps \
      --entrypoint /workspace/scripts/run-psql.sh \
      blackbox-pg-writer -f /workspace/sql/006_normalize_history_to_five_minutes.sql
    ;;

  cleanup-unused)
    if compose ps --status running --services | grep -qx 'blackbox-pg-writer'; then
      echo "Stop blackbox-pg-writer before dropping unused KPI tables." >&2
      exit 1
    fi
    compose run --rm --no-deps \
      --entrypoint /workspace/scripts/run-psql.sh \
      blackbox-pg-writer -f /workspace/sql/005_kpi_only_cleanup.sql
    ;;

  writer-start)
    compose up -d --force-recreate blackbox-pg-writer
    ;;

  writer-stop)
    compose stop blackbox-pg-writer
    ;;

  writer-restart)
    compose restart blackbox-pg-writer
    ;;

  writer-logs)
    compose logs -f --tail=200 blackbox-pg-writer
    ;;

  writer-run-once)
    compose run --rm --no-deps \
      --entrypoint /workspace/scripts/blackbox-pg-writer.sh \
      -e BLACKBOX_RUN_ONCE=true \
      blackbox-pg-writer
    ;;

  writer-query)
    compose run --rm --no-deps \
      --entrypoint /workspace/scripts/run-psql.sh \
      blackbox-pg-writer -Atc \
      "SELECT count(*) AS rows, min(checked_at), max(checked_at) FROM monitoring.db_port_blackbox_probe_results;"
    ;;

  help|-h|--help)
    usage
    ;;

  *)
    echo "Unknown command: $cmd" >&2
    echo >&2
    usage >&2
    exit 1
    ;;
esac
