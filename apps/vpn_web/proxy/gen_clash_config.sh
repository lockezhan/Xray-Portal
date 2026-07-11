#!/usr/bin/env bash
# =============================================================================
# 生成 Clash YAML 原始配置（从 Xray 运行配置读取，非交互）
# apps/vpn_web/proxy/gen_clash_config.sh
#
# 安全设计：
#   - 密钥从 /etc/xray-portal/proxy.env 读取（不从命令行或 stdin）
#   - 不打印任何密钥到 stdout/stderr
#   - 优先读取 proxy.env，回退到 Xray config.json
#   - 输出到 /var/www/clash/clash.yaml（供订阅构建使用）
# =============================================================================

set -euo pipefail

CONFIG="/usr/local/etc/xray/config.json"
PROXY_ENV="/etc/xray-portal/proxy.env"
PROXY_META="/etc/xray-portal/proxy-meta.conf"
SUBSCRIBE_DIR="/var/www/clash"
SUBSCRIBE_FILE="${SUBSCRIBE_DIR}/clash.yaml"

# 颜色（仅用于非密钥信息输出）
red='\033[0;31m'
green='\033[0;32m'
yellow='\033[0;33m'
plain='\033[0m'

# =============================================================================
# 检查依赖
# =============================================================================
if ! command -v jq >/dev/null 2>&1; then
    echo -e "[${red}Error${plain}] jq is not installed: apt install -y jq"
    exit 1
fi

if [[ ! -f "${CONFIG}" ]]; then
    echo -e "[${red}Error${plain}] Xray config not found at ${CONFIG}"
    exit 1
fi

# =============================================================================
# 读取 IP（始终需要用于 IPv6 节点）
# =============================================================================
IPV4=$(ip -4 addr | awk '/inet /{print $2}' | cut -d/ -f1 \
    | grep -Ev '^127\.|^10\.|^172\.(1[6-9]|2[0-9]|3[0-2])\.|^192\.168\.' \
    | head -n1 || true)
IPV6=$(ip -6 addr | awk '/inet6/{print $2}' | cut -d/ -f1 \
    | grep -Ev '^::1$|^fe80:|^fc00:|^fd00:' | head -n1 || true)
[[ -z "${IPV4}" ]] && IPV4=$(curl -fsSL --max-time 5 ipv4.icanhazip.com 2>/dev/null || echo "1.2.3.4")

# =============================================================================
# 读取域名（优先从 proxy-meta.conf）
# =============================================================================
DOMAIN="${IPV4}"  # 默认回退 IPv4

if [[ -f "${PROXY_META}" ]]; then
    # 安全逐行读取（不 source）
    while IFS= read -r line || [[ -n "${line}" ]]; do
        [[ "${line}" =~ ^[[:space:]]*# ]] && continue
        [[ -z "${line// }" ]] && continue
        if [[ "${line}" =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]]; then
            k="${BASH_REMATCH[1]}"
            v="${BASH_REMATCH[2]}"
            case "${k}" in
                PROXY_DOMAIN)
                    [[ -n "${v}" && "${v}" != "unknown" ]] && DOMAIN="${v}"
                    ;;
                PROXY_PORT_V4)   PROXY_PORT_V4="${v}" ;;
                PROXY_PORT_V6)   PROXY_PORT_V6="${v}" ;;
                PROXY_PORT_LEGACY) PROXY_PORT_LEGACY="${v}" ;;
                PROXY_ENABLE_IPV6) PROXY_ENABLE_IPV6="${v}" ;;
                PROXY_ENABLE_LEGACY) PROXY_ENABLE_LEGACY="${v}" ;;
            esac
        fi
    done < "${PROXY_META}"
    echo -e "[${green}Info${plain}] 读取代理元数据: DOMAIN=${DOMAIN}"
else
    echo -e "[${yellow}Warn${plain}] ${PROXY_META} 不存在，尝试从 Xray config.json 读取"
fi

# =============================================================================
# 从 Xray config.json 读取端口和加密方法（不读取密钥）
# =============================================================================
PORT_V4="${PROXY_PORT_V4:-$(jq -r '.inbounds[] | select(.tag=="ss-ipv4") | .port' "${CONFIG}" 2>/dev/null || echo 20001)}"
PORT_V6="${PROXY_PORT_V6:-$(jq -r '.inbounds[] | select(.tag=="ss-ipv6") | .port' "${CONFIG}" 2>/dev/null || echo 20002)}"
PORT_LEGACY="${PROXY_PORT_LEGACY:-$(jq -r '.inbounds[] | select(.tag=="ss-legacy") | .port' "${CONFIG}" 2>/dev/null || echo 20003)}"

METHOD_V4=$(jq -r '.inbounds[] | select(.tag=="ss-ipv4") | .settings.method' "${CONFIG}" 2>/dev/null || echo "2022-blake3-aes-128-gcm")
METHOD_V6=$(jq -r '.inbounds[] | select(.tag=="ss-ipv6") | .settings.method' "${CONFIG}" 2>/dev/null || echo "2022-blake3-aes-128-gcm")

# =============================================================================
# 读取密钥（仅从 proxy.env，不打印到终端）
# =============================================================================
PASS_V4=""
PASS_V6=""
PASS_LEGACY=""

if [[ -f "${PROXY_ENV}" ]]; then
    # 安全逐行读取 proxy.env
    while IFS= read -r line || [[ -n "${line}" ]]; do
        [[ "${line}" =~ ^[[:space:]]*# ]] && continue
        [[ -z "${line// }" ]] && continue
        if [[ "${line}" =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]]; then
            k="${BASH_REMATCH[1]}"
            v="${BASH_REMATCH[2]}"
            case "${k}" in
                _PROXY_KEY_V4)     PASS_V4="${v}" ;;
                _PROXY_KEY_V6)     PASS_V6="${v}" ;;
                _PROXY_KEY_LEGACY) PASS_LEGACY="${v}" ;;
            esac
        fi
    done < "${PROXY_ENV}"
    echo -e "[${green}Info${plain}] 从 ${PROXY_ENV} 读取密钥（不打印）"
else
    # 回退：从 Xray config.json 读取（生产不建议，仅兼容旧版）
    echo -e "[${yellow}Warn${plain}] ${PROXY_ENV} 不存在，从 config.json 读取密钥（建议升级到带 proxy.env 的部署方式）"
    PASS_V4=$(jq -r '.inbounds[] | select(.tag=="ss-ipv4") | .settings.password' "${CONFIG}" 2>/dev/null || echo "")
    PASS_V6=$(jq -r '.inbounds[] | select(.tag=="ss-ipv6") | .settings.password' "${CONFIG}" 2>/dev/null || echo "")
    PASS_LEGACY=$(jq -r '.inbounds[] | select(.tag=="ss-legacy") | .settings.password' "${CONFIG}" 2>/dev/null || echo "")
fi

if [[ -z "${PASS_V4}" ]]; then
    echo -e "[${red}Error${plain}] 无法获取 IPv4 密钥，Clash 配置无法生成！"
    exit 1
fi

# =============================================================================
# 生成 Clash YAML
# =============================================================================
mkdir -p "${SUBSCRIBE_DIR}"

# 构建代理节点列表（条件包含 IPv6/Legacy）
PROXIES_YAML="  - name: \"US-IPv4\"
    type: ss
    server: ${DOMAIN}
    port: ${PORT_V4}
    cipher: ${METHOD_V4}
    password: \"${PASS_V4}\"
    udp: true"

if [[ "${PROXY_ENABLE_IPV6:-true}" == "true" && -n "${PASS_V6}" && -n "${IPV6}" ]]; then
    PROXIES_YAML+="

  - name: \"US-IPv6\"
    type: ss
    server: ${IPV6}
    port: ${PORT_V6}
    cipher: ${METHOD_V6}
    password: \"${PASS_V6}\"
    udp: true"
fi

if [[ "${PROXY_ENABLE_LEGACY:-false}" == "true" && -n "${PASS_LEGACY}" ]]; then
    PROXIES_YAML+="

  - name: \"US-Legacy\"
    type: ss
    server: ${DOMAIN}
    port: ${PORT_LEGACY}
    cipher: aes-256-gcm
    password: \"${PASS_LEGACY}\"
    udp: true"
fi

# 原子写入（mktemp + mv）
TMP_OUT=$(mktemp "${SUBSCRIBE_DIR}/.clash.yaml.XXXXXX")

cat > "${TMP_OUT}" <<YAML
# Xray Portal 自动生成 - 请勿手动修改
# 生成时间: $(date -u +"%Y-%m-%dT%H:%M:%SZ")
port: 7890
socks-port: 7891
allow-lan: false
mode: rule
log-level: warning

proxies:
${PROXIES_YAML}

proxy-groups:
  - name: "Proxy"
    type: select
    proxies:
      - "US-IPv4"
$([ "${PROXY_ENABLE_IPV6:-true}" == "true" ] && echo '      - "US-IPv6"' || true)
$([ "${PROXY_ENABLE_LEGACY:-false}" == "true" ] && echo '      - "US-Legacy"' || true)
      - DIRECT

rules:
  - GEOSITE,CN,DIRECT
  - GEOIP,CN,DIRECT,no-resolve
  - MATCH,Proxy
YAML

chmod 644 "${TMP_OUT}"
mv -f "${TMP_OUT}" "${SUBSCRIBE_FILE}"

echo -e "[${green}Info${plain}] Clash 订阅源已生成: ${SUBSCRIBE_FILE}"
echo -e "[${green}Info${plain}] 代理域名: ${DOMAIN} | IPv4 端口: ${PORT_V4}"
# 注意：不打印任何密钥
