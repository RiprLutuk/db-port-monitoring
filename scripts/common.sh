#!/usr/bin/env bash

log() {
  local level="$1"
  shift
  printf '%s [%s] %s\n' "$(date -Iseconds)" "$level" "$*"
}

load_file_env() {
  local var_name="$1"
  local file_var_name="${var_name}_FILE"
  local file_path="${!file_var_name:-}"

  if [[ -z "$file_path" ]]; then
    return 0
  fi

  if [[ ! -f "$file_path" ]]; then
    log ERROR "${file_var_name} points to missing file: ${file_path}"
    return 1
  fi

  export "${var_name}=$(<"$file_path")"
}

positive_int() {
  [[ "${1:-}" =~ ^[0-9]+$ ]] && (( "$1" > 0 ))
}

bool_enabled() {
  case "${1:-false}" in
    true|TRUE|True|1|yes|YES|Yes|on|ON|On) return 0 ;;
    *) return 1 ;;
  esac
}

load_env_file_raw() {
  local env_file="${1:-}"
  local line key value

  if [[ -z "$env_file" || ! -f "$env_file" ]]; then
    return 0
  fi

  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"

    [[ "$line" =~ ^[[:space:]]*$ ]] && continue
    [[ "$line" =~ ^[[:space:]]*# ]] && continue

    if [[ "$line" =~ ^[[:space:]]*export[[:space:]]+ ]]; then
      line="${line#*export}"
      line="${line#"${line%%[![:space:]]*}"}"
    fi

    [[ "$line" == *=* ]] || continue

    key="${line%%=*}"
    value="${line#*=}"

    key="${key#"${key%%[![:space:]]*}"}"
    key="${key%"${key##*[![:space:]]}"}"

    if [[ ! "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
      log WARN "Ignoring invalid env key in ${env_file}: ${key}"
      continue
    fi

    export "${key}=${value}"
  done < "$env_file"
}

map_pg_env() {
  if [[ -n "${DB_HOST:-}" ]]; then
    PGHOST="$DB_HOST"
  fi

  if [[ -n "${DB_PORT:-}" ]]; then
    PGPORT="$DB_PORT"
  fi

  if [[ -n "${DB_NAME:-}" ]]; then
    PGDATABASE="$DB_NAME"
  fi

  if [[ -n "${DB_USER:-}" ]]; then
    PGUSER="$DB_USER"
  fi

  if [[ -n "${DB_PASSWORD:-}" ]]; then
    PGPASSWORD="$DB_PASSWORD"
  fi

  if [[ -n "${DB_PASSWORD_FILE:-}" ]]; then
    PGPASSWORD_FILE="$DB_PASSWORD_FILE"
  fi

  if [[ -n "${DB_SCHEMA:-}" ]]; then
    PGSCHEMA="$DB_SCHEMA"
  fi

  if [[ -z "${PGSCHEMA:-}" && -n "${SCHEMA:-}" ]]; then
    PGSCHEMA="$SCHEMA"
  fi
}

require_pg_env() {
  load_file_env PGPASSWORD

  : "${PGHOST:?PGHOST is required}"
  : "${PGPORT:=5432}"
  : "${PGDATABASE:?PGDATABASE is required}"
  : "${PGUSER:?PGUSER is required}"
  : "${PGSCHEMA:=monitoring}"
  : "${PGCONNECT_TIMEOUT:=10}"

  if ! positive_int "$PGCONNECT_TIMEOUT"; then
    log ERROR "PGCONNECT_TIMEOUT must be a positive integer"
    return 1
  fi

  if [[ -z "${PGPASSWORD:-}" && -z "${PGPASSFILE:-}" ]]; then
    log ERROR "PGPASSWORD, PGPASSWORD_FILE, or PGPASSFILE is required"
    return 1
  fi

  export PGPORT
  export PGSCHEMA
  export PGCONNECT_TIMEOUT
  if [[ -n "${PGPASSWORD:-}" ]]; then
    export PGPASSWORD
  fi
}
