#!/usr/bin/env bash
# =============================================================================
# Xray 配置渲染库 (apps/vpn_web/proxy/lib/render-xray-config.sh)
#
# 安全设计：
#   - 密钥从 /etc/xray-portal/proxy.env 读取（0600）
#   - 若密钥为空则自动安全生成并写入 proxy.env
#   - 生成的密钥绝不打印到 stdout/stderr
#   - 多次运行幂等：检测已有密钥则复用，不重新生成
#   - 自动获取物理机所在国家与国旗 Emoji 并写入 proxy-meta.conf
# =============================================================================

set -euo pipefail

_RENDER_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROXY_ENV_FILE="/etc/xray-portal/proxy.env"
XRAY_CONFIG_FILE="/usr/local/etc/xray/config.json"

# =============================================================================
# 加载或生成代理密钥
# 所有密钥操作全部在此函数内完成，不向外暴露密钥值
# =============================================================================
_load_or_generate_proxy_keys() {
    log_info "加载或生成代理密钥..."

    mkdir -p /etc/xray-portal
    chmod 750 /etc/xray-portal

    # 若 proxy.env 已存在，从中加载密钥（复用已有密钥，保证幂等）
    if [[ -f "${PROXY_ENV_FILE}" ]]; then
        log_info "检测到已有代理配置: ${PROXY_ENV_FILE}，复用现有密钥。"
        # 安全读取（不使用 source，用逐行解析器）
        while IFS= read -r line || [[ -n "${line}" ]]; do
            [[ "${line}" =~ ^[[:space:]]*# ]] && continue
            [[ -z "${line// }" ]] && continue
            if [[ "${line}" =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]]; then
                local k="${BASH_REMATCH[1]}"
                local v="${BASH_REMATCH[2]}"
                # 仅导出密钥相关变量
                case "${k}" in
                    _PROXY_KEY_V4|_PROXY_KEY_V6|_PROXY_KEY_LEGACY)
                        export "${k}"="${v}"
                        ;;
                esac
            fi
        done < "${PROXY_ENV_FILE}"
        return 0
    fi

    # 新生成密钥（不打印到任何终端）
    log_info "未找到代理配置，生成新密钥..."

    # 从环境变量读取（用户显式指定优先）
    _PROXY_KEY_V4="${PROXY_KEY_V4:-}"
    _PROXY_KEY_V6="${PROXY_KEY_V6:-}"
    _PROXY_KEY_LEGACY="${PROXY_KEY_LEGACY:-}"

    # 若用户未指定则自动安全生成（openssl rand 密码学安全随机数）
    if [[ -z "${_PROXY_KEY_V4}" ]]; then
        _PROXY_KEY_V4=$(openssl rand -base64 16)
        log_info "IPv4 密钥：已自动生成（保存至 ${PROXY_ENV_FILE}）"
    else
        log_info "IPv4 密钥：使用用户提供的值"
    fi

    if [[ -z "${_PROXY_KEY_V6}" ]]; then
        _PROXY_KEY_V6=$(openssl rand -base64 16)
        log_info "IPv6 密钥：已自动生成（保存至 ${PROXY_ENV_FILE}）"
    else
        log_info "IPv6 密钥：使用用户提供的值"
    fi

    if [[ -z "${_PROXY_KEY_LEGACY}" ]]; then
        _PROXY_KEY_LEGACY=$(openssl rand -base64 24)
        log_info "Legacy 密钥：已自动生成（保存至 ${PROXY_ENV_FILE}）"
    else
        log_info "Legacy 密钥：使用用户提供的值"
    fi

    # 原子写入 proxy.env（mktemp + mv，避免写断裂）
    local tmp_env
    tmp_env=$(mktemp /tmp/proxy.env.XXXXXX)

    cat > "${tmp_env}" <<EOF
# =============================================================================
# Xray 代理服务运行时密钥配置（由自动部署脚本生成）
# 权限: root:root 0600 - 严禁修改权限或通过任何渠道分享此文件
# 生成时间: $(date -u +"%Y-%m-%dT%H:%M:%SZ")
# =============================================================================
_PROXY_KEY_V4=${_PROXY_KEY_V4}
_PROXY_KEY_V6=${_PROXY_KEY_V6}
_PROXY_KEY_LEGACY=${_PROXY_KEY_LEGACY}
EOF

    # 先设权限，再 mv（确保写入前权限已正确）
    chmod 600 "${tmp_env}"
    chown root:root "${tmp_env}"
    mv -f "${tmp_env}" "${PROXY_ENV_FILE}"

    log_success "代理密钥已写入 ${PROXY_ENV_FILE} (权限: root:root 0600)"
    # 注意：此处绝不输出密钥值
}

# =============================================================================
# 渲染 Xray config.json
# =============================================================================
render_xray_config() {
    log_info "渲染 Xray 配置文件..."

    if [[ "${DRY_RUN:-false}" == "true" ]]; then
        log_info "[DRY-RUN] 渲染 Xray config.json 至 ${XRAY_CONFIG_FILE}"
        return 0
    fi

    # 加载或生成密钥（密钥存于内部变量 _PROXY_KEY_*）
    _load_or_generate_proxy_keys

    local port_v4="${PROXY_PORT_V4:-20001}"
    local port_v6="${PROXY_PORT_V6:-20002}"
    local port_legacy="${PROXY_PORT_LEGACY:-20003}"
    local method_v4="${PROXY_METHOD_V4:-2022-blake3-aes-128-gcm}"
    local method_v6="${PROXY_METHOD_V6:-2022-blake3-aes-128-gcm}"
    local enable_ipv6="${PROXY_ENABLE_IPV6:-true}"
    local enable_legacy="${PROXY_ENABLE_LEGACY:-false}"

    mkdir -p "${XRAY_CONFIG_DIR:-/usr/local/etc/xray}"
    mkdir -p /var/log/xray

    # 构建 inbounds 数组（条件包含 IPv6 和 Legacy）
    local inbounds_json
    inbounds_json=$(cat <<EOF
    {
      "tag": "ss-ipv4",
      "port": ${port_v4},
      "listen": "0.0.0.0",
      "protocol": "shadowsocks",
      "settings": {
        "method": "${method_v4}",
        "password": "${_PROXY_KEY_V4}",
        "network": "tcp,udp"
      }
    }
EOF
)

    if [[ "${enable_ipv6}" == "true" ]]; then
        inbounds_json+=",
    {
      \"tag\": \"ss-ipv6\",
      \"port\": ${port_v6},
      \"listen\": \"::\",
      \"protocol\": \"shadowsocks\",
      \"settings\": {
        \"method\": \"${method_v6}\",
        \"password\": \"${_PROXY_KEY_V6}\",
        \"network\": \"tcp,udp\"
      }
    }"
    fi

    if [[ "${enable_legacy}" == "true" ]]; then
        inbounds_json+=",
    {
      \"tag\": \"ss-legacy\",
      \"port\": ${port_legacy},
      \"listen\": \"0.0.0.0\",
      \"protocol\": \"shadowsocks\",
      \"settings\": {
        \"method\": \"aes-256-gcm\",
        \"password\": \"${_PROXY_KEY_LEGACY}\",
        \"network\": \"tcp,udp\"
      }
    }"
    fi

    # 原子写入 config.json
    local tmp_cfg
    tmp_cfg=$(mktemp /tmp/config.json.XXXXXX)

    cat > "${tmp_cfg}" <<JSONEOF
{
  "log": {
    "loglevel": "warning",
    "access": "/var/log/xray/access.log",
    "error": "/var/log/xray/error.log"
  },
  "inbounds": [
    ${inbounds_json}
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
JSONEOF

    chmod 644 "${tmp_cfg}"
    chown root:root "${tmp_cfg}"
    mv -f "${tmp_cfg}" "${XRAY_CONFIG_FILE}"

    # 自动探测公网 IP 与地理位置（国家、国旗 Emoji）
    local proxy_domain="${PROXY_DOMAIN:-$(curl -fsSL --max-time 5 ipv4.icanhazip.com 2>/dev/null || echo 'unknown')}"
    local detect_py="${_RENDER_LIB_DIR}/detect_geo.py"
    local country_code="UN"
    local country_name="未知地区"
    local country_flag="🌐"
    local city=""

    if [[ -f "${detect_py}" ]]; then
        eval "$(python3 "${detect_py}" "${proxy_domain}" env 2>/dev/null || true)"
        country_code="${PROXY_COUNTRY_CODE:-UN}"
        country_name="${PROXY_COUNTRY_NAME:-未知地区}"
        country_flag="${PROXY_COUNTRY_FLAG:-🌐}"
        city="${PROXY_CITY:-}"
        log_info "检测到服务器地理位置: ${country_flag} ${country_name} (${country_code}${city:+ - ${city}})"
    fi

    # 同步写入 /etc/xray-portal/proxy-meta.conf（不含密钥）
    local meta_file="/etc/xray-portal/proxy-meta.conf"
    local tmp_meta
    tmp_meta=$(mktemp /tmp/proxy-meta.XXXXXX)

    cat > "${tmp_meta}" <<METAEOF
# 代理元数据配置（不含密钥）
PROXY_DOMAIN=${proxy_domain}
PROXY_COUNTRY_CODE=${country_code}
PROXY_COUNTRY_NAME=${country_name}
PROXY_COUNTRY_FLAG=${country_flag}
PROXY_CITY=${city}
PROXY_PORT_V4=${port_v4}
PROXY_PORT_V6=${port_v6}
PROXY_PORT_LEGACY=${port_legacy}
PROXY_METHOD_V4=${method_v4}
PROXY_METHOD_V6=${method_v6}
PROXY_ENABLE_IPV6=${enable_ipv6}
PROXY_ENABLE_LEGACY=${enable_legacy}
METAEOF

    chmod 644 "${tmp_meta}"
    mv -f "${tmp_meta}" "${meta_file}"

    log_success "Xray 配置与节点位置元数据写入完成: ${XRAY_CONFIG_FILE}"
    # 再次确认：不输出任何密钥
    unset _PROXY_KEY_V4 _PROXY_KEY_V6 _PROXY_KEY_LEGACY
}
