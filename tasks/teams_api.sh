#!/bin/bash
# ==============================================================================
# 通用 Teams 通知發送器 (API)
# 用法：
# export IS_TEST_MODE=true  (可選，設定環境變數來開啟測試模式)
# ./teams_api.sh "標題" "目標/副標題" "內容訊息" [is_json]
# ==============================================================================

# 1. 載入設定 (先讀同目錄 .env，再讀 teamapi.conf)
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

TEAM_API_CONF="$(yq eval -r '.teams.api_conf' "$CONFIG_YAML")"
TEAMS_DEFAULT_TITLE="$(yq eval -r '.teams.default_title' "$CONFIG_YAML")"
TEAMS_DEFAULT_TARGET="$(yq eval -r '.teams.default_target' "$CONFIG_YAML")"
IS_TEST_MODE="$(yq eval -r '.teams.test_mode' "$CONFIG_YAML")"

: "${TEAM_API_CONF:?缺少設定: teams.api_conf}"
if [ -f "$TEAM_API_CONF" ]; then
    # shellcheck disable=SC1090
    source "$TEAM_API_CONF"
fi

: "${TEAM_API:?缺少設定: TEAM_API (由 teams.api_conf 載入)}"
WEBHOOK_URL="${TEAM_API}"
if [ -z "$WEBHOOK_URL" ]; then
    echo "錯誤: 未設定 TEAM_API，請檢查 ${SCRIPT_DIR}/config.yaml 或 ${TEAM_API_CONF}"
    exit 1
fi

# 2. 處理參數
: "${TEAMS_DEFAULT_TITLE:?缺少設定: teams.default_title}"
: "${TEAMS_DEFAULT_TARGET:?缺少設定: teams.default_target}"
: "${IS_TEST_MODE:?缺少設定: teams.test_mode}"
TITLE="${1:-$TEAMS_DEFAULT_TITLE}"
TARGET="${2:-$TEAMS_DEFAULT_TARGET}"
CONTENT_INPUT="$3"
IS_JSON="${4:-false}"
HOSTNAME=$(hostname)

# 3. 處理測試模式邏輯
# 優先使用環境變數中的 IS_TEST_MODE，若無則預設 false
FINAL_TITLE="${TITLE}"
if [ "$IS_TEST_MODE" == "true" ]; then
    FINAL_TITLE="【🛠️ 測試訊息】 ${TITLE}"
fi

# 4. 檢查輸入內容
if [ -z "$CONTENT_INPUT" ]; then
    echo "錯誤: 必須提供內容訊息"
    exit 1
fi

# 5. 處理內容主體
if [ "$IS_JSON" == "true" ]; then
    BODY_ELEMENT="$CONTENT_INPUT"
else
    ESCAPED_TEXT=$(echo "$CONTENT_INPUT" | jq -Rs .)
    BODY_ELEMENT="{\"type\": \"TextBlock\", \"text\": ${ESCAPED_TEXT}, \"wrap\": true}"
fi

# 6. 構建 Payload
PAYLOAD=$(cat <<EOF
{
    "type": "message",
    "attachments": [
        {
            "contentType": "application/vnd.microsoft.card.adaptive",
            "content": {
                "\$schema": "http://adaptivecards.io/schemas/adaptive-card.json",
                "type": "AdaptiveCard",
                "version": "1.2",
                "body": [
                    {
                        "type": "TextBlock",
                        "text": "${FINAL_TITLE}",
                        "size": "Large",
                        "weight": "Bolder",
                        "color": "Attention"
                    },
                    {
                        "type": "FactSet",
                        "facts": [
                            {"title": "主機:", "value": "${HOSTNAME}"},
                            {"title": "目標:", "value": "${TARGET}"},
                            {"title": "時間:", "value": "$(date '+%Y-%m-%d %H:%M:%S')"}
                        ]
                    },
                    {
                        "type": "TextBlock",
                        "text": " ",
                        "separator": true
                    },
                    ${BODY_ELEMENT}
                ]
            }
        }
    ]
}
EOF
)

# 7. 發送
curl -s -X POST -H "Content-Type: application/json" -d "$PAYLOAD" "$WEBHOOK_URL" > /dev/null
