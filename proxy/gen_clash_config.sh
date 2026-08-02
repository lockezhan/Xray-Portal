#!/usr/bin/env bash
# Generate Clash Verge YAML from Xray config in /usr/local/etc/xray/config.json
# Supports domain-based server (via /etc/xray-meta.conf) and Clash subscription URL.
set -euo pipefail

CONFIG="${CONFIG:-/usr/local/etc/xray/config.json}"
META="${META:-/etc/xray-meta.conf}"
OUT="${OUT:-/root/clash-verge.yaml}"
SUBSCRIBE_DIR="${SUBSCRIBE_DIR:-/var/www/clash}"
SUBSCRIBE_FILE="${SUBSCRIBE_FILE:-${SUBSCRIBE_DIR}/clash.yaml}"

red='\033[0;31m'
green='\033[0;32m'
yellow='\033[0;33m'
plain='\033[0m'

if ! command -v jq >/dev/null 2>&1; then
  echo "jq is not installed. Install it first: apt install -y jq"
  exit 1
fi

if [[ ! -f "$CONFIG" ]]; then
  echo "Xray config not found at $CONFIG"
  exit 1
fi

is_valid_ipv6() {
  local ip="${1:-}"
  [[ -z "$ip" ]] && return 1
  python3 -c 'import sys, ipaddress; sys.exit(0 if ipaddress.ip_address(sys.argv[1]).version == 6 else 1)' "$ip" 2>/dev/null
}

detect_public_ipv6() {
  local ip=""

  # 1. 优先检查 PUBLIC_IPV6 环境变量
  if [[ -n "${PUBLIC_IPV6:-}" ]] && is_valid_ipv6 "${PUBLIC_IPV6}"; then
    echo "${PUBLIC_IPV6}"
    return 0
  fi

  # 2. 检查 /etc/xray-meta.conf 中的 PUBLIC_IPV6
  if [[ -f "$META" ]]; then
    local meta_v6
    meta_v6=$(grep -E '^PUBLIC_IPV6=' "$META" 2>/dev/null | cut -d= -f2- | tr -d '[:space:]"' || true)
    if [[ -n "$meta_v6" ]] && is_valid_ipv6 "$meta_v6"; then
      echo "$meta_v6"
      return 0
    fi
  fi

  # 3. 检查网卡直连公网 IPv6
  ip=$(ip -6 addr 2>/dev/null | awk '/inet6/{print $2}' | cut -d/ -f1 | grep -Ev '^::1$|^fe80:|^fc00:|^fd00:' | head -n1 || true)
  if [[ -n "$ip" ]] && is_valid_ipv6 "$ip"; then
    echo "$ip"
    return 0
  fi

  # 4. curl -6 自动探测
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

  # 5. 无法获取时安全降级返回空
  echo ""
}

# ── 读取 IPv4 与 DOMAIN ──────────────────────────────────────────────────
IPV4=$(ip -4 addr 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1 | grep -Ev '^127\.|^10\.|^172\.(1[6-9]|2[0-9]|3[0-2])\.|^192\.168\.' | head -n1 || true)
[[ -z "$IPV4" ]] && IPV4=$(curl -fsSL --max-time 3 ipv4.icanhazip.com 2>/dev/null || echo "1.2.3.4")

DOMAIN="$IPV4"  # 默认回退到 IPv4
if [[ -f "$META" ]]; then
  # shellcheck source=/dev/null
  source "$META"
  echo -e "[${green}Info${plain}] 读取到元配置: DOMAIN=${DOMAIN:-$IPV4}"
  [[ -z "${DOMAIN:-}" ]] && DOMAIN="$IPV4"
else
  echo -e "[${yellow}Warn${plain}] /etc/xray-meta.conf 不存在，使用 IP 探测（建议先运行 install.sh）"
fi

PUBLIC_IPV6=$(detect_public_ipv6)

if [[ -n "$PUBLIC_IPV6" ]]; then
  echo -e "[${green}Info${plain}] 检测到有效公网 IPv6: ${PUBLIC_IPV6}"
else
  echo -e "[${yellow}Warning${plain}] 未检测到有效公网 IPv6 地址，将跳过 MyVPS-IPv6 节点生成。"
fi

# ── 从 JSON 读取端口、方法、密码────────────────────────────────────────────
PORT_V4=$(jq -r '.inbounds[] | select(.tag=="ss-ipv4") | .port' "$CONFIG")
PORT_V6=$(jq -r '.inbounds[] | select(.tag=="ss-ipv6") | .port' "$CONFIG" 2>/dev/null || echo "")
PORT_LEGACY=$(jq -r '.inbounds[] | select(.tag=="ss-legacy") | .port' "$CONFIG")

METHOD_V4=$(jq -r '.inbounds[] | select(.tag=="ss-ipv4") | .settings.method' "$CONFIG")
METHOD_V6=$(jq -r '.inbounds[] | select(.tag=="ss-ipv6") | .settings.method' "$CONFIG" 2>/dev/null || echo "2022-blake3-aes-128-gcm")
PASS_V4=$(jq -r '.inbounds[] | select(.tag=="ss-ipv4") | .settings.password' "$CONFIG")
PASS_V6=$(jq -r '.inbounds[] | select(.tag=="ss-ipv6") | .settings.password' "$CONFIG" 2>/dev/null || echo "")
PASS_LEGACY=$(jq -r '.inbounds[] | select(.tag=="ss-legacy") | .settings.password' "$CONFIG")

CIPHER_V4="$METHOD_V4"
CIPHER_V6="$METHOD_V6"
if [[ "$METHOD_V4" != 2022-* ]]; then CIPHER_V4="aes-256-gcm"; fi
if [[ "$METHOD_V6" != 2022-* ]]; then CIPHER_V6="aes-256-gcm"; fi

# ── 动态构建 proxies 与 proxy-groups 内容 ──────────────────────────────────
PROXIES_BLOCK="  - name: \"MyVPS-IPv4\"\n    type: ss\n    server: ${DOMAIN}\n    port: ${PORT_V4}\n    cipher: ${CIPHER_V4}\n    password: \"${PASS_V4}\"\n    udp: true"

if [[ -n "$PUBLIC_IPV6" ]]; then
  PROXIES_BLOCK+="\n\n  - name: \"MyVPS-IPv6\"\n    type: ss\n    server: \"${PUBLIC_IPV6}\"\n    port: ${PORT_V6}\n    cipher: ${CIPHER_V6}\n    password: \"${PASS_V6}\"\n    udp: true"
fi

PROXIES_BLOCK+="\n\n  - name: \"MyVPS-Legacy\"\n    type: ss\n    server: ${DOMAIN}\n    port: ${PORT_LEGACY}\n    cipher: aes-256-gcm\n    password: \"${PASS_LEGACY}\"\n    udp: true"

AUTO_SELECT_LIST="      - \"MyVPS-IPv4\""
if [[ -n "$PUBLIC_IPV6" ]]; then
  AUTO_SELECT_LIST+="\n      - \"MyVPS-IPv6\""
fi
AUTO_SELECT_LIST+="\n      - \"MyVPS-Legacy\""

PROXY_GROUP_LIST="      - \"Auto-Select\"\n      - \"MyVPS-IPv4\""
if [[ -n "$PUBLIC_IPV6" ]]; then
  PROXY_GROUP_LIST+="\n      - \"MyVPS-IPv6\""
fi
PROXY_GROUP_LIST+="\n      - \"MyVPS-Legacy\""

cat > "$OUT" <<YAML
# Clash 通用配置 (学校直连，其他全代理)
port: 7890
socks-port: 7891
allow-lan: true
mode: rule
log-level: info
external-controller: :9090

proxies:
$(echo -e "$PROXIES_BLOCK")

proxy-groups:
  - name: "Auto-Select"
    type: url-test
    proxies:
$(echo -e "$AUTO_SELECT_LIST")
    url: 'http://www.gstatic.com/generate_204'
    interval: 300

  - name: "Proxy"
    type: select
    proxies:
$(echo -e "$PROXY_GROUP_LIST")

rules:
  - DOMAIN-SUFFIX,edu.cn,DIRECT
  - DOMAIN-SUFFIX,cn,DIRECT
  - GEOSITE,cn,DIRECT
  - GEOIP,lan,DIRECT
  - GEOIP,cn,DIRECT
  - IP-CIDR,127.0.0.0/8,DIRECT
  - IP-CIDR,10.0.0.0/8,DIRECT
  - IP-CIDR,172.16.0.0/12,DIRECT
  - IP-CIDR,192.168.0.0/16,DIRECT
  - MATCH,Proxy
YAML

echo "Clash Verge config written to: $OUT"

# ── 同步复制到订阅目录（供 serve_clash.sh 使用）────────────────────────────
mkdir -p "${SUBSCRIBE_DIR}"
cp "$OUT" "${SUBSCRIBE_FILE}"
echo -e "[${green}Info${plain}] 订阅文件已同步到: ${SUBSCRIBE_FILE}"

# ── 生成 ss:// 快速导入链接──────────────────────────────────────────────────
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

echo
echo -e "[${green}===== ss:// 快速导入链接 =====${plain}]"
echo "  [IPv4-SS2022 (域名)]"
make_ss_uri \
  "${CIPHER_V4}" "${PASS_V4}" "${DOMAIN}" "${PORT_V4}" "MyVPS-IPv4"

if [[ -n "$PUBLIC_IPV6" ]]; then
  echo "  [IPv6-SS2022 (IP)]"
  make_ss_uri \
    "${CIPHER_V6}" "${PASS_V6}" "${PUBLIC_IPV6}" "${PORT_V6}" "MyVPS-IPv6"
else
  echo -e "  [IPv6-SS2022 (IP)] ${yellow}(跳过 - 无公网 IPv6)${plain}"
fi

echo "  [Legacy-AES256 (域名)]"
make_ss_uri \
  "aes-256-gcm" "${PASS_LEGACY}" "${DOMAIN}" "${PORT_LEGACY}" "MyVPS-Legacy"
echo
echo -e "  ${yellow}Clash 订阅 URL${plain}: 运行 sudo ./serve_clash.sh 后可获取 http://${DOMAIN}:8080/clash.yaml"
