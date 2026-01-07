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

get_ipv6() {
  local ip
  ip=$(ip -6 addr | awk '/inet6/{print $2}' | cut -d/ -f1 | grep -Ev '^::1$|^fe80:|^fc00:|^fd00:' | head -n1 || true)
  echo "${ip:-Unknown}"
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
  bash <(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)
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
        "domainStrategy": "UseIP"
      }
    }
  ]
}
JSON
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

  echo -e "[${green}Step${plain}] Apt init & tools"
  apt_init

  echo -e "[${green}Step${plain}] Install Xray"
  install_xray

  echo -e "[${green}Step${plain}] Ports"
  prompt_ports

  echo -e "[${green}Step${plain}] Keys"
  prompt_keys

  echo -e "[${green}Step${plain}] Write config"
  write_xray_config

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
  echo "  IPv6: $(get_ipv6)"

  echo -e "\nNote: If your cloud provider has a Security Group/Firewall, open TCP/UDP ${PORT_V4}-${PORT_LEGACY} there too."

  maybe_generate_clash

  echo -e "\nDone. You can edit Xray config at /usr/local/etc/xray/config.json and restart with: systemctl restart xray"
}

main "$@"
