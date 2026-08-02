#!/usr/bin/env bash
#=================================================================#
#   System Required:  Ubuntu 20.04+ / Debian 11+                  #
#   Description: One-click deploy Xray multi-port Shadowsocks     #
#                with IPv4/IPv6 split + BBR + UFW                 #
#   Author: Gemini (adapted for Xray-core SS-2022 multi inbounds) #
#=================================================================#

set -euo pipefail

# Colors
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

require_apt() {
  if ! command -v apt &>/dev/null; then
    echo -e "[${red}Error${plain}] This script is designed for Debian/Ubuntu systems using apt."
    exit 1
  fi
}

get_ipv4() {
  local ip
  ip=$(ip -4 addr | awk '/inet /{print $2}' | cut -d/ -f1 | grep -Ev '^127\.|^10\.|^172\.(1[6-9]|2[0-9]|3[0-2])\.|^192\.168\.' | head -n1 || true)
  if [[ -z "$ip" ]]; then ip=$(curl -fsSL --max-time 2 ipv4.icanhazip.com || true); fi
  if [[ -z "$ip" ]]; then ip=$(curl -fsSL --max-time 2 ipinfo.io/ip || true); fi
  echo "${ip:-Unknown}"
}

is_valid_ipv6() {
  local ip="${1:-}"
  [[ -z "$ip" ]] && return 1
  python3 -c 'import sys, ipaddress; sys.exit(0 if ipaddress.ip_address(sys.argv[1]).version == 6 else 1)' "$ip" 2>/dev/null
}

get_private_ipv6() {
  local ip
  ip=$(ip -6 addr 2>/dev/null | awk '/inet6/{print $2}' | cut -d/ -f1 | grep -E '^fc00:|^fd00:' | head -n1 || true)
  if is_valid_ipv6 "$ip"; then
    echo "$ip"
  else
    echo ""
  fi
}

detect_public_ipv6() {
  local ip=""
  if [[ -n "${PUBLIC_IPV6:-}" ]] && is_valid_ipv6 "${PUBLIC_IPV6}"; then
    echo "${PUBLIC_IPV6}"
    return 0
  fi

  ip=$(ip -6 addr 2>/dev/null | awk '/inet6/{print $2}' | cut -d/ -f1 | grep -Ev '^::1$|^fe80:|^fc00:|^fd00:' | head -n1 || true)
  if [[ -n "$ip" ]] && is_valid_ipv6 "$ip"; then
    echo "$ip"
    return 0
  fi

  ip=$(curl -6 --noproxy '*' -fsSL --max-time 8 https://api64.ipify.org 2>/dev/null | tr -d '[:space:]' || true)
  if [[ -n "$ip" ]] && is_valid_ipv6 "$ip"; then
    echo "$ip"
    return 0
  fi

  ip=$(curl -6 --noproxy '*' -fsSL --max-time 8 https://ipv6.icanhazip.com 2>/dev/null | tr -d '[:space:]' || true)
  if [[ -n "$ip" ]] && is_valid_ipv6 "$ip"; then
    echo "$ip"
    return 0
  fi

  echo ""
}

prompt_ipv6() {
  echo
  echo -e "[${green}Step${plain}] 配置公网 IPv6 地址（可选）"
  local input_v6
  while true; do
    read -rp "Public IPv6 address (leave empty to auto-detect): " input_v6
    if [[ -z "${input_v6}" ]]; then
      local auto_v6
      auto_v6=$(detect_public_ipv6)
      if [[ -n "${auto_v6}" ]]; then
        echo -e "  自动探测到公网 IPv6: ${green}${auto_v6}${plain}"
        read -rp "  确认使用该公网 IPv6 地址? [Y/n]: " confirm_v6
        confirm_v6=${confirm_v6:-Y}
        if [[ "${confirm_v6}" =~ ^[Yy]$ ]]; then
          PUBLIC_IPV6="${auto_v6}"
        else
          PUBLIC_IPV6=""
          echo -e "  已跳过使用公网 IPv6。"
        fi
      else
        echo -e "  [${yellow}Info${plain}] 未探测到有效的公网 IPv6 地址。"
        PUBLIC_IPV6=""
      fi
      break
    else
      if is_valid_ipv6 "${input_v6}"; then
        PUBLIC_IPV6="${input_v6}"
        echo -e "  Public IPv6: ${green}${PUBLIC_IPV6}${plain}"
        break
      else
        echo -e "  [${red}Error${plain}] 输入的 IPv6 地址格式无效，请重新输入或留空。"
      fi
    fi
  done
}


prompt_domain() {
  echo
  echo -e "[${green}Step${plain}] 可选：使用 Cloudflare 域名替代裸 IP（请在 CF 中将该子域名设为 A 记录 → 灰云/仅DNS）"
  read -rp "输入已解析到本 VPS 的子域名（如 vpn.example.com），留空则使用 IPv4: " DOMAIN
  if [[ -n "${DOMAIN}" ]]; then
    echo -e "  域名: ${green}${DOMAIN}${plain}（将用于 Clash 配置与 ss:// URI）"
  else
    DOMAIN="$(get_ipv4)"
    echo -e "  未输入域名，将使用 IPv4: ${yellow}${DOMAIN}${plain}"
  fi
}

prompt_ports() {
  read -rp "Enter IPv4 SS-2022 port [default 20001]: " PORT_V4
  PORT_V4=${PORT_V4:-20001}
  read -rp "Enter IPv6 SS-2022 port [default 20002]: " PORT_V6
  PORT_V6=${PORT_V6:-20002}
  read -rp "Enter legacy AES-256-GCM port [default 20003]: " PORT_LEGACY
  PORT_LEGACY=${PORT_LEGACY:-20003}

  echo -e "Ports selected:\n  IPv4:   ${PORT_V4}\n  IPv6:   ${PORT_V6}\n  Legacy: ${PORT_LEGACY}"
}

is_base64_16() {
  # Base64 for 16 bytes typically ~24 chars with trailing ==, but accept general base64.
  local s="$1"
  # rudimentary check: consists of base64 chars and optional padding
  [[ "$s" =~ ^[A-Za-z0-9+/]+={0,2}$ ]] && return 0 || return 1
}

prompt_keys() {
  echo "Provide SS-2022 (aes-128-gcm blake3) base64 keys (16 bytes -> base64)."
  read -rp "IPv4 key (leave empty to auto-generate): " KEY_V4
  if [[ -z "${KEY_V4}" ]]; then
    KEY_V4=$(openssl rand -base64 16)
    echo "Auto-generated IPv4 key: ${KEY_V4}"
  elif ! is_base64_16 "$KEY_V4"; then
    echo -e "[${yellow}Warning${plain}] IPv4 key does not look like base64; proceeding anyway."
  fi

  read -rp "IPv6 key (leave empty to auto-generate): " KEY_V6
  if [[ -z "${KEY_V6}" ]]; then
    KEY_V6=$(openssl rand -base64 16)
    echo "Auto-generated IPv6 key: ${KEY_V6}"
  elif ! is_base64_16 "$KEY_V6"; then
    echo -e "[${yellow}Warning${plain}] IPv6 key does not look like base64; proceeding anyway."
  fi

  # Legacy password can be any string
  read -rp "Legacy AES-256-GCM password [default TraditionalPassword123]: " KEY_LEGACY
  KEY_LEGACY=${KEY_LEGACY:-TraditionalPassword123}
}

apt_init() {
  echo -e "[${green}Step${plain}] Update & install base tools"
  export DEBIAN_FRONTEND=noninteractive
  apt update && apt -y upgrade
  apt install -y curl nano ufw openssl jq
  timedatectl set-timezone UTC || true
}

install_xray() {
  echo -e "[${green}Step${plain}] Install Xray-core via official script"
  # 强制删除已有的 xray 二进制文件，避免官方安装脚本因为检测到同版本号而跳过 systemd 服务的覆盖安装
  rm -f /usr/local/bin/xray /usr/bin/xray 2>/dev/null || true
  bash <(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)
  
  # 修复 systemd "Special user nobody configured, this is not safe!" 警告
  if [[ -f /etc/systemd/system/xray.service ]]; then
    sed -i 's/User=nobody/User=root/g' /etc/systemd/system/xray.service
  fi
}

write_xray_config() {
  echo -e "[${green}Step${plain}] Write Xray config JSON"
  mkdir -p /usr/local/etc/xray /var/log/xray
  # Create config without comments; Xray uses strict JSON.
  cat >/usr/local/etc/xray/config.json <<JSON
{
  "log": {
    "loglevel": "warning",
    "access": "/var/log/xray/access.log",
    "error": "/var/log/xray/error.log"
  },
  "inbounds": [
    {
      "tag": "ss-ipv4",
      "port": ${PORT_V4},
      "listen": "0.0.0.0",
      "protocol": "shadowsocks",
      "settings": {
        "method": "2022-blake3-aes-128-gcm",
        "password": "${KEY_V4}",
        "network": "tcp,udp"
      }
    },
    {
      "tag": "ss-ipv6",
      "port": ${PORT_V6},
      "listen": "::",
      "protocol": "shadowsocks",
      "settings": {
        "method": "2022-blake3-aes-128-gcm",
        "password": "${KEY_V6}",
        "network": "tcp,udp"
      }
    },
    {
      "tag": "ss-legacy",
      "port": ${PORT_LEGACY},
      "listen": "0.0.0.0",
      "protocol": "shadowsocks",
      "settings": {
        "method": "aes-256-gcm",
        "password": "${KEY_LEGACY}",
        "network": "tcp,udp"
      }
    }
  ],
  "routing": {
    "domainStrategy": "AsIs",
    "rules": []
  },
  "outbounds": [
    {
      "tag": "direct",
      "protocol": "freedom",
      "settings": {
        "domainStrategy": "UseIPv4"
      }
    }
  ]
}
JSON

  # 修复并确保配置与日志目录对于 root 用户权限正确
  chown -R root:root /usr/local/etc/xray/
  chmod 644 /usr/local/etc/xray/config.json
  chown -R root:root /var/log/xray/
}

write_meta_conf() {
  echo -e "[${green}Step${plain}] Write /etc/xray-meta.conf"
  cat >/etc/xray-meta.conf <<META
DOMAIN=${DOMAIN}
PORT_V4=${PORT_V4}
PORT_V6=${PORT_V6}
PORT_LEGACY=${PORT_LEGACY}
KEY_V4=${KEY_V4}
KEY_V6=${KEY_V6}
KEY_LEGACY=${KEY_LEGACY}
PUBLIC_IPV6=${PUBLIC_IPV6:-}
PRIVATE_IPV6=${PRIVATE_IPV6:-}
META
  chmod 600 /etc/xray-meta.conf
  echo "  Saved to /etc/xray-meta.conf"
}

format_host_for_ss() {
  local host="$1"
  if [[ "$host" == *:* && "$host" != \[*\] ]]; then
    echo "[${host}]"
  else
    echo "${host}"
  fi
}

make_ss_uri() {
  local method="$1" pass="$2" host="$3" port="$4" name="$5"
  local formatted_host
  formatted_host=$(format_host_for_ss "${host}")
  local userinfo
  userinfo=$(printf '%s:%s' "${method}" "${pass}" | base64 -w0)
  printf 'ss://%s@%s:%s#%s\n' "${userinfo}" "${formatted_host}" "${port}" "${name}"
}

show_uris() {
  echo
  echo -e "[${green}===== Shadowsocks 快速导入链接 =====${plain}]"
  echo "  [IPv4-SS2022]"
  make_ss_uri "2022-blake3-aes-128-gcm" "${KEY_V4}" "${DOMAIN}" "${PORT_V4}" "MyVPS-IPv4"
  if [[ -n "${PUBLIC_IPV6:-}" ]]; then
    echo "  [IPv6-SS2022]"
    make_ss_uri "2022-blake3-aes-128-gcm" "${KEY_V6}" "${PUBLIC_IPV6}" "${PORT_V6}" "MyVPS-IPv6"
  else
    echo -e "  [IPv6-SS2022] ${yellow}(跳过 - 未检测到/未配置公网 IPv6)${plain}"
  fi
  echo "  [Legacy-AES256]"
  make_ss_uri "aes-256-gcm" "${KEY_LEGACY}" "${DOMAIN}" "${PORT_LEGACY}" "MyVPS-Legacy"
  echo
  echo -e "  ${yellow}提示${plain}: 复制上方 ss:// 链接可直接导入 v2rayN / Shadowrocket / Clash"
  echo -e "  如需 Clash 订阅 URL，安装完成后运行: sudo ./serve_clash.sh"
}

restart_xray() {
  echo -e "[${green}Step${plain}] Restart & enable Xray service"
  systemctl daemon-reload || true
  systemctl enable xray
  systemctl restart xray
  sleep 1
  systemctl --no-pager --full status xray || true
}

enable_bbr() {
  echo -e "[${green}Step${plain}] Enable TCP BBR"
  # Avoid duplicate lines
  sed -i '/net.core.default_qdisc=fq/d' /etc/sysctl.conf || true
  sed -i '/net.ipv4.tcp_congestion_control=bbr/d' /etc/sysctl.conf || true
  echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
  echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
  sysctl -p || true
  echo "Loaded TCP modules:"
  lsmod | grep bbr || true
}

configure_ufw() {
  echo -e "[${green}Step${plain}] Configure UFW firewall"
  ufw allow 22/tcp || true
  ufw allow "${PORT_V4}"/tcp || true
  ufw allow "${PORT_V4}"/udp || true
  ufw allow "${PORT_V6}"/tcp || true
  ufw allow "${PORT_V6}"/udp || true
  ufw allow "${PORT_LEGACY}"/tcp || true
  ufw allow "${PORT_LEGACY}"/udp || true
  yes | ufw enable || true
}

port_check() {
  echo -e "[${green}Check${plain}] Listening ports (expect ${PORT_V4}, ${PORT_V6}, ${PORT_LEGACY})"
  ss -tulpn | grep -E "xray|${PORT_V4}|${PORT_V6}|${PORT_LEGACY}" || true
}

maybe_generate_clash() {
  local choice
  read -rp "Generate Clash Verge config now? [y/N]: " choice
  if [[ "${choice:-N}" =~ ^[Yy]$ ]]; then
    /usr/local/bin/gen_clash_config.sh || bash ./gen_clash_config.sh || echo -e "[${yellow}Skip${plain}] gen_clash_config.sh not found; you can run it later."
  fi
}

main() {
  require_root
  require_apt

  PUBLIC_IPV6="${PUBLIC_IPV6:-}"
  PRIVATE_IPV6=$(get_private_ipv6)

  echo -e "[${green}Step${plain}] Apt init & tools"
  apt_init

  echo -e "[${green}Step${plain}] Install Xray"
  install_xray

  echo -e "[${green}Step${plain}] Domain"
  prompt_domain

  echo -e "[${green}Step${plain}] IPv6 Configuration"
  prompt_ipv6

  echo -e "[${green}Step${plain}] Ports"
  prompt_ports

  echo -e "[${green}Step${plain}] Keys"
  prompt_keys

  echo -e "[${green}Step${plain}] Write config"
  write_xray_config

  echo -e "[${green}Step${plain}] Save meta"
  write_meta_conf

  echo -e "[${green}Step${plain}] Restart Xray"
  restart_xray

  echo -e "[${green}Step${plain}] Enable BBR"
  enable_bbr

  echo -e "[${green}Step${plain}] Configure UFW"
  configure_ufw

  echo -e "[${green}Step${plain}] Verify"
  port_check

  echo -e "\nServer IPs:"
  echo "  IPv4: $(get_ipv4)"
  echo "  Private IPv6: ${PRIVATE_IPV6:-None}"
  echo "  Public IPv6: ${PUBLIC_IPV6:-None}"
  [[ "${DOMAIN}" != "$(get_ipv4)" ]] && echo "  Domain: ${DOMAIN}"

  echo -e "\nNote: If your cloud provider has a Security Group/Firewall, open TCP/UDP ${PORT_V4}-${PORT_LEGACY} there too."

  show_uris

  maybe_generate_clash

  echo -e "\nDone. You can edit Xray config at /usr/local/etc/xray/config.json and restart with: systemctl restart xray"
}

main "$@"
