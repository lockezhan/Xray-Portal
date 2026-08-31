#!/usr/bin/env bash
#=================================================================#
#   System Required:  Ubuntu 20.04+ / Debian 11+                  #
#   Description: One-click deploy Xray multi-port Shadowsocks     #
#                with IPv4/IPv6 split + BBR + UFW + Country Geo   #
#   Author: Gemini (adapted for Xray-core SS-2022 multi inbounds) #
#=================================================================#

set -euo pipefail

_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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

  for meta_path in "/etc/xray-portal/proxy-meta.conf" "/etc/xray-meta.conf"; do
    if [[ -f "$meta_path" ]]; then
      local meta_v6
      meta_v6=$(grep -E '^(PUBLIC_IPV6|PROXY_PUBLIC_IPV6)=' "$meta_path" 2>/dev/null | cut -d= -f2- | tr -d '[:space:]"' || true)
      if [[ -n "$meta_v6" ]] && is_valid_ipv6 "$meta_v6"; then
        echo "$meta_v6"
        return 0
      fi
    fi
  done

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
      input_v6=$(detect_public_ipv6)
      if [[ -n "${input_v6}" ]]; then
        echo -e "  Auto-detected public IPv6: ${green}${input_v6}${plain}"
        PUBLIC_IPV6="${input_v6}"
      else
        echo -e "  ${yellow}未检测到公网 IPv6 地址，将跳过 IPv6 出站/入站专属配置。${plain}"
        PUBLIC_IPV6=""
      fi
      break
    elif is_valid_ipv6 "${input_v6}"; then
      PUBLIC_IPV6="${input_v6}"
      echo -e "  Using specified IPv6: ${green}${PUBLIC_IPV6}${plain}"
      break
    else
      echo -e "  [${red}Error${plain}] Invalid IPv6 address format. Please try again or press Enter to auto-detect."
    fi
  done
}

prompt_domain() {
  local default_ip
  default_ip=$(get_ipv4)
  read -rp "Domain or IP for client connection [default ${default_ip}]: " DOMAIN
  DOMAIN=${DOMAIN:-$default_ip}
}

prompt_ports() {
  echo "Default ports: IPv4=20001, IPv6=20002, Legacy=20003."
  read -rp "Use default ports? (Y/n): " choice
  choice=${choice:-Y}
  if [[ "$choice" =~ ^[Yy]$ ]]; then
    PORT_V4=20001
    PORT_V6=20002
    PORT_LEGACY=20003
  else
    read -rp "Enter Port for IPv4 SS-2022 [1-65535]: " PORT_V4
    read -rp "Enter Port for IPv6 SS-2022 [1-65535]: " PORT_V6
    read -rp "Enter Port for Legacy AES-256 [1-65535]: " PORT_LEGACY
  fi

  echo -e "Ports selected:\n  IPv4:   ${PORT_V4}\n  IPv6:   ${PORT_V6}\n  Legacy: ${PORT_LEGACY}"
}

is_base64_16() {
  local s="$1"
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

  read -rp "Legacy AES-256-GCM password [default TraditionalPassword123]: " KEY_LEGACY
  KEY_LEGACY=${KEY_LEGACY:-TraditionalPassword123}
}

apt_init() {
  echo -e "[${green}Step${plain}] Update & install base tools"
  export DEBIAN_FRONTEND=noninteractive
  apt update && apt -y upgrade
  apt install -y curl nano ufw openssl jq python3
  timedatectl set-timezone UTC || true
}

install_xray() {
  echo -e "[${green}Step${plain}] Install Xray-core via official script"
  rm -f /usr/local/bin/xray /usr/bin/xray 2>/dev/null || true
  bash <(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)
  
  if [[ -f /etc/systemd/system/xray.service ]]; then
    sed -i 's/User=nobody/User=root/g' /etc/systemd/system/xray.service
  fi
}

write_xray_config() {
  echo -e "[${green}Step${plain}] Write Xray config JSON"
  mkdir -p /usr/local/etc/xray /var/log/xray
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

  chown -R root:root /usr/local/etc/xray/
  chmod 644 /usr/local/etc/xray/config.json
  chown -R root:root /var/log/xray/
}

detect_and_save_geo_meta() {
  local detect_py="${_SCRIPT_DIR}/lib/detect_geo.py"
  PROXY_COUNTRY_CODE="UN"
  PROXY_COUNTRY_NAME="未知地区"
  PROXY_COUNTRY_FLAG="🌐"
  PROXY_CITY=""

  if [[ -f "${detect_py}" ]]; then
    eval "$(python3 "${detect_py}" "${DOMAIN}" env 2>/dev/null || true)"
    echo -e "  [地理定位] ${green}${PROXY_COUNTRY_FLAG} ${PROXY_COUNTRY_NAME}${plain} (${PROXY_COUNTRY_CODE}${PROXY_CITY:+ - ${PROXY_CITY}})"
  fi

  mkdir -p /etc/xray-portal
  cat >/etc/xray-portal/proxy-meta.conf <<META
PROXY_DOMAIN=${DOMAIN}
PROXY_COUNTRY_CODE=${PROXY_COUNTRY_CODE}
PROXY_COUNTRY_NAME=${PROXY_COUNTRY_NAME}
PROXY_COUNTRY_FLAG=${PROXY_COUNTRY_FLAG}
PROXY_CITY=${PROXY_CITY}
PROXY_PORT_V4=${PORT_V4}
PROXY_PORT_V6=${PORT_V6}
PROXY_PORT_LEGACY=${PORT_LEGACY}
PROXY_ENABLE_IPV6=true
PROXY_ENABLE_LEGACY=false
META
  chmod 644 /etc/xray-portal/proxy-meta.conf

  # 保存兼容旧版 /etc/xray-meta.conf
  cat >/etc/xray-meta.conf <<META
DOMAIN=${DOMAIN}
COUNTRY_CODE=${PROXY_COUNTRY_CODE}
COUNTRY_NAME=${PROXY_COUNTRY_NAME}
COUNTRY_FLAG=${PROXY_COUNTRY_FLAG}
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
  echo "  Saved to /etc/xray-portal/proxy-meta.conf"
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
  local flag="${PROXY_COUNTRY_FLAG:-🌐}"
  local cname="${PROXY_COUNTRY_NAME:-节点}"
  echo
  echo -e "[${green}===== Shadowsocks 快速导入链接 (${flag} ${cname}) =====${plain}]"
  echo "  [${flag} ${cname} · IPv4]"
  make_ss_uri "2022-blake3-aes-128-gcm" "${KEY_V4}" "${DOMAIN}" "${PORT_V4}" "${flag} ${cname} - IPv4"
  if [[ -n "${PUBLIC_IPV6:-}" ]]; then
    echo "  [${flag} ${cname} · IPv6]"
    make_ss_uri "2022-blake3-aes-128-gcm" "${KEY_V6}" "${PUBLIC_IPV6}" "${PORT_V6}" "${flag} ${cname} - IPv6"
  else
    echo -e "  [${flag} ${cname} · IPv6] ${yellow}(跳过 - 未检测到/未配置公网 IPv6)${plain}"
  fi
  echo "  [${flag} ${cname} · Legacy]"
  make_ss_uri "aes-256-gcm" "${KEY_LEGACY}" "${DOMAIN}" "${PORT_LEGACY}" "${flag} ${cname} - Legacy"
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
    "${_SCRIPT_DIR}/gen_clash_config.sh" || /usr/local/bin/gen_clash_config.sh || echo -e "[${yellow}Skip${plain}] gen_clash_config.sh not found; you can run it later."
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

  echo -e "[${green}Step${plain}] Save meta & Geolocation"
  detect_and_save_geo_meta

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
  echo "  Location: ${PROXY_COUNTRY_FLAG} ${PROXY_COUNTRY_NAME} (${PROXY_COUNTRY_CODE})"

  echo -e "\nNote: If your cloud provider has a Security Group/Firewall, open TCP/UDP ${PORT_V4}-${PORT_LEGACY} there too."

  show_uris

  maybe_generate_clash

  echo -e "\nDone. You can edit Xray config at /usr/local/etc/xray/config.json and restart with: systemctl restart xray"
}

main "$@"
