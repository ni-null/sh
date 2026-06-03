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
if ! command -v borg >/dev/null 2>&1; then
    echo "錯誤: 找不到 borg，請先安裝 borgbackup"
    exit 1
fi

BORG_REPO="$(yq eval -r '.borg.repo' "$CONFIG_YAML")"
BORG_ENCRYPTION="$(yq eval -r '.borg.encryption // ""' "$CONFIG_YAML")"
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
: "${BORG_EXCLUDE_PATHS:?缺少設定: borg.exclude_paths}"

# export BORG_PASSPHRASE='your_secret' # 若有加密請啟用
export BORG_REPO="${BORG_REPO}"

# 保留策略調整
KEEP_DAILY="${BORG_KEEP_DAILY}"     # 保留最近 14 天的每一份備份
KEEP_WEEKLY="${BORG_KEEP_WEEKLY}"   # 保留最近 0 週的週備份
KEEP_MONTHLY="${BORG_KEEP_MONTHLY}" # 保留最近 12 個月的月備份

# 備份目標 "名稱:路徑"（僅由 YAML 載入）
BACKUP_TARGETS=()
IFS=',' read -r -a BACKUP_TARGETS <<< "$BORG_BACKUP_TARGETS"

# 排除清單 (注意：路徑結尾若無 * 則為完全匹配)
EXCLUDE_PATHS=()
IFS=',' read -r -a EXCLUDE_PATHS <<< "$BORG_EXCLUDE_PATHS"

# ==============================================================================
# 輔助函式：日誌與計時
# ==============================================================================

now_ts() { date +%s; }
log_info() { echo "[INFO] $1"; }
log_warn() { echo "[WARN] $1"; }
log_err()  { echo "[ERROR] $1" >&2; }

# 檢查 repo 是否可用（避免未掛載時誤備份到空目錄）
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

# 當 repo 目錄不存在時，自動初始化新倉庫
ensure_borg_repo() {
    if [ -d "$BORG_REPO" ]; then
        return 0
    fi

    log_warn "BORG_REPO not found: $BORG_REPO"
    log_info "Creating repository directory..."
    if ! mkdir -p "$BORG_REPO"; then
        log_err "Failed to create directory: $BORG_REPO"
        return 1
    fi

    log_info "Initializing borg repository: $BORG_REPO"
    local init_args=()
    if [ -n "$BORG_ENCRYPTION" ]; then
        init_args+=(--encryption "$BORG_ENCRYPTION")
        log_info "Using encryption mode: $BORG_ENCRYPTION"
    else
        init_args+=(--encryption=none)
        log_info "Encryption is empty in config, using non-encrypted repo."
    fi

    if ! borg init "${init_args[@]}" "$BORG_REPO"; then
        log_err "Failed to initialize borg repository: $BORG_REPO"
        return 1
    fi

    log_info "Repository initialized successfully."
    return 0
}

# 列出目前所有 borg FUSE 掛載點（新版做法：實際 lock 來源以 borg mount 程序判斷）
list_all_borg_mountpoints() {
    if command -v findmnt >/dev/null 2>&1; then
        findmnt -rn -t fuse.borgfs -o TARGET 2>/dev/null
        return
    fi

    # fallback: 直接讀 kernel mount table
    while read -r source target fstype _; do
        [ "$fstype" = "fuse.borgfs" ] || continue
        echo "$target"
    done < /proc/self/mounts
}

# 若偵測到此 repo 的 borg mount 程序，先自動卸載，避免 lock 衝突。
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

    # borg/FUSE 釋放 lock 可能有短暫延遲，稍等再檢查 stale lock。
    sleep 1
    return 0
}

# 列出仍在執行的 borg 指令程序；避免把本腳本 borg-backup.sh 誤判成 borg。
list_active_borg_processes() {
    pgrep -af '(^|[ /])borg( |$)' 2>/dev/null || true
}

# 偵測 repo lock；若沒有任何活躍 borg 程序，才自動 break-lock。
# 注意：break-lock 只適合處理 stale lock。若仍有 borg create/prune/compact/mount
# 正在執行，強制 break-lock 可能破壞正在進行的操作，因此這裡會拒絕。
auto_fix_borg_lock() {
    if borg with-lock "$BORG_REPO" true >/dev/null 2>&1; then
        log_info "Repository lock is OK."
        return 0
    fi

    log_warn "Repository lock detected: $BORG_REPO"

    local active_borg_processes
    active_borg_processes="$(list_active_borg_processes)"
    if [ -n "$active_borg_processes" ]; then
        log_err "Active borg process exists. Refusing to break lock:"
        echo "$active_borg_processes" >&2
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
# 主程式邏輯
# ==============================================================================

TOTAL_START=$(now_ts)
log_info "Starting Daily Auto-Backup Job..."

ensure_borg_repo || exit 1
validate_borg_repo || exit 1
auto_unmount_borg_mounts || exit 1
auto_fix_borg_lock || exit 1

TODAY=$(date +%Y-%m-%d)

# 1. 預先建構排除參數陣列 (修正點：移出迴圈，只建構一次參數)
# 這會將 EXCLUDE_PATHS 轉換為: --exclude /srv/backup --exclude /var/log/journal
BORG_EXCLUDE_ARGS=()
for path in "${EXCLUDE_PATHS[@]}"; do
    [ -n "$path" ] || continue
    BORG_EXCLUDE_ARGS+=(--exclude "$path")
done

for entry in "${BACKUP_TARGETS[@]}"; do
    JOB_NAME="${entry%%:*}"
    TARGET_DIR="${entry#*:}"

    # 產生的檔名將會是: auto-sdc_srv-2026-01-27
    ARCHIVE_NAME="auto-$JOB_NAME-$TODAY"
    TASK_START=$(now_ts)

    # 檢查目錄是否存在
    if [ ! -d "$TARGET_DIR" ]; then
        log_err "Directory not found: $TARGET_DIR (Skipping $JOB_NAME)"
        continue
    fi

    # 2. 檢查封存檔是否已存在
    if borg list "$BORG_REPO::$ARCHIVE_NAME" >/dev/null 2>&1; then
        log_info "Archive '$ARCHIVE_NAME' already exists. Skipping creation."
        CREATE_RC=0
    else
        log_info "Creating archive: $ARCHIVE_NAME"

        # 修正點：單次執行 borg create，並傳入組合好的排除參數陣列
        borg create \
            --stats \
            --compression lz4 \
            "${BORG_EXCLUDE_ARGS[@]}" \
            "$BORG_REPO::$ARCHIVE_NAME" \
            "$TARGET_DIR"

        CREATE_RC=$?
    fi

    # 3. 執行清理 (Prune)
    # 容忍 Exit Code 0 (成功) 或 1 (檔案在備份期間變動)
    if [ "$CREATE_RC" -le 1 ]; then
        [ "$CREATE_RC" -eq 1 ] && log_warn "Backup of $JOB_NAME finished with warnings (file changed)."

        log_info "Pruning archives for $JOB_NAME (Strategy: ${KEEP_DAILY}D + ${KEEP_WEEKLY}W + ${KEEP_MONTHLY}M)"

        borg prune \
            --list \
            --keep-daily "$KEEP_DAILY" \
            --keep-weekly "$KEEP_WEEKLY" \
            --keep-monthly "$KEEP_MONTHLY" \
            --glob-archives "auto-$JOB_NAME-*" \
            "$BORG_REPO"

        PRUNE_RC=$?
        [ "$PRUNE_RC" -ne 0 ] && log_warn "Prune task for $JOB_NAME finished with issues (Code: $PRUNE_RC)"
    else
        log_err "Backup creation failed for $JOB_NAME (Exit Code: $CREATE_RC). Skipping prune."
    fi

    TASK_END=$(now_ts)
    log_info "Task '$JOB_NAME' finished in $((TASK_END - TASK_START))s"
done

# ==============================================================================
# 收尾作業 (Compact)
# ==============================================================================

log_info "Compacting repository..."
START_COMPACT=$(now_ts)

# Compact 不需要指定 Repo 若已設定 ENV，但加上去也無妨
borg compact "$BORG_REPO"
COMPACT_RC=$?

if [ "$COMPACT_RC" -eq 0 ]; then
    log_info "Compact finished in $(( $(now_ts) - START_COMPACT ))s"
else
    log_warn "Compact failed. Exit Code: $COMPACT_RC"
fi

TOTAL_DURATION=$(( $(now_ts) - TOTAL_START ))
log_info "Auto-Backup Job Completed. Total Duration: ${TOTAL_DURATION}s"
