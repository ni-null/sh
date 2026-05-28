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
BORG_BACKUP_TARGETS="$(yq eval -r '.borg.backup_targets // [] | map(.name + ":" + .path) | join(",")' "$CONFIG_YAML")"
BORG_MANUAL_EXCLUDE_PATHS="$(yq eval -r '.borg.manual_exclude_paths // [] | join(",")' "$CONFIG_YAML")"

: "${BORG_REPO:?缺少設定: borg.repo}"
: "${BORG_BACKUP_TARGETS:?缺少設定: borg.backup_targets}"
export BORG_REPO="${BORG_REPO}"
# export BORG_PASSPHRASE='your_secret' # 若有加密請啟用

# 備份目標 "名稱:路徑"（僅由 YAML 載入）
BACKUP_TARGETS=()
IFS=',' read -r -a BACKUP_TARGETS <<< "$BORG_BACKUP_TARGETS"

# 排除清單
EXCLUDE_PATHS=()
if [ -n "${BORG_MANUAL_EXCLUDE_PATHS}" ]; then
    IFS=',' read -r -a EXCLUDE_PATHS <<< "$BORG_MANUAL_EXCLUDE_PATHS"
fi

# ==============================================================================
# 輔助函式
# ==============================================================================

now_ts() { date +%s; }
log_info() { echo "[INFO] $1"; }
log_warn() { echo "[WARN] $1"; }
log_err()  { echo "[ERROR] $1" >&2; }

# ==============================================================================
# 主程式邏輯
# ==============================================================================

TOTAL_START=$(now_ts)
log_info "Starting MANUAL Backup Job..."

# 取得當前時間，格式範例：2026-01-28-14:02
TIMESTAMP=$(date +%Y-%m-%d-%H:%M)

# 1. 預先建構排除參數陣列
BORG_EXCLUDE_ARGS=()
for path in "${EXCLUDE_PATHS[@]}"; do
    [ -n "$path" ] || continue
    BORG_EXCLUDE_ARGS+=(--exclude "$path")
done

for entry in "${BACKUP_TARGETS[@]}"; do
    JOB_NAME="${entry%%:*}"
    TARGET_DIR="${entry#*:}"
    
    # 產生的檔名: manual-srv-2026-01-28-14:02
    ARCHIVE_NAME="manual-$JOB_NAME-$TIMESTAMP"
    
    TASK_START=$(now_ts)
    
    # 檢查目錄是否存在
    if [ ! -d "$TARGET_DIR" ]; then
        log_err "Directory not found: $TARGET_DIR (Skipping $JOB_NAME)"
        continue
    fi

    # 檢查是否已有同分同秒的備份 (防止手動連點)
    if borg list "$BORG_REPO::$ARCHIVE_NAME" > /dev/null 2>&1; then
        log_warn "Archive '$ARCHIVE_NAME' already exists. Skipping."
    else
        log_info "Creating manual archive: $ARCHIVE_NAME"
        
        borg create \
            --stats \
            --compression lz4 \
            "${BORG_EXCLUDE_ARGS[@]}" \
            "$BORG_REPO::$ARCHIVE_NAME" \
            "$TARGET_DIR"
        
        CREATE_RC=$?

        if [ $CREATE_RC -eq 0 ]; then
            log_info "Backup of $JOB_NAME successful."
        elif [ $CREATE_RC -eq 1 ]; then
            log_warn "Backup of $JOB_NAME finished with warnings (files changed)."
        else
            log_err "Backup of $JOB_NAME failed (Exit Code: $CREATE_RC)."
        fi
        
        # 注意：此處已移除 prune (清理) 邏輯
    fi

    TASK_END=$(now_ts)
    log_info "Task '$JOB_NAME' finished in $((TASK_END - TASK_START))s"
done

# ==============================================================================
# 收尾作業 (Compact)
# ==============================================================================

log_info "Compacting repository..."
START_COMPACT=$(now_ts)
borg compact "$BORG_REPO"
echo "Compact finished in $(( $(now_ts) - START_COMPACT ))s"

TOTAL_DURATION=$(( $(now_ts) - TOTAL_START ))
log_info "Manual Backup Job Completed. Total Duration: ${TOTAL_DURATION}s"
