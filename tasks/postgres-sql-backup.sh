#!/usr/bin/env bash
set -euo pipefail

CONFIG="/srv/sh/tasks/config.yaml"

BACKUP_DIR=$(python3 - <<'PY'
import yaml
with open("/srv/sh/tasks/config.yaml") as f:
    c = yaml.safe_load(f)
print(c["postgres_sql"]["backup_dir"])
PY
)

RETENTION_DAYS=$(python3 - <<'PY'
import yaml
with open("/srv/sh/tasks/config.yaml") as f:
    c = yaml.safe_load(f)
print(c["postgres_sql"].get("retention_days", 7))
PY
)

mkdir -p "$BACKUP_DIR"

python3 - <<'PY' | while IFS='|' read -r CONTAINER USER; do
import yaml
with open("/srv/sh/tasks/config.yaml") as f:
    c = yaml.safe_load(f)

for item in c["postgres_sql"]["containers"]:
    print(f'{item["name"]}|{item.get("user", "postgres")}')
PY

  TS=$(date +"%Y-%m-%d_%H%M%S")
  OUT="$BACKUP_DIR/${CONTAINER}-${TS}.sql.gz"

  echo "[INFO] Start PostgreSQL dump: $CONTAINER"

  podman exec "$CONTAINER" pg_dumpall -U "$USER" \
    | gzip -9 > "$OUT"

  echo "[INFO] Backup done: $OUT"

done

echo "[INFO] Cleanup old backups (> ${RETENTION_DAYS} days)"
find "$BACKUP_DIR" -type f -name "*.sql.gz" -mtime +"$RETENTION_DAYS" -delete

echo "[INFO] PostgreSQL backup finished successfully."
