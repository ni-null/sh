#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_YAML="${SCRIPT_DIR}/config.yaml"
if [ ! -f "$CONFIG_YAML" ]; then
    echo "錯誤: 找不到設定檔 $CONFIG_YAML"
    exit 1
fi
if ! command -v yq >/dev/null 2>&1; then
    echo "錯誤: 找不到 yq，請先安裝 mikefarah/yq"
    exit 1
fi

MARIADB_SQL_BACKUP_DIR="$(yq eval -r '.mariadb_sql.backup_dir' "$CONFIG_YAML")"
MARIADB_SQL_RETENTION_DAYS="$(yq eval -r '.mariadb_sql.retention_days' "$CONFIG_YAML")"
MARIADB_SQL_CONTAINERS="$(yq eval -r '.mariadb_sql.containers // [] | join(",")' "$CONFIG_YAML")"
PODMAN_BIN="/usr/bin/podman"

: "${MARIADB_SQL_BACKUP_DIR:?缺少設定: mariadb_sql.backup_dir}"
: "${MARIADB_SQL_RETENTION_DAYS:?缺少設定: mariadb_sql.retention_days}"
: "${MARIADB_SQL_CONTAINERS:?缺少設定: mariadb_sql.containers}"
BACKUP_DIR="${MARIADB_SQL_BACKUP_DIR}"
RETENTION_DAYS="${MARIADB_SQL_RETENTION_DAYS}"
TIMESTAMP="$(date +%Y-%m-%d_%H%M%S)"

CONTAINERS=(
    "dsce-mariadb"
)
if [ -n "${MARIADB_SQL_CONTAINERS}" ]; then
    IFS=',' read -r -a CONTAINERS <<< "$MARIADB_SQL_CONTAINERS"
fi

log_info() { echo "[INFO] $1"; }
log_warn() { echo "[WARN] $1"; }
log_err() { echo "[ERROR] $1" >&2; }

is_running() {
    local name="$1"
    "$PODMAN_BIN" inspect -f '{{.State.Running}}' "$name" 2>/dev/null | grep -q '^true$'
}

dump_one() {
    local name="$1"
    local outfile="${BACKUP_DIR}/${name}-${TIMESTAMP}.sql.gz"

    if ! is_running "$name"; then
        log_err "Container not running: ${name}"
        return 1
    fi

    log_info "Start SQL dump: ${name}"
    "$PODMAN_BIN" exec "$name" sh -lc \
        'mariadb-dump --single-transaction --quick --routines --events --triggers -uroot -p"$MARIADB_ROOT_PASSWORD" --all-databases' \
        | gzip -c > "$outfile"

    if [ ! -s "$outfile" ]; then
        log_err "Backup file is empty: ${outfile}"
        return 1
    fi

    log_info "Backup done: ${outfile}"
}

main() {
    mkdir -p "$BACKUP_DIR"

    local fail_count=0
    for c in "${CONTAINERS[@]}"; do
        if ! dump_one "$c"; then
            fail_count=$((fail_count + 1))
        fi
    done

    log_info "Cleanup old backups (> ${RETENTION_DAYS} days)"
    find "$BACKUP_DIR" -name "*.sql.gz" -mtime "+${RETENTION_DAYS}" -delete

    if [ "$fail_count" -gt 0 ]; then
        log_err "SQL backup finished with ${fail_count} failure(s)."
        return 1
    fi

    log_info "SQL backup finished successfully."
}

main "$@"
