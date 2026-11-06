#!/bin/bash
# 掃描 Quadlet 容器狀態，發現異常時發送 Teams 通知。
#
# 用法：
#   report_pod_status.sh [通知標題]
#
# 注意：此腳本適用於 root 管理的 Quadlet 容器。

CONF_ROOT="/etc/containers/systemd"
TEAM_CONF="/usr/local/bin/teamapi.conf"
HOST_NAME="$(hostname)"
TITLE="${1:-Podman 容器狀態異常}"

log() {
    printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

if [ ! -d "$CONF_ROOT" ]; then
    log "錯誤：找不到 Quadlet 目錄 $CONF_ROOT"
    exit 1
fi

if [ ! -r "$TEAM_CONF" ]; then
    log "錯誤：無法讀取通知設定 $TEAM_CONF"
    exit 1
fi

if ! command -v podman >/dev/null 2>&1; then
    log "錯誤：找不到 podman"
    exit 1
fi

# 載入 teamapi.conf 中的 notify 函式。
source "$TEAM_CONF"

if ! declare -F notify >/dev/null; then
    log "錯誤：$TEAM_CONF 中找不到 notify 函式"
    exit 1
fi

# 先確認 Podman 可正常存取，避免將整台主機誤判為容器不存在。
if ! podman ps -a --format '{{.Names}}' >/dev/null; then
    log "錯誤：無法取得 Podman 容器清單"
    exit 1
fi

log "開始檢查 $CONF_ROOT"

count=0
abnormal_count=0
details=""

while IFS= read -r -d '' container_file; do
    count=$((count + 1))

    # 讀取 [Container] 區塊中的 ContainerName。
    container_name=$(
        awk '
            /^[[:space:]]*\[/ {
                in_container = ($0 ~ /^[[:space:]]*\[Container\][[:space:]]*$/)
                next
            }
            in_container && /^[[:space:]]*ContainerName[[:space:]]*=/ {
                sub(/^[^=]*=/, "")
                sub(/^[[:space:]]+/, "")
                sub(/[[:space:]]+$/, "")
                name = $0
            }
            END { print name }
        ' "$container_file"
    )

    # Quadlet 沒有設定 ContainerName 時，預設為 systemd-<檔名>。
    if [ -z "$container_name" ]; then
        base_name="$(basename "$container_file" .container)"
        container_name="systemd-${base_name}"
    fi

    if ! podman container exists "$container_name"; then
        log "異常：$container_name 不存在 ($container_file)"
        abnormal_count=$((abnormal_count + 1))
        details="${details} ${container_name}：容器不存在；"
        continue
    fi

    state=$(podman inspect "$container_name" \
        --format '{{.State.Status}}' 2>/dev/null) || {
        log "異常：無法讀取 $container_name 狀態"
        abnormal_count=$((abnormal_count + 1))
        details="${details} ${container_name}：無法讀取狀態；"
        continue
    }

    if [ "$state" != "running" ]; then
        exit_code=$(podman inspect "$container_name" \
            --format '{{.State.ExitCode}}' 2>/dev/null || printf '未知')

        log "異常：$container_name 狀態=$state 退出碼=$exit_code"
        abnormal_count=$((abnormal_count + 1))
        details="${details} ${container_name}：${state}，退出碼 ${exit_code}；"
        continue
    fi

    # 沒有設定健康檢查的容器，health 可能為空。
    health=$(podman inspect "$container_name" \
        --format '{{if .State.Health}}{{.State.Health.Status}}{{end}}' \
        2>/dev/null || true)

    if [ "$health" = "unhealthy" ]; then
        log "異常：$container_name 健康狀態為 unhealthy"
        abnormal_count=$((abnormal_count + 1))
        details="${details} ${container_name}：unhealthy；"
        continue
    fi

    log "正常：$container_name 狀態=$state 健康狀態=${health:-未設定}"
done < <(find "$CONF_ROOT" -type f -name '*.container' -print0)

if [ "$count" -eq 0 ]; then
    log "警告：沒有找到 .container 檔案"
    exit 1
fi

if [ "$abnormal_count" -eq 0 ]; then
    log "檢查完成：共 $count 個容器，未發現異常"
    exit 0
fi

message="🚨 ${HOST_NAME}：${TITLE}。檢查 ${count} 個容器，發現 ${abnormal_count} 個異常。${details} 請登入主機檢查。"

log "發現 $abnormal_count 個異常，準備發送通知"

if notify "$message"; then
    log "通知請求已送出；請以 Teams 實際收到為準"
else
    log "錯誤：通知請求失敗"
    exit 1
fi

log "檢查完成"
