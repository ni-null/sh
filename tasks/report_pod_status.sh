#!/bin/bash
# ==============================================================================
# Podman 容器狀態監控腳本
# 功能：
# 1. 掃描 systemd 配置目錄下的 .container 檔案
# 2. 比對 podman ps 確認容器狀態
# 3. 只在發現異常時發送 Teams 通知
# 4. 記錄詳細的執行 log
#
# 用法：/srv/sh/report_pod_status.sh [標題(選填)]
# ==============================================================================

# 載入同目錄 .env
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

TEAMS_API_SCRIPT="$(yq eval -r '.pod_status.teams_api_script' "$CONFIG_YAML")"
IS_TEST_MODE="$(yq eval -r '.teams.test_mode' "$CONFIG_YAML")"
POD_STATUS_LOG_FILE="$(yq eval -r '.pod_status.log_file' "$CONFIG_YAML")"
POD_STATUS_DEFAULT_TITLE="$(yq eval -r '.pod_status.default_title' "$CONFIG_YAML")"

# --- 設定區塊 ---
# 固定掃描 systemd 容器設定根目錄，遞迴偵測所有子目錄 .container
CONF_ROOT="/etc/containers/systemd"
: "${TEAMS_API_SCRIPT:?缺少設定: pod_status.teams_api_script}"
: "${IS_TEST_MODE:?缺少設定: teams.test_mode}"
: "${POD_STATUS_LOG_FILE:?缺少設定: pod_status.log_file}"
: "${POD_STATUS_DEFAULT_TITLE:?缺少設定: pod_status.default_title}"
API_SCRIPT="${TEAMS_API_SCRIPT}"
export IS_TEST_MODE="${IS_TEST_MODE}"

# Log 設定
LOG_FILE="${POD_STATUS_LOG_FILE}"
TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')
HOSTNAME=$(hostname)

# 自訂標題參數
CUSTOM_TITLE="${1:-$POD_STATUS_DEFAULT_TITLE}"

# --- Log 函式 ---
log_info() {
    echo "[$TIMESTAMP] [INFO] $1" | tee -a "$LOG_FILE"
}

log_warn() {
    echo "[$TIMESTAMP] [WARN] $1" | tee -a "$LOG_FILE"
}

log_error() {
    echo "[$TIMESTAMP] [ERROR] $1" | tee -a "$LOG_FILE"
}

# --- 主程式開始 ---
log_info "=========================================="
log_info "開始執行容器狀態檢查"
log_info "配置目錄: $CONF_ROOT"
log_info "測試模式: $IS_TEST_MODE"

# 1. 檢查配置目錄是否存在
if [ ! -d "$CONF_ROOT" ]; then
    log_error "配置目錄不存在: $CONF_ROOT"
    exit 1
fi

# 2. 使用 find 找出所有 .container 檔案
log_info "掃描 .container 檔案..."
CONTAINER_FILES=$(find "$CONF_ROOT" -type f -name "*.container" 2>/dev/null)

if [ -z "$CONTAINER_FILES" ]; then
    log_warn "未找到任何 .container 檔案"
    exit 0
fi

CONTAINER_COUNT=$(echo "$CONTAINER_FILES" | wc -l)
log_info "找到 $CONTAINER_COUNT 個 .container 檔案"

# 3. 取得當前運行的容器列表
log_info "取得 podman 容器狀態..."
RUNNING_CONTAINERS=$(podman ps --format "{{.Names}}" 2>/dev/null)
ALL_CONTAINERS=$(podman ps -a --format "{{.Names}}|{{.State}}" 2>/dev/null)

if [ $? -ne 0 ]; then
    log_error "無法執行 podman ps 指令"
    exit 1
fi

log_info "當前運行容器數: $(echo "$RUNNING_CONTAINERS" | grep -v "^$" | wc -l)"

# 4. 檢查每個 .container 檔案對應的容器狀態
ANOMALY_FOUND=false
ALL_STATUS_DETAILS=""

while IFS= read -r container_file; do
    # 從檔案路徑提取容器名稱 (去除路徑和 .container 後綴)
    CONTAINER_NAME=$(basename "$container_file" .container)
    
    log_info "檢查容器: $CONTAINER_NAME (來源: $container_file)"
    
    # 檢查容器是否存在於 podman
    CONTAINER_INFO=$(echo "$ALL_CONTAINERS" | grep "^${CONTAINER_NAME}|" || true)
    
    if [ -z "$CONTAINER_INFO" ]; then
        # 容器不存在
        log_warn "異常: 容器不存在 - $CONTAINER_NAME"
        ANOMALY_FOUND=true
        ALL_STATUS_DETAILS="${ALL_STATUS_DETAILS}${CONTAINER_NAME}|未檢測到|未檢測到 (服務可能已崩潰)|abnormal\n"
    else
        # 容器存在，檢查狀態
        CONTAINER_STATE=$(echo "$CONTAINER_INFO" | cut -d'|' -f2)
        
        # 取得詳細狀態字串
        C_STATUS_STR=$(podman ps -a --filter "name=^${CONTAINER_NAME}$" --format "{{.Status}}" 2>/dev/null || echo "Unknown")
        
        if [ "$CONTAINER_STATE" != "running" ]; then
            # 容器已停止
            log_warn "異常: 容器已停止 - $CONTAINER_NAME (狀態: $CONTAINER_STATE)"
            ANOMALY_FOUND=true
            
            # 取得退出碼
            EXIT_CODE=$(podman inspect "$CONTAINER_NAME" --format '{{.State.ExitCode}}' 2>/dev/null || echo "N/A")
            ALL_STATUS_DETAILS="${ALL_STATUS_DETAILS}${CONTAINER_NAME}|${CONTAINER_STATE}|${C_STATUS_STR}|abnormal\n"
        else
            log_info "正常: 容器運行中 - $CONTAINER_NAME"
            ALL_STATUS_DETAILS="${ALL_STATUS_DETAILS}${CONTAINER_NAME}|running|${C_STATUS_STR}|normal\n"
        fi
    fi
done <<< "$CONTAINER_FILES"

# 5. 判斷是否需要發送通知
if [ "$ANOMALY_FOUND" = false ]; then
    log_info "所有容器狀態正常，無需發送通知"
    log_info "檢查完成"
    log_info "=========================================="
    exit 0
fi

log_warn "發現異常容器，準備發送通知"

# 6. 組裝所有容器的 JSON 內容（包括正常和異常的）
JSON_ITEMS=""
FIRST_ITEM=true

while IFS='|' read -r c_name c_state c_status_str c_type; do
    if [ -z "$c_name" ]; then continue; fi
    
    # 根據狀態決定 icon 和顯示內容
    if [ "$c_state" = "未檢測到" ]; then
        # 容器不存在
        LINE_TEXT="🔴 ${c_name} : ${c_status_str}"
    elif [ "$c_state" = "running" ]; then
        # 容器正常運行
        LINE_TEXT="🟢 ${c_name} : 運行中 (${c_status_str})"
    else
        # 容器已停止
        LINE_TEXT="🔴 ${c_name} : 已停止 (${c_status_str})"
    fi
    
    # 使用 jq 正確處理 emoji
    ESCAPED_TEXT=$(printf '%s' "$LINE_TEXT" | jq -Rs .)
    ITEM="{\"type\":\"TextBlock\",\"text\":${ESCAPED_TEXT},\"wrap\":true}"
    
    if [ "$FIRST_ITEM" = true ]; then
        JSON_ITEMS="$ITEM"
        FIRST_ITEM=false
    else
        JSON_ITEMS="${JSON_ITEMS},$ITEM"
    fi
done <<< "$(echo -e "$ALL_STATUS_DETAILS")"

 

# 7. 組裝完整的 JSON 內容 (包含檢測路徑統計與人為介入提醒)
SUMMARY_TEXT="檢測路徑 ${CONF_ROOT} 發現 目標 ${CONTAINER_COUNT}個容器"

CONTENT_JSON=$(cat <<EOF
{
    "type": "Container",
    "items": [
        {
            "type": "TextBlock",
            "text": "${SUMMARY_TEXT}",
            "isSubtle": true,
            "size": "Small"
        },
        {
            "type": "Container",
            "items": [
                ${JSON_ITEMS}
            ]
        },
        {
            "type": "TextBlock",
            "text": "需要人為介入處理",
            "color": "Attention",
            "weight": "Bolder",
            "size": "Medium",
            "separator": true
        }
    ]
}
EOF
)

# 8. 呼叫通用 API 發送通知（參考舊腳本格式）
log_info "呼叫 API 發送通知..."

if [ ! -x "$API_SCRIPT" ]; then
    log_error "API 腳本不存在或無執行權限: $API_SCRIPT"
    exit 1
fi

# 參數：標題, 目標, 內容JSON, is_json標記
$API_SCRIPT "🚨 ${CUSTOM_TITLE}" "Container Services" "$CONTENT_JSON" "true"

if [ $? -eq 0 ]; then
    log_info "通知發送成功"
else
    log_error "通知發送失敗"
fi

log_info "檢查完成"
log_info "=========================================="
