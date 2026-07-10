#!/usr/bin/env bash
set -euo pipefail

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_FILE="${BASE_DIR}/docker-compose.yml"
WRITER_ENV_FILE="${WRITER_ENV_FILE:-.env}"
PROMETHEUS_URL="${PROMETHEUS_URL:-http://127.0.0.1:9090}"
BLACKBOX_URL="${BLACKBOX_URL:-http://127.0.0.1:9115}"
DEFAULT_TARGET="${TARGET:-db-postgres.example.com:5432}"

cd "$BASE_DIR"

compose() {
  WRITER_ENV_FILE="$WRITER_ENV_FILE" docker compose -f "$COMPOSE_FILE" "$@"
}

usage() {
  cat <<'EOF'
Usage: ./promeblackbox.sh COMMAND [OPTIONS]

Commands:
  config                    Validate docker compose config
  start                     Start prometheus, blackbox-exporter, and writer
  stop                      Stop project containers only
  restart                   Restart project containers
  status                    Show container status
  logs [service]            Follow logs. Optional service: prometheus, blackbox-exporter, blackbox-pg-writer
  build-writer              Build blackbox-pg-writer image
  validate                  Validate shell scripts and Prometheus config/rules
  reload                    Reload Prometheus config
  targets                   Show active Prometheus targets
  probe [host:port]         Run one Blackbox TCP probe
  query                     Query probe_success from Prometheus
  pg-schema                 Run PostgreSQL schema migration
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
EOF
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
    compose stop prometheus blackbox-exporter blackbox-pg-writer
    ;;

  restart)
    compose restart prometheus blackbox-exporter blackbox-pg-writer
    ;;

  status)
    compose ps
    ;;

  logs)
    if [[ $# -gt 0 ]]; then
      compose logs -f --tail=200 "$1"
    else
      compose logs -f --tail=200 prometheus blackbox-exporter blackbox-pg-writer
    fi
    ;;

  build-writer)
    docker build -t blackbox-pg-writer:latest -f Dockerfile.writer .
    ;;

  validate)
    bash -n "$0" scripts/*.sh
    for dashboard in grafana/*.json; do
      jq -e . "$dashboard" >/dev/null
    done
    compose config --quiet
    docker run --rm --entrypoint promtool \
      -v "${BASE_DIR}/prometheus:/etc/prometheus:ro" \
      prom/prometheus:latest check config /etc/prometheus/prometheus.yml
    docker run --rm --entrypoint promtool \
      -v "${BASE_DIR}/prometheus:/etc/prometheus:ro" \
      prom/prometheus:latest check rules /etc/prometheus/alert-rules.yml
    ;;

  reload)
    curl -sf -X POST "${PROMETHEUS_URL}/-/reload"
    echo "Prometheus reload requested."
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
      blackbox-pg-writer -f /workspace/sql/001_blackbox_pg_schema.sql
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
