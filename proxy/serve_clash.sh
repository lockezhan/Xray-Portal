#!/usr/bin/env bash
#=================================================================#
#   serve_clash.sh                                                #
#   在 VPS 上托管 Clash 订阅文件，提供可被 Clash 直接导入的 URL  #
#   用法: sudo ./serve_clash.sh [--port PORT] [--install-service] #
#=================================================================#
set -euo pipefail

red='\033[0;31m'
green='\033[0;32m'
yellow='\033[0;33m'
plain='\033[0m'

META="/etc/xray-meta.conf"
SUBSCRIBE_DIR="/var/www/clash"
YAML_SRC="/root/clash-verge.yaml"
YAML_DST="${SUBSCRIBE_DIR}/clash.yaml"
SERVE_PORT="${SERVE_PORT:-80}"
SERVICE_NAME="clash-subscribe"

require_root() {
  if [[ $EUID -ne 0 ]]; then
    echo -e "[${red}Error${plain}] 请以 root 运行: sudo $0"
    exit 1
  fi
}

detect_domain() {
  # 优先读元配置，否则探测 IPv4
  if [[ -f "$META" ]]; then
    # shellcheck source=/dev/null
    source "$META"
    DOMAIN="${DOMAIN:-}"
  fi
  if [[ -z "${DOMAIN:-}" ]]; then
    DOMAIN=$(curl -fsSL --max-time 3 ipv4.icanhazip.com 2>/dev/null || \
             ip -4 addr | awk '/inet /{print $2}' | cut -d/ -f1 \
               | grep -Ev '^127\.|^10\.|^172\.(1[6-9]|2[0-9]|3[0-2])\.|^192\.168\.' \
               | head -n1 || echo "YOUR_DOMAIN_OR_IP")
  fi
}

sync_yaml() {
  mkdir -p "${SUBSCRIBE_DIR}"
  if [[ -f "${YAML_SRC}" ]]; then
    cp "${YAML_SRC}" "${YAML_DST}"
    echo -e "[${green}OK${plain}] YAML 已复制: ${YAML_SRC} → ${YAML_DST}"
  else
    echo -e "[${yellow}Warn${plain}] ${YAML_SRC} 不存在，请先运行 gen_clash_config.sh"
    echo -e "  如已有 YAML 文件可手动放到: ${YAML_DST}"
  fi
}

open_firewall() {
  if command -v ufw >/dev/null 2>&1; then
    ufw allow "${SERVE_PORT}"/tcp >/dev/null 2>&1 || true
    echo -e "[${green}OK${plain}] UFW 已放行端口 ${SERVE_PORT}/tcp"
  else
    echo -e "[${yellow}Warn${plain}] 未检测到 ufw，请手动放行 ${SERVE_PORT}/tcp"
  fi
}

install_systemd_service() {
  echo -e "[${green}Step${plain}] 准备 Web 部署环境与 Python 依赖..."
  if ! command -v pip3 >/dev/null 2>&1 || ! python3 -m venv -h >/dev/null 2>&1; then
      apt-get update -y >/dev/null 2>&1
      apt-get install -y python3-pip python3-venv >/dev/null 2>&1
  fi
  
  echo -e "[${green}Step${plain}] 部署前端代码到 /usr/local/vpn-web ..."
  rm -rf /usr/local/vpn-web
  # 获取脚本所在目录的上一级中的 web 文件夹
  local SCRIPT_DIR
  SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
  if [[ -d "${SCRIPT_DIR}/../web" ]]; then
    cp -r "${SCRIPT_DIR}/../web" /usr/local/vpn-web
  else
    echo -e "[${yellow}Warn${plain}] 找不到 ${SCRIPT_DIR}/../web，依赖项可能不完整。"
    mkdir -p /usr/local/vpn-web
  fi

  echo -e "[${green}Step${plain}] 初始化虚拟环境并安装依赖..."
  python3 -m venv /usr/local/vpn-web/venv
  /usr/local/vpn-web/venv/bin/pip install --upgrade pip >/dev/null 2>&1
  /usr/local/vpn-web/venv/bin/pip install flask requests urllib3 >/dev/null 2>&1

  echo -e "[${green}Step${plain}] 创建 systemd 服务: ${SERVICE_NAME}"
  cat > "/etc/systemd/system/${SERVICE_NAME}.service" <<EOF
[Unit]
Description=Clash Subscription YAML Web Panel
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/usr/local/vpn-web
ExecStart=/usr/local/vpn-web/venv/bin/python app.py ${SERVE_PORT}
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable --now "${SERVICE_NAME}"
  sleep 1
  if systemctl is-active "${SERVICE_NAME}" >/dev/null 2>&1; then
    echo -e "[${green}OK${plain}] 服务已启动并设为开机自启"
  else
    echo -e "[${red}Error${plain}] 服务启动失败，请检查: systemctl status ${SERVICE_NAME}"
  fi
}

start_foreground() {
  echo -e "[${green}Info${plain}] 前台启动 HTTP 服务（Ctrl+C 退出），访问入口:"
  echo -e "  ${green}http://${DOMAIN}:${SERVE_PORT}/${plain}"
  cd /usr/local/vpn-web || exit
  exec ./venv/bin/python app.py "${SERVE_PORT}"
}

print_subscribe_url() {
  echo
  echo -e "======================================================"
  echo -e " ${green}全新 Web 管理面板已上线:${plain}"
  echo -e "   http://${DOMAIN}:${SERVE_PORT}/"
  echo -e "======================================================"
  echo -e " ${yellow}提示${plain}: 可直接在浏览器打开此链接获取节点信息和客户端下载。"
  echo -e " 请确保云服务商安全组已放行 TCP ${SERVE_PORT}。"
  echo -e " 若 Cloudflare 使用代理（橙云），该面板依然能完美加速访问！"
  echo
}

usage() {
  cat <<EOF
用法: sudo $0 [选项]

选项:
  (无参数)            复制 YAML、放行防火墙、安装 systemd 服务并后台运行
  --port PORT         指定 HTTP 监听端口（默认 8080）
  --foreground        不安装服务，直接前台运行（调试用）
  --uninstall         停止并删除 systemd 服务
  -h, --help          显示帮助

示例:
  sudo ./serve_clash.sh                   # 默认安装为系统服务
  sudo ./serve_clash.sh --port 8080       # 使用 8080 端口
  sudo ./serve_clash.sh --foreground      # 前台调试
  sudo ./serve_clash.sh --uninstall       # 卸载服务
EOF
}

uninstall_service() {
  require_root
  echo -e "[${yellow}Info${plain}] 停止并删除 ${SERVICE_NAME} 服务"
  systemctl stop "${SERVICE_NAME}" 2>/dev/null || true
  systemctl disable "${SERVICE_NAME}" 2>/dev/null || true
  rm -f "/etc/systemd/system/${SERVICE_NAME}.service"
  systemctl daemon-reload
  if command -v ufw >/dev/null 2>&1; then
    ufw delete allow "${SERVE_PORT}"/tcp >/dev/null 2>&1 || true
    echo "  UFW 规则已清除"
  fi
  echo -e "[${green}Done${plain}] 服务已卸载"
}

main() {
  local foreground=false

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --port)      SERVE_PORT="$2"; shift 2 ;;
      --foreground) foreground=true; shift ;;
      --uninstall) uninstall_service; exit 0 ;;
      -h|--help)   usage; exit 0 ;;
      *)  echo -e "[${red}Error${plain}] 未知参数: $1"; usage; exit 1 ;;
    esac
  done

  require_root
  detect_domain
  sync_yaml
  open_firewall

  if $foreground; then
    print_subscribe_url
    start_foreground
  else
    install_systemd_service
    print_subscribe_url
  fi
}

main "$@"
