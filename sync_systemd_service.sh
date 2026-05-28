#!/bin/bash
set -euo pipefail

# 定義顏色與格式
GREEN='\033[0;32m'
GRAY='\033[0;90m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# --- 設定區 ---
readonly SH_DIR="/srv/sh"                            # 腳本根目錄
readonly SRC_DIR="$SH_DIR/systemd_service"           # Systemd 檔案來源
readonly DEST_DIR="/etc/systemd/system"              # Systemd 系統目錄

# --- 輔助函式：列印狀態行 ---
print_row() {
    # $1=Name, $2=ServiceStatus, $3=TimerStatus
    printf " %-28s %-22b %-20b\n" "$1" "$2" "$3"
}

is_safe_unit_path() {
    local p="$1"
    case "$p" in
        "$DEST_DIR"/*.service|"$DEST_DIR"/*.timer) return 0 ;;
        *) return 1 ;;
    esac
}

safe_remove_symlink() {
    local target="$1"
    if ! is_safe_unit_path "$target"; then
        echo -e "${YELLOW}[SKIP] 非白名單路徑，拒絕刪除: $target${NC}"
        return 1
    fi
    if [ -L "$target" ]; then
        sudo unlink -- "$target"
    fi
}

clear
echo "========================================================="
echo " 🔄 Systemd 同步與部署工具   [$(date '+%Y-%m-%d %H:%M')]"
echo "========================================================="

# 檢查來源目錄
if [ ! -d "$SRC_DIR" ]; then
    echo -e "${YELLOW}錯誤: 找不到原始資料夾 $SRC_DIR${NC}"
    exit 1
fi

# 防呆：避免目標目錄錯設時觸發任何刪改
if [ "$DEST_DIR" != "/etc/systemd/system" ] || [ ! -d "$DEST_DIR" ]; then
    echo -e "${YELLOW}錯誤: DEST_DIR 非預期或不存在: $DEST_DIR${NC}"
    exit 1
fi

cd "$SRC_DIR" || exit

# ---------------------------------------------------------
# [1/3] 同步設定檔
# ---------------------------------------------------------
printf "\n[1/3] 同步設定檔 (建立連結)\n"
echo "---------------------------------------------------------"

for unit_file in *.service *.timer; do
    [ -e "$unit_file" ] || continue
    TARGET_LINK="$DEST_DIR/$unit_file"
    FULL_SRC_PATH="$SRC_DIR/$unit_file"
    
    ACTION_MSG="已更新連結"
    
    # 邏輯處理
    if [ -L "$TARGET_LINK" ]; then
        safe_remove_symlink "$TARGET_LINK" || continue
    elif [ -f "$TARGET_LINK" ]; then
        if ! is_safe_unit_path "$TARGET_LINK"; then
            printf " ${YELLOW}[FAIL]${NC} %-30s → 非白名單目標，拒絕覆蓋\n" "$unit_file"
            continue
        fi
        sudo mv -- "$TARGET_LINK" "$TARGET_LINK.bak"
        ACTION_MSG="備份舊檔並更新"
    fi
    
    if sudo ln -s -- "$FULL_SRC_PATH" "$TARGET_LINK"; then
        # 簡潔輸出
        printf " ${GREEN}[OK]${NC} %-30s → %s\n" "$unit_file" "$ACTION_MSG"
    else
        printf " ${YELLOW}[FAIL]${NC} %-30s → 建立連結失敗\n" "$unit_file"
    fi
done

# ---------------------------------------------------------
# [2/3] 系統重載與權限設定
# ---------------------------------------------------------
printf "\n[2/3] 重新載入與賦權\n"
echo "---------------------------------------------------------"

# 1. Daemon Reload
printf " -> %-35s " "Systemd Daemon Reload ..."
if sudo systemctl daemon-reload; then
    echo -e "[${GREEN}OK${NC}]"
else
    echo -e "[${YELLOW}FAIL${NC}]"
fi

# 2. Enable Timers
printf " -> %-35s " "啟用所有 Timer (*.timer) ..."
TIMER_COUNT=0
TIMER_FAIL_COUNT=0
for timer_file in *.timer; do
    [ -e "$timer_file" ] || continue
    if sudo systemctl enable --now "$timer_file" > /dev/null 2>&1; then
        TIMER_COUNT=$((TIMER_COUNT + 1))
    else
        TIMER_FAIL_COUNT=$((TIMER_FAIL_COUNT + 1))
    fi
done
if [ "$TIMER_FAIL_COUNT" -eq 0 ]; then
    echo -e "[${GREEN}OK${NC}] (成功 $TIMER_COUNT 個)"
else
    echo -e "[${YELLOW}WARN${NC}] (成功 $TIMER_COUNT 個, 失敗 $TIMER_FAIL_COUNT 個)"
fi

# 3. Chmod .sh files
printf " -> %-35s " "賦予腳本執行權限 (+x) ..."
shopt -s nullglob
SCRIPT_FILES=("$SH_DIR"/*.sh "$SH_DIR"/tasks/*.sh)
shopt -u nullglob
if [ ${#SCRIPT_FILES[@]} -gt 0 ]; then
    sudo chmod +x "${SCRIPT_FILES[@]}"
    echo -e "[${GREEN}OK${NC}]"
else
    echo -e "[${GRAY}SKIP${NC}] (無 .sh 檔)"
fi

# ---------------------------------------------------------
# [3/3] 服務狀態總覽 (表格化)
# ---------------------------------------------------------
printf "\n[3/3] 服務狀態總覽\n"
echo "---------------------------------------------------------------------------"
printf " %-28s %-15s %-15s\n" "UNIT NAME" "SERVICE STATUS" "TIMER STATUS"
echo "---------------------------------------------------------------------------"

PROCESSED_TIMERS=()

# 遍歷所有 Service 檔案
for service_file in *.service; do
    [ -e "$service_file" ] || continue
    
    # 取得基礎名稱 (移除 .service)
    BASE_NAME="${service_file%.service}"
    TIMER_NAME="${BASE_NAME}.timer"
    
    # 1. 取得 Service 狀態
    S_STATE=$(sudo systemctl is-active "$service_file" 2>/dev/null | head -n1)
    
    # 格式化 Service 顯示
    S_DISPLAY="(${S_STATE})"
    [[ "$S_STATE" == "active" ]] && S_DISPLAY="(${GREEN}active${NC})"
    
    # 特殊處理樣板 (@)
    if [[ "$service_file" == *"@"* ]]; then
        print_row "$service_file" "${CYAN}[樣板/Template]${NC}" "${GRAY}-${NC}"
        continue
    fi

    # 2. 取得 Timer 狀態 (如果對應的 timer 檔案存在)
    T_DISPLAY="${GRAY}-${NC}"
    if [ -e "$TIMER_NAME" ]; then
        T_STATE=$(sudo systemctl is-active "$TIMER_NAME" 2>/dev/null | head -n1)
        
        # 格式化 Timer 顯示
        DOT="○"
        [[ "$T_STATE" == "active" ]] && DOT="${GREEN}●${NC}"
        
        T_DISPLAY="$DOT $T_STATE"
        PROCESSED_TIMERS+=("$TIMER_NAME")
    fi

    print_row "$BASE_NAME" "$S_DISPLAY" "$T_DISPLAY"
done

# 檢查是否有「只有 Timer 但沒有對應 Service」的孤兒 Timer
for timer_file in *.timer; do
    [ -e "$timer_file" ] || continue
    # 如果這個 timer 已經在上面處理過，就跳過
    if [[ " ${PROCESSED_TIMERS[@]} " =~ " ${timer_file} " ]]; then
        continue
    fi
    
    # 顯示孤兒 Timer
    T_STATE=$(sudo systemctl is-active "$timer_file" 2>/dev/null | head -n1)
    DOT="○"
    [[ "$T_STATE" == "active" ]] && DOT="${GREEN}●${NC}"
    
    print_row "${timer_file}" "${GRAY}(無 Service)${NC}" "$DOT $T_STATE"
done

echo "---------------------------------------------------------------------------"
echo -e "✅ 全部完成"
echo ""
