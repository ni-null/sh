#!/bin/bash

set -uo pipefail

# =========================================================
# 基本路徑 / 天數設定
# =========================================================
SH_DIR=$(dirname "$(readlink -f "$0")")
CONFIG_YAML="${SH_DIR}/config.yaml"
if [ ! -f "$CONFIG_YAML" ]; then
    echo "錯誤: 找不到設定檔 $CONFIG_YAML"
    exit 1
fi
if ! command -v yq >/dev/null 2>&1; then
    echo "錯誤: 找不到 yq，請先安裝 mikefarah/yq"
    exit 1
fi

LOG_DIR="$(yq eval -r '.save_to_log.log_dir' "$CONFIG_YAML")"
CHECK_DAYS="$(yq eval -r '.save_to_log.check_days' "$CONFIG_YAML")"
KEEP_DAYS_AUDIT="$(yq eval -r '.save_to_log.keep_days_audit' "$CONFIG_YAML")"
KEEP_DAYS_ETC="$(yq eval -r '.save_to_log.keep_days_etc' "$CONFIG_YAML")"
KEEP_DAYS_JOURNAL="$(yq eval -r '.save_to_log.keep_days_journal' "$CONFIG_YAML")"
JOURNAL_SERVICE_PREFIXES_CSV="$(yq eval -r '.save_to_log.journal_service_prefixes // [] | join(",")' "$CONFIG_YAML")"

: "${LOG_DIR:?缺少設定: save_to_log.log_dir}"
: "${CHECK_DAYS:?缺少設定: save_to_log.check_days}"
: "${KEEP_DAYS_AUDIT:?缺少設定: save_to_log.keep_days_audit}"
: "${KEEP_DAYS_ETC:?缺少設定: save_to_log.keep_days_etc}"
: "${KEEP_DAYS_JOURNAL:?缺少設定: save_to_log.keep_days_journal}"

# =========================================================
# 容器 / 服務提取設定
# 方便統一維護，只改這一段即可
# =========================================================

# 方式 1：用前綴匹配 systemd service 名稱
# 例如 apidev-xxx.service
JOURNAL_SERVICE_PREFIXES=(
  "dsce"
)
if [ -n "${JOURNAL_SERVICE_PREFIXES_CSV}" ]; then
    IFS=',' read -r -a JOURNAL_SERVICE_PREFIXES <<< "$JOURNAL_SERVICE_PREFIXES_CSV"
fi

# 方式 2：直接指定明確 service 名稱
# 若有填值，會額外加入這些 service
JOURNAL_EXPLICIT_SERVICES=(
)

# journalctl 輸出格式，可自行改成 short-iso / short-full / json 等
JOURNAL_OUTPUT_FORMAT="short"

mkdir -p "$LOG_DIR"

log_info() { echo "[INFO] $1"; }
log_warn() { echo "[WARN] $1"; }
log_error() { echo "[ERROR] $1"; }

# =========================================================
# 執行狀態統計
# =========================================================
FAILED_TASKS=()
SUCCESS_TASKS=()

mark_success() {
    SUCCESS_TASKS+=("$1")
}

mark_failed() {
    FAILED_TASKS+=("$1")
}

run_task() {
    local task_name="$1"
    shift

    if "$@"; then
        mark_success "$task_name"
    else
        log_warn "${task_name} 失敗，但不中斷整體流程。"
        mark_failed "$task_name"
    fi
}

# =========================================================
# 共用工具
# =========================================================
safe_delete_old_logs() {
    local pattern="$1"
    local keep_days="$2"

    find "$LOG_DIR" -type f -name "$pattern" -mtime "+${keep_days}" -delete 2>/dev/null || true
}

build_journal_units() {
    local all_units=()
    local matched_units=()

    if ! command -v systemctl >/dev/null 2>&1; then
        return 0
    fi

    mapfile -t all_units < <(
        systemctl list-unit-files --type=service --no-legend 2>/dev/null | awk '{print $1}'
    )

    if [ "${#JOURNAL_SERVICE_PREFIXES[@]}" -gt 0 ]; then
        local unit prefix
        for unit in "${all_units[@]}"; do
            for prefix in "${JOURNAL_SERVICE_PREFIXES[@]}"; do
                if [[ "$unit" == "${prefix}-"*.service ]]; then
                    matched_units+=("$unit")
                    break
                fi
            done
        done
    fi

    if [ "${#JOURNAL_EXPLICIT_SERVICES[@]}" -gt 0 ]; then
        matched_units+=("${JOURNAL_EXPLICIT_SERVICES[@]}")
    fi

    if [ "${#matched_units[@]}" -eq 0 ]; then
        return 0
    fi

    printf '%s\n' "${matched_units[@]}" | awk '!seen[$0]++'
}

# =========================================================
# Audit 匯出
# =========================================================
run_audit_export() {
    log_info "開始提取 audit 真實檔案修改紀錄..."

    if [ ! -x /sbin/ausearch ]; then
        log_warn "找不到 /sbin/ausearch，略過 audit 匯出。"
        safe_delete_old_logs "Audit_*.json" "$KEEP_DAYS_AUDIT"
        return 0
    fi

    local search_start
    search_start=$(date -d "$((CHECK_DAYS-1)) days ago" +%m/%d/%Y)

    local date_list=()
    local i
    for ((i=0; i<CHECK_DAYS; i++)); do
        date_list+=("$(date -d "$i days ago" +%Y-%m-%d)")
    done

    # 關鍵修正：
    # ausearch 沒資料時常回傳非 0，在 pipefail 下會讓整支腳本退出
    # 所以只放寬 ausearch，不吞掉 awk 自己的錯誤
    if ! { /sbin/ausearch -ts "$search_start" 00:00:00 -i 2>/dev/null || true; } | LC_ALL=C awk \
        -v dates="${date_list[*]}" \
        -v log_dir="$LOG_DIR" '
BEGIN {
    split(dates, d_arr, " ")
    for (i in d_arr) {
        count[d_arr[i]] = 0
        target_dates[d_arr[i]] = 1
    }
}
/^----/ || /^type=/ {
    if (match($0, /audit\(([^)]+)\)/, m)) {
        id = m[1]
        if (last_id != "" && last_id != id) { process_event() }
        last_id = id
    }
}
{
    if (id != "") {
        line[id] = line[id] " " $0
    }
}
END {
    process_event()
    for (d in target_dates) {
        fpath = log_dir "/Audit_" d ".json"
        if (count[d] > 0) close_json(fpath, count[d], d)
        else printf ">> audit %s: 無有效檔案修改\n", d
    }
}
function extract_val(str, key, tmp, res, val) {
    if (match(str, key "=[^ ]+")) {
        tmp = substr(str, RSTART, RLENGTH)
        split(tmp, res, "=")
        val = res[2]
        gsub(/"/, "", val)
        if (val ~ /^\(?\[?\^/ || val == "(null)" || val ~ /^\(?\[/) return ""
        return val
    }
    return ""
}
function process_event() {
    if (last_id == "" || !(last_id in line)) return

    str = line[last_id]
    split(last_id, parts, " ")
    split(parts[1], d_parts, "/")

    if (length(d_parts) < 3) {
        delete line[last_id]
        return
    }

    cur_date = sprintf("%s-%s-%s", d_parts[3], d_parts[1], d_parts[2])
    if (!(cur_date in target_dates)) {
        delete line[last_id]
        return
    }

    user_name = extract_val(str, "auid")
    if (user_name == "" || user_name == "unset" || user_name == "4294967295") {
        delete line[last_id]
        return
    }

    comm = extract_val(str, "comm")
    if (comm == "") comm = extract_val(str, "exe")
    if (comm == "" || comm ~ /awk|ausearch|systemd|cron|less|cat|grep|tail|head|more|view/) {
        delete line[last_id]
        return
    }

    action = ""
    if (str ~ /nametype=DELETE/) action = "DELETE"
    else if (str ~ /nametype=CREATE/) action = "CREATE"
    else if (str ~ /syscall=(chmod|chown|fchmod|fchown|268)/) action = "ATTRIB"
    else if (str ~ /type=PATH.*nametype=NORMAL/ && str ~ /success=yes/ && str !~ /syscall=execve/) action = "MODIFY"

    if (action == "") {
        delete line[last_id]
        return
    }

    target = "N/A"
    n = split(str, p_items, "type=PATH")
    for (j=n; j>=2; j--) {
        if (p_items[j] ~ /nametype=PARENT/) continue
        target = extract_val(p_items[j], "name")
        if (target != "" && target != "?") break
    }

    if (target ~ /^\/?(lib|usr\/lib|dev|proc|run|bin|usr\/bin|sys)/ || target == "N/A") {
        delete line[last_id]
        return
    }

    write_record(log_dir "/Audit_" cur_date ".json", count[cur_date], parts[1] " " parts[2], action, user_name, comm, target)
    count[cur_date]++
    delete line[last_id]
}
function write_record(path, c, time, act, usr, cmd, file) {
    if (c == 0) print "[\n" > path
    else print ",\n" >> path
    printf "  {\n    \"timestamp\": \"%s\",\n    \"action\": \"%s\",\n    \"user\": \"%s\",\n    \"command\": \"%s\",\n    \"target\": \"%s\"\n  }", time, act, usr, cmd, file >> path
}
function close_json(path, c, d, cmd, fsize) {
    printf "\n]\n" >> path
    cmd = "du -sh " path " | awk \047{print $1}\047"
    cmd | getline fsize
    close(cmd)
    printf ">> audit %s: 完成 (大小: %s, 筆數: %d)\n", d, fsize, c
}
'; then
        log_warn "audit 匯出過程發生錯誤，但流程繼續。"
        safe_delete_old_logs "Audit_*.json" "$KEEP_DAYS_AUDIT"
        return 1
    fi

    safe_delete_old_logs "Audit_*.json" "$KEEP_DAYS_AUDIT"
    return 0
}

# =========================================================
# /etc 變更匯出
# =========================================================
run_etc_export() {
    log_info "開始提取 /etc 變更紀錄..."

    if ! command -v etckeeper >/dev/null 2>&1; then
        log_warn "etckeeper 未安裝，略過 /etc 變更紀錄。"
        safe_delete_old_logs "etc_change-*.log" "$KEEP_DAYS_ETC"
        return 0
    fi

    if ! command -v git >/dev/null 2>&1; then
        log_warn "git 未安裝，略過 /etc 變更紀錄。"
        safe_delete_old_logs "etc_change-*.log" "$KEEP_DAYS_ETC"
        return 0
    fi

    if [ ! -d /etc/.git ]; then
        log_warn "/etc 不是 git 倉庫，略過 /etc 變更紀錄。"
        safe_delete_old_logs "etc_change-*.log" "$KEEP_DAYS_ETC"
        return 0
    fi

    if etckeeper dirty >/dev/null 2>&1; then
        etckeeper commit "Auto-commit: $(date '+%Y-%m-%d %H:%M')" >/dev/null 2>&1 || true
    fi

    local i
    for ((i=0; i<CHECK_DAYS; i++)); do
        local target_date log_name
        target_date=$(date -d "$i days ago" +%Y-%m-%d)
        log_name="${LOG_DIR}/etc_change-${target_date}.log"

        if ! git -C /etc log \
            --since="${target_date} 00:00:00" \
            --until="${target_date} 23:59:59" \
            -p --patch-with-stat > "$log_name" 2>/dev/null; then
            rm -f "$log_name" 2>/dev/null || true
            log_warn "etc ${target_date}: git log 失敗，略過"
            continue
        fi

        if [ ! -s "$log_name" ]; then
            rm -f "$log_name" 2>/dev/null || true
            log_warn "etc ${target_date}: 無修改"
        else
            local size commits
            size=$(du -sh "$log_name" | awk '{print $1}' 2>/dev/null || echo "unknown")
            commits=$(git -C /etc rev-list --count --since="${target_date} 00:00:00" --until="${target_date} 23:59:59" HEAD 2>/dev/null || echo 0)
            log_info "etc ${target_date}: 完成 (大小: ${size}, 變更: ${commits})"
        fi
    done

    safe_delete_old_logs "etc_change-*.log" "$KEEP_DAYS_ETC"
    return 0
}

# =========================================================
# 容器 / service journal 匯出
# =========================================================
run_journal_export() {
    log_info "開始提取容器服務日誌..."

    if ! command -v systemctl >/dev/null 2>&1; then
        log_warn "systemctl 不存在，略過 journal 匯出。"
        safe_delete_old_logs "journal-containers-*.log" "$KEEP_DAYS_JOURNAL"
        return 0
    fi

    if ! command -v journalctl >/dev/null 2>&1; then
        log_warn "journalctl 不存在，略過 journal 匯出。"
        safe_delete_old_logs "journal-containers-*.log" "$KEEP_DAYS_JOURNAL"
        return 0
    fi

    mapfile -t units < <(build_journal_units || true)

    if [ "${#units[@]}" -eq 0 ]; then
        log_warn "找不到符合設定的 service，略過 journal 匯出。"
        safe_delete_old_logs "journal-containers-*.log" "$KEEP_DAYS_JOURNAL"
        return 0
    fi

    log_info "本次 journal 提取目標: ${units[*]}"

    local unit_args=()
    local u
    for u in "${units[@]}"; do
        unit_args+=("-u" "$u")
    done

    local i
    for ((i=0; i<CHECK_DAYS; i++)); do
        local target_date log_name
        target_date=$(date -d "$i days ago" +%Y-%m-%d)
        log_name="${LOG_DIR}/journal-containers-${target_date}.log"

        if ! journalctl "${unit_args[@]}" \
            --since "${target_date} 00:00:00" \
            --until "${target_date} 23:59:59" \
            --no-pager --quiet \
            --output "$JOURNAL_OUTPUT_FORMAT" > "$log_name" 2>/dev/null; then
            rm -f "$log_name" 2>/dev/null || true
            log_warn "journal ${target_date}: 匯出失敗"
            continue
        fi

        if [ ! -s "$log_name" ]; then
            rm -f "$log_name" 2>/dev/null || true
            log_warn "journal ${target_date}: 無日誌"
        else
            local size lines
            size=$(du -sh "$log_name" | awk '{print $1}' 2>/dev/null || echo "unknown")
            lines=$(wc -l < "$log_name" 2>/dev/null || echo 0)
            log_info "journal ${target_date}: 完成 (大小: ${size}, 筆數: ${lines})"
        fi
    done

    safe_delete_old_logs "journal-containers-*.log" "$KEEP_DAYS_JOURNAL"
    return 0
}

# =========================================================
# 主流程
# =========================================================
print_summary() {
    echo
    log_info "================ 執行摘要 ================"

    if [ "${#SUCCESS_TASKS[@]}" -gt 0 ]; then
        log_info "成功項目: ${SUCCESS_TASKS[*]}"
    else
        log_warn "成功項目: 無"
    fi

    if [ "${#FAILED_TASKS[@]}" -gt 0 ]; then
        log_warn "失敗項目: ${FAILED_TASKS[*]}"
    else
        log_info "失敗項目: 無"
    fi

    log_info "========================================"
}

main() {
    log_info "saveTolog merged job start: $(date '+%Y-%m-%d %H:%M:%S')"

    run_task "audit_export" run_audit_export
    run_task "etc_export" run_etc_export
    run_task "journal_export" run_journal_export

    print_summary
    log_info "saveTolog merged job done."
}

main "$@"
