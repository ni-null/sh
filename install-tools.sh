#!/usr/bin/env bash
set -Eeuo pipefail

# =========================
# 彩色高亮設定
# =========================
RED='\033[1;91m'
GREEN='\033[1;92m'
YELLOW='\033[1;93m'
BLUE='\033[1;94m'
CYAN='\033[1;96m'
WHITE='\033[1;97m'
GRAY='\033[1;90m'
RESET='\033[0m'
BOLD='\033[1m'

OK="${GREEN}${BOLD}"
WARN="${YELLOW}${BOLD}"
ERR="${RED}${BOLD}"
INFO="${BLUE}${BOLD}"
TITLE="${CYAN}${BOLD}"

# =========================
# 套件清單
# =========================
PACKAGES=("etckeeper" "borgbackup" "yq")

declare -A STATUS
declare -A VERSION

# =========================
# 基本工具
# =========================
need_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    echo -e "${ERR}請用 root 執行，或使用 sudo：${RESET}"
    echo -e "  ${WHITE}sudo bash $0${RESET}"
    exit 1
  fi
}

has_cmd() {
  command -v "$1" >/dev/null 2>&1
}

cmd_name() {
  local name="$1"

  case "$name" in
    borgbackup)
      echo "borg"
      ;;
    *)
      echo "$name"
      ;;
  esac
}

get_version() {
  local name="$1"

  case "$name" in
    etckeeper)
      etckeeper -v 2>/dev/null \
        | sed 's/^Version:[[:space:]]*//' \
        | head -n 1 || echo "未知"
      ;;
    borgbackup)
      borg --version 2>/dev/null \
        | sed 's/^borg //' \
        | head -n 1 || echo "未知"
      ;;
    yq)
      yq --version 2>/dev/null \
        | sed 's#yq (https://github.com/mikefarah/yq/) version ##' \
        | head -n 1 || echo "未知"
      ;;
    *)
      echo "未知"
      ;;
  esac
}

color_status() {
  local text="$1"

  case "$text" in
    已安裝*|安裝完成*)
      echo -e "${OK}${text}${RESET}"
      ;;
    正在安裝*|正在更新*)
      echo -e "${WARN}${text}${RESET}"
      ;;
    未安裝*|等待中*)
      echo -e "${GRAY}${text}${RESET}"
      ;;
    失敗*|安裝失敗*)
      echo -e "${ERR}${text}${RESET}"
      ;;
    *)
      echo -e "${WHITE}${text}${RESET}"
      ;;
  esac
}

draw_screen() {
  clear || true

  echo -e "${TITLE}套件安裝狀態${RESET}"
  echo -e "${GRAY}──────────────────────────────────────────────${RESET}"
  printf "%-12s %-12s %s\n" "套件" "狀態" "版本"
  echo -e "${GRAY}──────────────────────────────────────────────${RESET}"

  for pkg in "${PACKAGES[@]}"; do
    local status="${STATUS[$pkg]:-等待中}"
    local version="${VERSION[$pkg]:-}"

    printf "%-12s " "$pkg"

    case "$status" in
      已安裝|安裝完成)
        printf "${OK}%-12s${RESET} " "$status"
        ;;
      正在安裝*|正在更新*)
        printf "${WARN}%-12s${RESET} " "$status"
        ;;
      未安裝|等待中)
        printf "${GRAY}%-12s${RESET} " "$status"
        ;;
      安裝失敗*|失敗*)
        printf "${ERR}%-12s${RESET} " "$status"
        ;;
      *)
        printf "${WHITE}%-12s${RESET} " "$status"
        ;;
    esac

    printf "${GRAY}%s${RESET}\n" "$version"
  done

  echo -e "${GRAY}──────────────────────────────────────────────${RESET}"
}


set_status() {
  local pkg="$1"
  local text="$2"

  STATUS["$pkg"]="$text"
  draw_screen
}

set_version() {
  local pkg="$1"
  local version="$2"

  VERSION["$pkg"]="$version"
}

# =========================
# 初始檢測：優先確認版本
# =========================
detect_package_status() {
  local pkg="$1"
  local cmd
  cmd="$(cmd_name "$pkg")"

  if has_cmd "$cmd"; then
    set_version "$pkg" "$(get_version "$pkg")"
    STATUS["$pkg"]="已安裝"
  else
    set_version "$pkg" ""
    STATUS["$pkg"]="未安裝"
  fi
}

detect_all_packages() {
  for pkg in "${PACKAGES[@]}"; do
    detect_package_status "$pkg"
  done

  draw_screen
}

need_apt_update() {
  ! has_cmd etckeeper || ! has_cmd borg
}

# =========================
# apt 安裝
# =========================
apt_install_package() {
  local pkg="$1"
  local cmd
  cmd="$(cmd_name "$pkg")"

  if has_cmd "$cmd"; then
    set_version "$pkg" "$(get_version "$pkg")"
    set_status "$pkg" "已安裝"
    return 0
  fi

  set_version "$pkg" ""
  set_status "$pkg" "正在安裝..."

  if DEBIAN_FRONTEND=noninteractive apt-get install -y "$pkg" >/dev/null; then
    if has_cmd "$cmd"; then
      set_version "$pkg" "$(get_version "$pkg")"
      set_status "$pkg" "安裝完成"
    else
      set_status "$pkg" "安裝失敗，找不到指令"
      return 1
    fi
  else
    set_status "$pkg" "安裝失敗"
    return 1
  fi
}

# =========================
# yq 安裝
# 使用 mikefarah/yq GitHub release
# =========================
install_yq() {
  if has_cmd yq; then
    set_version "yq" "$(get_version yq)"
    set_status "yq" "已安裝"
    return 0
  fi

  local dots=0
  local arch
  local url

  arch="$(dpkg --print-architecture)"

  case "$arch" in
    amd64)
      url="https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64"
      ;;
    arm64)
      url="https://github.com/mikefarah/yq/releases/latest/download/yq_linux_arm64"
      ;;
    armhf)
      url="https://github.com/mikefarah/yq/releases/latest/download/yq_linux_arm"
      ;;
    *)
      set_status "yq" "安裝失敗，不支援架構 ${arch}"
      return 1
      ;;
  esac

  (
    set -Eeuo pipefail

    if has_cmd curl; then
      curl -fsSL "$url" -o /usr/local/bin/yq
    elif has_cmd wget; then
      wget -q "$url" -O /usr/local/bin/yq
    else
      DEBIAN_FRONTEND=noninteractive apt-get install -y curl >/dev/null
      curl -fsSL "$url" -o /usr/local/bin/yq
    fi

    chmod +x /usr/local/bin/yq
  ) &

  local pid=$!

  while kill -0 "$pid" 2>/dev/null; do
    dots=$(( (dots + 1) % 4 ))

    case "$dots" in
      0) set_status "yq" "正在安裝" ;;
      1) set_status "yq" "正在安裝." ;;
      2) set_status "yq" "正在安裝.." ;;
      3) set_status "yq" "正在安裝..." ;;
    esac

    sleep 0.35
  done

  if wait "$pid"; then
    if has_cmd yq; then
      set_version "yq" "$(get_version yq)"
      set_status "yq" "安裝完成"
    else
      set_status "yq" "安裝失敗，找不到指令"
      return 1
    fi
  else
    set_status "yq" "安裝失敗"
    return 1
  fi
}

# =========================
# 主流程
# =========================
main() {
  need_root

  # 先檢測版本，避免一開始長時間顯示等待中
  detect_all_packages

  # 只有 apt 套件缺少時才更新 apt index
  if need_apt_update; then
    set_status "etckeeper" "正在更新套件索引..."
    apt-get update -y >/dev/null
    detect_all_packages
  fi

  apt_install_package "etckeeper"
  apt_install_package "borgbackup"
  install_yq

  echo
  echo -e "${OK}全部檢測 / 安裝完成${RESET}"
}

main "$@"
