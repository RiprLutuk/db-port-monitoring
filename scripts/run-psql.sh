#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

: "${ENV_FILE:=}"

load_env_file_raw "$ENV_FILE"
map_pg_env
require_pg_env

exec psql \
  -X \
  -v ON_ERROR_STOP=1 \
  -h "$PGHOST" \
  -p "$PGPORT" \
  -U "$PGUSER" \
  -d "$PGDATABASE" \
  -v schema_name="$PGSCHEMA" \
  "$@"

