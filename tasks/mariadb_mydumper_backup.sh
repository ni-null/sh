#!/bin/bash

# ============================================================
# 🧾 MariaDB 多實例備份腳本（mydumper + Podman）
# ============================================================
# 📦 備份工具：docker.io/mydumper/mydumper:v0.21.3-1
# 🗄️ 備份目標：
#   - dsce-mariadb (127.0.0.1:13306) → /srv/dsce/.env
#   - api-mariadb  (127.0.0.1:23306) → /srv/api/.env
# 📁 備份路徑：/srv/backup-db/mydumper
# ♻️ 保留天數：7 天
# ============================================================


# =========================
# 🔧 基本設定（集中）
# =========================
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

MYDUMPER_IMAGE="$(yq eval -r '.mydumper.image' "$CONFIG_YAML")"
MYDUMPER_BACKUP_BASE="$(yq eval -r '.mydumper.backup_base' "$CONFIG_YAML")"
MYDUMPER_RETENTION_DAYS="$(yq eval -r '.mydumper.retention_days' "$CONFIG_YAML")"
MYDUMPER_DATABASES="$(yq eval -r '.mydumper.databases // [] | map(.name + ":" + (.port|tostring) + ":" + .env_file) | join(",")' "$CONFIG_YAML")"
PODMAN_BIN="/usr/bin/podman"

: "${MYDUMPER_IMAGE:?缺少設定: mydumper.image}"
: "${MYDUMPER_BACKUP_BASE:?缺少設定: mydumper.backup_base}"
: "${MYDUMPER_RETENTION_DAYS:?缺少設定: mydumper.retention_days}"
: "${MYDUMPER_DATABASES:?缺少設定: mydumper.databases}"
MYDUMPER_IMAGE="${MYDUMPER_IMAGE}"
BACKUP_BASE="${MYDUMPER_BACKUP_BASE}"
RETENTION_DAYS="${MYDUMPER_RETENTION_DAYS}"
DB_USER="root"
MYDUMPER_THREADS="4"
MYDUMPER_HOST="127.0.0.1"

# 名稱:port:env_file
DATABASES=(
  "dsce-mariadb:13306:/srv/dsce/.env"
)
if [ -n "${MYDUMPER_DATABASES}" ]; then
  IFS=',' read -r -a DATABASES <<< "$MYDUMPER_DATABASES"
fi

# =========================
# ⚙️ 系統變數
# =========================
TIMESTAMP=$(date +%Y_%m_%d)

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

# =========================
# 📁 建立備份目錄
# =========================
mkdir -p "$BACKUP_BASE"

log "========== 🚀 開始 MariaDB 備份 =========="

# =========================
# 🔄 逐一備份
# =========================
for DB in "${DATABASES[@]}"; do

  NAME=$(echo "$DB" | cut -d: -f1)
  PORT=$(echo "$DB" | cut -d: -f2)
  ENV_FILE_DB=$(echo "$DB" | cut -d: -f3)

  OUTPUT_DIR="${BACKUP_BASE}/${NAME}-${TIMESTAMP}"

  log "---------- 📦 備份 ${NAME} ----------"
  log "Port：${PORT}"
  log "Env：${ENV_FILE_DB}"

  # 檢查 env
  if [ ! -f "$ENV_FILE_DB" ]; then
    log "❌ 找不到 env：$ENV_FILE_DB"
    continue
  fi

  # 讀取密碼
  DB_PASS_LINE=$(grep -m1 -E '^MARIADB_ROOT_PASSWORD=' "$ENV_FILE_DB" || true)
  DB_PASS="${DB_PASS_LINE#MARIADB_ROOT_PASSWORD=}"
  DB_PASS="${DB_PASS%$'\r'}"

  # 支援 .env 中使用單引號或雙引號包覆密碼值
  if [[ "$DB_PASS" == \"*\" ]]; then
    DB_PASS="${DB_PASS#\"}"
    DB_PASS="${DB_PASS%\"}"
  elif [[ "$DB_PASS" == \'*\' ]]; then
    DB_PASS="${DB_PASS#\'}"
    DB_PASS="${DB_PASS%\'}"
  fi

  if [ -z "$DB_PASS" ]; then
    log "❌ 無法讀取密碼（$ENV_FILE_DB）"
    continue
  fi

  # 已存在 → 跳過
  if [ -d "$OUTPUT_DIR" ] && [ -n "$(ls -A "$OUTPUT_DIR")" ]; then
    log "⚠️ 已存在備份，跳過"
    continue
  fi

  mkdir -p "$OUTPUT_DIR"

  # 執行備份
  "$PODMAN_BIN" run --rm \
    --network host \
    -e "MYSQL_PWD=${DB_PASS}" \
    -v "${OUTPUT_DIR}:/backup" \
    "$MYDUMPER_IMAGE" \
    mydumper \
      --host "$MYDUMPER_HOST" \
      --user "$DB_USER" \
      --port "$PORT" \
      --outputdir /backup \
      --compress \
      --threads "$MYDUMPER_THREADS" \
      --trx-tables=0 \
      --verbose 2

  EXIT_CODE=$?

  # 成功 / 失敗
  if [ $EXIT_CODE -eq 0 ] && [ -n "$(ls -A "$OUTPUT_DIR")" ]; then
    SIZE=$(du -sh "$OUTPUT_DIR" | cut -f1)
    log "✅ 成功：${NAME}（$SIZE）"
  else
    log "❌ 失敗：${NAME}"
    rm -rf "$OUTPUT_DIR"
  fi

done

# =========================
# 🧹 清理舊備份
# =========================
log "🧹 清理 ${RETENTION_DAYS} 天前備份..."

find "$BACKUP_BASE" -mindepth 1 -maxdepth 1 -type d -mtime +${RETENTION_DAYS} | while read f; do
  rm -rf "$f"
  log "🗑️ 已刪除：$f"
done

log "========== 🎉 全部完成 =========="
