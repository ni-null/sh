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
export BORG_REPO="${BORG_REPO}"
# export BORG_PASSPHRASE='your_secret' # 若有加密請啟用

# 保留策略調整
KEEP_DAILY="${BORG_KEEP_DAILY}"    # 保留最近 14 天的每一份備份
KEEP_WEEKLY="${BORG_KEEP_WEEKLY}"   # 保留最近 0  週的週備份 (約 3 個月)
KEEP_MONTHLY="${BORG_KEEP_MONTHLY}"  # 保留最近 12 個月的月備份 (約 1 年)

# 備份目標 "名稱:路徑"（僅由 YAML 載入）
BACKUP_TARGETS=()
IFS=',' read -r -a BACKUP_TARGETS <<< "$BORG_BACKUP_TARGETS"

# 排除清單 (注意：路徑結尾若無 * 則為完全匹配)
EXCLUDE_PATHS=()
if [ -n "${BORG_EXCLUDE_PATHS}" ]; then
    IFS=',' read -r -a EXCLUDE_PATHS <<< "$BORG_EXCLUDE_PATHS"
fi

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

# 列出目前使用此 repo 的 borg FUSE 掛載點（避免 lock 衝突）
list_borg_mountpoints_for_repo() {
    if command -v findmnt >/dev/null 2>&1; then
        while read -r source target; do
            case "$source" in
                "$BORG_REPO" | "$BORG_REPO"::*)
                    echo "$target"
                    ;;
            esac
        done < <(findmnt -rn -t fuse.borgfs -o SOURCE,TARGET 2>/dev/null)
        return
    fi

    # fallback: 直接讀 kernel mount table
    while read -r source target fstype _; do
        [ "$fstype" = "fuse.borgfs" ] || continue
        case "$source" in
            "$BORG_REPO" | "$BORG_REPO"::*)
                echo "$target"
                ;;
        esac
    done < /proc/self/mounts
}

# 若已掛載同一個 repo，先自動卸載
auto_unmount_borg_mounts() {
    mapfile -t mounts < <(list_borg_mountpoints_for_repo)
    if [ "${#mounts[@]}" -eq 0 ]; then
        log_info "No active borg mounts for repo."
        return 0
    fi

    local mnt
    for mnt in "${mounts[@]}"; do
        log_warn "Detected active borg mount: $mnt. Unmounting to avoid repository lock..."
        if borg umount "$mnt" >/dev/null 2>&1 || umount "$mnt" >/dev/null 2>&1 || fusermount -u "$mnt" >/dev/null 2>&1; then
            log_info "Unmounted: $mnt"
        else
            log_err "Failed to unmount: $mnt"
            return 1
        fi
    done

    return 0
}

# ==============================================================================
# 主程式邏輯
# ==============================================================================

TOTAL_START=$(now_ts)
log_info "Starting Daily Auto-Backup Job..."

validate_borg_repo || exit 1
auto_unmount_borg_mounts || exit 1

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
    if borg list "$BORG_REPO::$ARCHIVE_NAME" > /dev/null 2>&1; then
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
    if [ $CREATE_RC -le 1 ]; then
        [ $CREATE_RC -eq 1 ] && log_warn "Backup of $JOB_NAME finished with warnings (file changed)."
        
        log_info "Pruning archives for $JOB_NAME (Strategy: ${KEEP_DAILY}D + ${KEEP_WEEKLY}W + ${KEEP_MONTHLY}M)"
        
        borg prune \
            --list \
            --keep-daily $KEEP_DAILY \
            --keep-weekly $KEEP_WEEKLY \
            --keep-monthly $KEEP_MONTHLY \
            --glob-archives "auto-$JOB_NAME-*" \
            "$BORG_REPO"
            
        PRUNE_RC=$?
        [ $PRUNE_RC -ne 0 ] && log_warn "Prune task for $JOB_NAME finished with issues (Code: $PRUNE_RC)"
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

echo "Compact finished in $(( $(now_ts) - START_COMPACT ))s"

TOTAL_DURATION=$(( $(now_ts) - TOTAL_START ))
log_info "Auto-Backup Job Completed. Total Duration: ${TOTAL_DURATION}s"
