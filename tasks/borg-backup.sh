#!/bin/bash

# ==============================================================================
# 全域設定
# ==============================================================================

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

BORG_REPO="$(yq eval -r '.borg.repo' "$CONFIG_YAML")"
BORG_KEEP_DAILY="$(yq eval -r '.borg.keep_daily' "$CONFIG_YAML")"
BORG_KEEP_WEEKLY="$(yq eval -r '.borg.keep_weekly' "$CONFIG_YAML")"
BORG_KEEP_MONTHLY="$(yq eval -r '.borg.keep_monthly' "$CONFIG_YAML")"
BORG_BACKUP_TARGETS="$(yq eval -r '.borg.backup_targets // [] | map(.name + ":" + .path) | join(",")' "$CONFIG_YAML")"
BORG_EXCLUDE_PATHS="$(yq eval -r '.borg.exclude_paths // [] | join(",")' "$CONFIG_YAML")"

: "${BORG_REPO:?缺少設定: borg.repo}"
: "${BORG_KEEP_DAILY:?缺少設定: borg.keep_daily}"
: "${BORG_KEEP_WEEKLY:?缺少設定: borg.keep_weekly}"
: "${BORG_KEEP_MONTHLY:?缺少設定: borg.keep_monthly}"
: "${BORG_BACKUP_TARGETS:?缺少設定: borg.backup_targets}"

export BORG_REPO="$BORG_REPO"

KEEP_DAILY="$BORG_KEEP_DAILY"
KEEP_WEEKLY="$BORG_KEEP_WEEKLY"
KEEP_MONTHLY="$BORG_KEEP_MONTHLY"

BACKUP_TARGETS=()
IFS=',' read -r -a BACKUP_TARGETS <<< "$BORG_BACKUP_TARGETS"

EXCLUDE_PATHS=()
if [ -n "$BORG_EXCLUDE_PATHS" ]; then
    IFS=',' read -r -a EXCLUDE_PATHS <<< "$BORG_EXCLUDE_PATHS"
fi

# ==============================================================================
# 輔助函式
# ==============================================================================

now_ts() { date +%s; }
log_info() { echo "[INFO] $1"; }
log_warn() { echo "[WARN] $1"; }
log_err()  { echo "[ERROR] $1" >&2; }

validate_borg_repo() {
    if [ ! -d "$BORG_REPO" ]; then
        log_err "BORG_REPO not found: $BORG_REPO"
        return 1
    fi

    if [ ! -f "$BORG_REPO/config" ] || [ ! -d "$BORG_REPO/data" ]; then
        log_err "BORG_REPO looks unavailable or not mounted correctly: $BORG_REPO"
        log_err "Expected files/dirs missing: config or data"
        return 1
    fi

    return 0
}

list_all_borg_mountpoints() {
    if command -v findmnt >/dev/null 2>&1; then
        findmnt -rn -t fuse.borgfs -o TARGET 2>/dev/null
        return
    fi

    while read -r source target fstype _; do
        [ "$fstype" = "fuse.borgfs" ] || continue
        echo "$target"
    done < /proc/self/mounts
}

auto_unmount_borg_mounts() {
    local mounts
    mounts="$(pgrep -af "borg mount .*${BORG_REPO}" | awk '{print $NF}')"

    if [ -z "$mounts" ]; then
        log_info "No active borg mounts."
        return 0
    fi

    local mnt
    for mnt in $mounts; do
        log_warn "Detected borg mount: $mnt. Unmounting..."

        borg umount "$mnt" >/dev/null 2>&1 \
        || umount "$mnt" >/dev/null 2>&1 \
        || fusermount3 -u "$mnt" >/dev/null 2>&1 \
        || fusermount -u "$mnt" >/dev/null 2>&1 \
        || {
            log_err "Failed to unmount: $mnt"
            return 1
        }

        log_info "Unmounted: $mnt"
    done

    sleep 1
    return 0
}

auto_fix_borg_lock() {
    if borg with-lock "$BORG_REPO" true >/dev/null 2>&1; then
        log_info "Repository lock is OK."
        return 0
    fi

    log_warn "Repository lock detected: $BORG_REPO"

    if pgrep -af borg >/dev/null 2>&1; then
        log_err "Active borg process exists. Refusing to break lock:"
        pgrep -af borg
        return 1
    fi

    log_warn "No active borg process found. Running borg break-lock..."

    if borg break-lock "$BORG_REPO"; then
        log_info "borg break-lock completed."
    else
        log_err "borg break-lock failed."
        return 1
    fi

    if borg with-lock "$BORG_REPO" true >/dev/null 2>&1; then
        log_info "Repository lock is OK after break-lock."
        return 0
    fi

    log_err "Repository is still locked after break-lock."
    return 1
}

# ==============================================================================
# 主程式
# ==============================================================================

TOTAL_START=$(now_ts)
log_info "Starting Daily Auto-Backup Job..."

validate_borg_repo || exit 1
auto_unmount_borg_mounts || exit 1
auto_fix_borg_lock || exit 1

TODAY=$(date +%Y-%m-%d)

BORG_EXCLUDE_ARGS=()
for path in "${EXCLUDE_PATHS[@]}"; do
    [ -n "$path" ] || continue
    BORG_EXCLUDE_ARGS+=(--exclude "$path")
done

for entry in "${BACKUP_TARGETS[@]}"; do
    JOB_NAME="${entry%%:*}"
    TARGET_DIR="${entry#*:}"

    ARCHIVE_NAME="auto-$JOB_NAME-$TODAY"
    TASK_START=$(now_ts)

    if [ ! -d "$TARGET_DIR" ]; then
        log_err "Directory not found: $TARGET_DIR (Skipping $JOB_NAME)"
        continue
    fi

    if borg list "$BORG_REPO::$ARCHIVE_NAME" >/dev/null 2>&1; then
        log_info "Archive '$ARCHIVE_NAME' already exists. Skipping creation."
        CREATE_RC=0
    else
        log_info "Creating archive: $ARCHIVE_NAME"

        borg create \
            --stats \
            --compression lz4 \
            "${BORG_EXCLUDE_ARGS[@]}" \
            "$BORG_REPO::$ARCHIVE_NAME" \
            "$TARGET_DIR"

        CREATE_RC=$?
    fi

    if [ "$CREATE_RC" -le 1 ]; then
        [ "$CREATE_RC" -eq 1 ] && log_warn "Backup of $JOB_NAME finished with warnings."

        log_info "Pruning archives for $JOB_NAME"

        borg prune \
            --list \
            --keep-daily "$KEEP_DAILY" \
            --keep-weekly "$KEEP_WEEKLY" \
            --keep-monthly "$KEEP_MONTHLY" \
            --glob-archives "auto-$JOB_NAME-*" \
            "$BORG_REPO"

        PRUNE_RC=$?
        [ "$PRUNE_RC" -ne 0 ] && log_warn "Prune task for $JOB_NAME finished with issues. Code: $PRUNE_RC"
    else
        log_err "Backup creation failed for $JOB_NAME. Exit Code: $CREATE_RC. Skipping prune."
    fi

    TASK_END=$(now_ts)
    log_info "Task '$JOB_NAME' finished in $((TASK_END - TASK_START))s"
done

# ==============================================================================
# Compact
# ==============================================================================

log_info "Compacting repository..."
START_COMPACT=$(now_ts)

borg compact "$BORG_REPO"
COMPACT_RC=$?

if [ "$COMPACT_RC" -eq 0 ]; then
    log_info "Compact finished in $(( $(now_ts) - START_COMPACT ))s"
else
    log_warn "Compact failed. Exit Code: $COMPACT_RC"
fi

TOTAL_DURATION=$(( $(now_ts) - TOTAL_START ))
log_info "Auto-Backup Job Completed. Total Duration: ${TOTAL_DURATION}s"
