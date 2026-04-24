#!/usr/bin/env bash
# Generate Clash Verge YAML from Xray config in /usr/local/etc/xray/config.json
# Supports domain-based server (via /etc/xray-meta.conf) and Clash subscription URL.
set -euo pipefail

CONFIG="/usr/local/etc/xray/config.json"
META="/etc/xray-meta.conf"
OUT="/root/clash-verge.yaml"
SUBSCRIBE_DIR="/var/www/clash"
SUBSCRIBE_FILE="${SUBSCRIBE_DIR}/clash.yaml"

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

# ── 读取 IP（始终需要用于 IPv6 节点）────────────────────────────────────────
IPV4=$(ip -4 addr | awk '/inet /{print $2}' | cut -d/ -f1 | grep -Ev '^127\.|^10\.|^172\.(1[6-9]|2[0-9]|3[0-2])\.|^192\.168\.' | head -n1 || true)
IPV6=$(ip -6 addr | awk '/inet6/{print $2}' | cut -d/ -f1 | grep -Ev '^::1$|^fe80:|^fc00:|^fd00:' | head -n1 || true)
[[ -z "$IPV4" ]] && IPV4=$(curl -fsSL --max-time 3 ipv4.icanhazip.com 2>/dev/null || echo "1.2.3.4")
[[ -z "$IPV6" ]] && IPV6="2400:6180:0:d2:0:2:75fd:e000"

# ── 优先读取 /etc/xray-meta.conf（由 install.sh 写入，含域名信息）──────────
DOMAIN="$IPV4"  # 默认回退到 IPv4
if [[ -f "$META" ]]; then
  # shellcheck source=/dev/null
  source "$META"
  echo -e "[${green}Info${plain}] 读取到元配置: DOMAIN=${DOMAIN}"
  # 若 META 中 DOMAIN 为空，回退 IPv4
  [[ -z "${DOMAIN:-}" ]] && DOMAIN="$IPV4"
else
  echo -e "[${yellow}Warn${plain}] /etc/xray-meta.conf 不存在，使用 IP 探测（建议先运行 install.sh）"
fi

# ── 从 JSON 读取端口、方法、密码────────────────────────────────────────────
PORT_V4=$(jq -r '.inbounds[] | select(.tag=="ss-ipv4") | .port' "$CONFIG")
PORT_V6=$(jq -r '.inbounds[] | select(.tag=="ss-ipv6") | .port' "$CONFIG")
PORT_LEGACY=$(jq -r '.inbounds[] | select(.tag=="ss-legacy") | .port' "$CONFIG")

METHOD_V4=$(jq -r '.inbounds[] | select(.tag=="ss-ipv4") | .settings.method' "$CONFIG")
METHOD_V6=$(jq -r '.inbounds[] | select(.tag=="ss-ipv6") | .settings.method' "$CONFIG")
PASS_V4=$(jq -r '.inbounds[] | select(.tag=="ss-ipv4") | .settings.password' "$CONFIG")
PASS_V6=$(jq -r '.inbounds[] | select(.tag=="ss-ipv6") | .settings.password' "$CONFIG")
PASS_LEGACY=$(jq -r '.inbounds[] | select(.tag=="ss-legacy") | .settings.password' "$CONFIG")

CIPHER_V4="$METHOD_V4"
CIPHER_V6="$METHOD_V6"
if [[ "$METHOD_V4" != 2022-* ]]; then CIPHER_V4="aes-256-gcm"; fi
if [[ "$METHOD_V6" != 2022-* ]]; then CIPHER_V6="aes-256-gcm"; fi

cat > "$OUT" <<YAML
# Clash 通用配置 (学校直连，其他全代理)
port: 7890
socks-port: 7891
allow-lan: true
mode: Rule
log-level: info
external-controller: :9090

proxies:
  - name: "MyVPS-IPv4"
    type: ss
    server: ${DOMAIN}
    port: ${PORT_V4}
    cipher: ${CIPHER_V4}
    password: ${PASS_V4}
    udp: true

  - name: "MyVPS-IPv6"
    type: ss
    server: ${IPV6}
    port: ${PORT_V6}
    cipher: ${CIPHER_V6}
    password: ${PASS_V6}
    udp: true

  - name: "MyVPS-Legacy"
    type: ss
    server: ${DOMAIN}
    port: ${PORT_LEGACY}
    cipher: aes-256-gcm
    password: "${PASS_LEGACY}"
    udp: true

proxy-groups:
  - name: "Auto-Select"
    type: url-test
    proxies:
      - "MyVPS-IPv4"
      - "MyVPS-IPv6"
      - "MyVPS-Legacy"
    url: 'http://www.gstatic.com/generate_204'
    interval: 300

  - name: "Proxy"
    type: select
    proxies:
      - "Auto-Select"
      - "MyVPS-IPv4"
      - "MyVPS-IPv6"
      - "MyVPS-Legacy"

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
make_ss_uri() {
  local method="$1" pass="$2" host="$3" port="$4" name="$5"
  local userinfo
  userinfo=$(printf '%s:%s' "${method}" "${pass}" | base64 -w0)
  printf 'ss://%s@%s:%s#%s\n' "${userinfo}" "${host}" "${port}" "${name}"
}

echo
echo -e "[${green}===== ss:// 快速导入链接 =====${plain}]"
echo "  [IPv4-SS2022 (域名)]"
make_ss_uri \
  "${CIPHER_V4}" "${PASS_V4}" "${DOMAIN}" "${PORT_V4}" "MyVPS-IPv4"
echo "  [IPv6-SS2022 (IP)]"
make_ss_uri \
  "${CIPHER_V6}" "${PASS_V6}" "${IPV6}" "${PORT_V6}" "MyVPS-IPv6"
echo "  [Legacy-AES256 (域名)]"
make_ss_uri \
  "aes-256-gcm" "${PASS_LEGACY}" "${DOMAIN}" "${PORT_LEGACY}" "MyVPS-Legacy"
echo
echo -e "  ${yellow}Clash 订阅 URL${plain}: 运行 sudo ./serve_clash.sh 后可获取 http://${DOMAIN}:8080/clash.yaml"

