#!/usr/bin/env bash
#=================================================================#
#   Description: Manage Xray multi-port Shadowsocks:              #
#                - One-click change ports                         #
#                - One-click full uninstall (including Xray)      #
#=================================================================#

set -euo pipefail

CONFIG_FILE="/usr/local/etc/xray/config.json"
SERVICE_NAME="xray"

red='\033[0;31m'
green='\033[0;32m'
yellow='\033[0;33m'
plain='\033[0m'

require_root() {
  if [[ $EUID -ne 0 ]]; then
    echo -e "[${red}Error${plain}] This script must be run as root."
    exit 1
  fi
}

check_deps() {
  if ! command -v jq >/dev/null 2>&1; then
    echo -e "[${red}Error${plain}] jq is required. Install it via: apt install -y jq"
    exit 1
  fi
}

check_config() {
  if [[ ! -f "$CONFIG_FILE" ]]; then
    echo -e "[${red}Error${plain}] Xray config not found: $CONFIG_FILE"
    exit 1
  fi
}

restart_service() {
  echo -e "[${green}Info${plain}] Restarting service: ${SERVICE_NAME}"
  if command -v systemctl >/dev/null 2>&1; then
    systemctl restart "$SERVICE_NAME"
    sleep 1
    if systemctl is-active "$SERVICE_NAME" >/dev/null 2>&1; then
      echo -e "[${green}OK${plain}] Service restarted."
    else
      echo -e "[${red}Error${plain}] Service failed to restart. Check: systemctl status ${SERVICE_NAME}"
    fi
  else
    service "$SERVICE_NAME" restart || true
  fi
}

show_current_ports() {
  if [[ ! -f "$CONFIG_FILE" ]]; then
    echo -e "[${yellow}Warn${plain}] Config not found: $CONFIG_FILE"
    return 0
  fi

  local p4 p6 pleg
  p4=$(jq -r '.inbounds[] | select(.tag=="ss-ipv4")   | .port' "$CONFIG_FILE" 2>/dev/null || echo "N/A")
  p6=$(jq -r '.inbounds[] | select(.tag=="ss-ipv6")   | .port' "$CONFIG_FILE" 2>/dev/null || echo "N/A")
  pleg=$(jq -r '.inbounds[] | select(.tag=="ss-legacy") | .port' "$CONFIG_FILE" 2>/dev/null || echo "N/A")
  echo -e "Current ports:"
  echo "  IPv4   (ss-ipv4)   : ${p4}"
  echo "  IPv6   (ss-ipv6)   : ${p6}"
  echo "  Legacy (ss-legacy) : ${pleg}"
}

change_ports() {
  require_root
  check_deps
  check_config

  echo -e "[${green}Info${plain}] Changing ports for ss-ipv4 / ss-ipv6 / ss-legacy"
  show_current_ports
  echo

  read -rp "New IPv4 SS-2022 port [leave empty to keep current]: " new_p4
  read -rp "New IPv6 SS-2022 port [leave empty to keep current]: " new_p6
  read -rp "New Legacy AES-256-GCM port [leave empty to keep current]: " new_pleg

  # helper: validate and apply port
  apply_port() {
    local tag="$1"
    local port="$2"

    if [[ -z "$port" ]]; then
      echo "  ${tag}: keep current."
      return 0
    fi

    if ! [[ "$port" =~ ^[0-9]+$ ]] || (( port <= 0 || port > 65535 )); then
      echo -e "[${red}Error${plain}] Invalid port for ${tag}: ${port}"
      exit 1
    fi

    # update JSON via jq
    local tmp
    tmp=$(mktemp)
    jq --arg tag "$tag" --argjson p "$port" '
      .inbounds = (.inbounds | map(
        if .tag == $tag then .port = $p else . end
      ))
    ' "$CONFIG_FILE" > "$tmp"
    mv "$tmp" "$CONFIG_FILE"
    echo "  ${tag}: set to ${port}"
  }

  apply_port "ss-ipv4"   "$new_p4"
  apply_port "ss-ipv6"   "$new_p6"
  apply_port "ss-legacy" "$new_pleg"

  restart_service
  echo -e "[${green}Done${plain}] Ports updated. Remember to update your clients."
}

# 从 config.json 中读出当前端口，方便卸载时尝试关闭 UFW 规则
get_ports_from_config() {
  if [[ ! -f "$CONFIG_FILE" ]]; then
    return 0
  fi
  PORT_V4=$(jq -r '.inbounds[] | select(.tag=="ss-ipv4")   | .port' "$CONFIG_FILE" 2>/dev/null || echo "")
  PORT_V6=$(jq -r '.inbounds[] | select(.tag=="ss-ipv6")   | .port' "$CONFIG_FILE" 2>/dev/null || echo "")
  PORT_LEGACY=$(jq -r '.inbounds[] | select(.tag=="ss-legacy") | .port' "$CONFIG_FILE" 2>/dev/null || echo "")
}

cleanup_ufw_rules() {
  if ! command -v ufw >/dev/null 2>&1; then
    return 0
  fi

  get_ports_from_config || true

  for p in "$PORT_V4" "$PORT_V6" "$PORT_LEGACY"; do
    [[ -z "$p" || "$p" == "null" ]] && continue
    # 尝试删除规则（不保证一定删除成功）
    ufw delete allow "${p}"/tcp >/dev/null 2>&1 || true
    ufw delete allow "${p}"/udp >/dev/null 2>&1 || true
  done
}

cleanup_sysctl_bbr() {
  # 删除 install.sh 中添加的两行
  sed -i '/^net.core.default_qdisc=fq$/d' /etc/sysctl.conf || true
  sed -i '/^net.ipv4.tcp_congestion_control=bbr$/d' /etc/sysctl.conf || true
  sysctl -p >/dev/null 2>&1 || true
}

uninstall_xray_full() {
  require_root

  echo -e "[${yellow}Warning${plain}] 即将卸载由本脚本安装的 Xray 部署："
  echo "  - 停止并禁用 xray 服务"
  echo "  - 删除 Xray systemd 单元（如存在）"
  echo "  - 删除配置目录 /usr/local/etc/xray"
  echo "  - 删除日志目录 /var/log/xray"
  echo "  - 尝试移除 UFW 中开放的相关端口"
  echo "  - 尝试移除 /etc/sysctl.conf 中的 BBR 配置行"
  echo "  - 调用官方脚本卸载 Xray (如果存在)"
  echo
  read -rp "确认要彻底卸载吗？(y/N): " confirm
  if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
    echo "已取消卸载。"
    exit 0
  fi

  # 停止 & 禁用服务
  if command -v systemctl >/dev/null 2>&1; then
    systemctl stop "${SERVICE_NAME}" 2>/dev/null || true
    systemctl disable "${SERVICE_NAME}" 2>/dev/null || true
  else
    service "${SERVICE_NAME}" stop 2>/dev/null || true
  fi

  # 清理 UFW 规则
  cleanup_ufw_rules

  # 删除自定义/可能存在的 unit 文件
  if [[ -f "/etc/systemd/system/${SERVICE_NAME}.service" ]]; then
    rm -f "/etc/systemd/system/${SERVICE_NAME}.service"
    echo "Removed unit: /etc/systemd/system/${SERVICE_NAME}.service"
  fi
  if [[ -f "/etc/systemd/system/${SERVICE_NAME}.service.d/10-donot_touch_single_conf.conf" ]]; then
    rm -f "/etc/systemd/system/${SERVICE_NAME}.service.d/10-donot_touch_single_conf.conf"
  fi
  if [[ -f "/etc/systemd/system/${SERVICE_NAME}@.service" ]]; then
    rm -f "/etc/systemd/system/${SERVICE_NAME}@.service"
  fi
  systemctl daemon-reload >/dev/null 2>&1 || true

  # 删除配置和日志目录
  if [[ -d "/usr/local/etc/xray" ]]; then
    rm -rf "/usr/local/etc/xray"
    echo "Removed config dir: /usr/local/etc/xray"
  fi
  if [[ -d "/var/log/xray" ]]; then
    rm -rf "/var/log/xray"
    echo "Removed log dir: /var/log/xray"
  fi

  # 清理 BBR 配置
  cleanup_sysctl_bbr

  # 调用官方卸载脚本（如果存在）
  if [[ -x "/usr/local/bin/xray" ]] || [[ -x "/usr/bin/xray" ]]; then
    echo -e "[${green}Info${plain}] 尝试使用官方脚本卸载 Xray（如果可用）..."
    bash <(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh) remove || true
  fi

  echo -e "[${green}Done${plain}] 已尽力清理由本脚本安装的 Xray 部署。"
  echo "如需再次确认，可执行："
  echo "  which xray || echo 'xray binary not found'"
  echo "  systemctl status xray"
}

show_menu() {
  echo "==============================="
  echo " Xray Shadowsocks 管理脚本"
  echo "==============================="
  echo "1) 查看当前端口"
  echo "2) 一键更换端口"
  echo "3) 一键彻底卸载部署（含 Xray）"
  echo "0) 退出"
  echo "==============================="
  read -rp "请选择: " choice
  case "$choice" in
    1) show_current_ports ;;
    2) change_ports ;;
    3) uninstall_xray_full ;;
    0) exit 0 ;;
    *) echo "无效选择" ;;
  esac
}

usage() {
  cat <<EOF
用法: $0 [命令]

命令:
  menu               交互式菜单 (默认)
  show-ports         显示当前 ss-ipv4/ss-ipv6/ss-legacy 端口
  change-ports       一键更换端口 (交互输入)
  uninstall          一键彻底卸载部署（停服务 + 删配置 + 删日志 + 尝试卸载 Xray）

示例:
  sudo $0
  sudo $0 change-ports
  sudo $0 uninstall
EOF
}

main() {
  case "${1:-menu}" in
    menu)
      show_menu
      ;;
    show-ports)
      show_current_ports
      ;;
    change-ports)
      change_ports
      ;;
    uninstall)
      uninstall_xray_full
      ;;
    -h|--help|help)
      usage
      ;;
    *)
      echo -e "[${yellow}Warn${plain}] 未知命令: $1"
      usage
      exit 1
      ;;
  esac
}

main "$@"
