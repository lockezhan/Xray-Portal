#!/usr/bin/env bash
# =============================================================================
# Xray_portal 部署系统 - 安全环境变量解析库 (deploy/lib/env.sh)
# =============================================================================

set -euo pipefail

env_load_safe() {
    local env_file="$1"

    if [[ ! -f "${env_file}" ]]; then
        log_error "指定的环境变量配置文件不存在: ${env_file}"
        return 1
    fi

    if [[ "$(uname -s)" == "Linux" ]]; then
        local perm
        perm=$(stat -c "%a" "${env_file}" 2>/dev/null || echo "unknown")
        if [[ "${perm}" == "unknown" ]]; then
            log_error "无法读取文件权限: ${env_file}"
            return 1
        fi
        if [[ "${perm}" != "600" ]]; then
            log_error "配置文件权限为 ${perm}，必须为 0600 才允许加载。请执行: chmod 600 ${env_file}"
            return 1
        fi
    fi

    local line_num=0
    local key val stripped

    while IFS= read -r line || [[ -n "${line}" ]]; do
        line_num=$((line_num + 1))
        stripped="${line#"${line%%[![:space:]]*}"}"
        stripped="${stripped%"${stripped##*[![:space:]]}"}"
        [[ -z "${stripped}" ]] && continue
        [[ "${stripped}" == \#* ]] && continue

        if [[ "${stripped}" =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]]; then
            key="${BASH_REMATCH[1]}"
            val="${BASH_REMATCH[2]}"
            if [[ "${val}" == '"'*'"' ]]; then
                val="${val:1:${#val}-2}"
            fi
            if [[ "${val}" == "'"*"'" ]]; then
                val="${val:1:${#val}-2}"
            fi
            if [[ "${val}" == *'$('* ]]; then
                log_error "env 文件第 ${line_num} 行包含非法命令替换语法 \$(: ${key}"
                return 1
            fi
            if [[ "${val}" == *'`'* ]]; then
                log_error "env 文件第 ${line_num} 行包含非法反引号命令替换: ${key}"
                return 1
            fi
            export "${key}"="${val}"
        else
            log_warn "env 文件第 ${line_num} 行格式不合规，已跳过: ${stripped:0:60}"
        fi
    done < "${env_file}"

    log_info "环境变量安全解析完成: ${env_file} (共 ${line_num} 行)"
}

_map_legacy_vars() {
    local mappings=(
        "US_SERVER_IP:PRIMARY_SERVER_IP"
        "NL_SERVER_IP:SECONDARY_SERVER_IP"
        "US_SUB_DOMAIN:PRIMARY_SUB_DOMAIN"
        "NL_SUB_DOMAIN:SECONDARY_SUB_DOMAIN"
        "CLASH_US_SOURCE:CLASH_PRIMARY_SOURCE"
        "CLASH_NL_SOURCE:CLASH_SECONDARY_SOURCE"
        "US_PUBLISH_DIR:PRIMARY_PUBLISH_DIR"
        "NL_MIRROR_DIR:SECONDARY_MIRROR_DIR"
    )

    for mapping in "${mappings[@]}"; do
        local old_key="${mapping%%:*}"
        local new_key="${mapping##*:}"

        local old_val="${!old_key:-}"
        local new_val="${!new_key:-}"

        if [[ -n "${old_val}" ]]; then
            if [[ -z "${new_val}" ]]; then
                log_warn "[DEPRECATED] 环境变量 ${old_key} 已弃用，已自动映射为 ${new_key}"
                export "${new_key}"="${old_val}"
            elif [[ "${old_val}" != "${new_val}" ]]; then
                log_error "发现冲突的环境变量: ${old_key} (${old_val}) 与 ${new_key} (${new_val}) 值不一致，请统一配置为 ${new_key} 后重试！"
                return 1
            fi
        fi
    done
}

env_load_and_validate() {
    local role="$1"
    local env_file="$2"

    env_load_safe "${env_file}"
    _map_legacy_vars || return 1

    if [[ -z "${SUB_TOKEN:-}" || "${SUB_TOKEN}" == "replace_me" ]]; then
        log_error "未正确配置 SUB_TOKEN，请在配置文件中填入强随机合规 Token。"
        return 1
    fi

    if [[ "${#SUB_TOKEN}" -lt 32 ]]; then
        log_error "SUB_TOKEN 长度不足 32 字符（当前: ${#SUB_TOKEN}），安全强度不够，请重新生成。"
        return 1
    fi

    DEFAULT_EGRESS_ROLE="${DEFAULT_EGRESS_ROLE:-primary}"
    SENSITIVE_EGRESS_ROLE="${SENSITIVE_EGRESS_ROLE:-secondary}"

    for r in "${DEFAULT_EGRESS_ROLE}" "${SENSITIVE_EGRESS_ROLE}"; do
        if [[ "$r" != "primary" && "$r" != "secondary" ]]; then
            log_error "非法出站策略角色: $r (必须为 primary 或 secondary)"
            return 1
        fi
    done

    # 统一转换角色名
    if [[ "${role}" == "us" ]]; then
        role="primary"
    elif [[ "${role}" == "nl" ]]; then
        role="secondary"
    fi

    case "${role}" in
        primary) _validate_primary_env ;;
        secondary) _validate_secondary_env ;;
        *)
            log_error "未知的节点部署角色: ${role} (支持参数: primary 或 secondary)"
            return 1
            ;;
    esac

    _validate_bots_env "${role}" || return 1
}

_validate_bots_env() {
    local role="$1"

    if [[ "${BOT_HOST_ROLE}" != "primary" && "${BOT_HOST_ROLE}" != "secondary" && "${BOT_HOST_ROLE}" != "none" ]]; then
        log_error "非法 BOT_HOST_ROLE 配置: ${BOT_HOST_ROLE} (必须为 primary, secondary 或 none)"
        return 1
    fi

    if [[ "${ENABLE_BOTS:-false}" == "true" ]]; then
        if [[ "${BOT_HOST_ROLE}" == "${role}" ]]; then
            if [[ -z "${BRIDGE_PUBLIC_BASE_URL:-}" && -z "${BRIDGE_SERVER_PUBLIC_IP:-}" ]]; then
                log_error "节点配置了运行 Bot，但未配置 BRIDGE_PUBLIC_BASE_URL。"
                return 1
            fi
            if [[ -z "${BRIDGE_BOT_TOKEN:-}" || "${BRIDGE_BOT_TOKEN}" == "replace_me" ]]; then
                log_error "节点配置了运行 Bot，但 BRIDGE_BOT_TOKEN 未正确配置。"
                return 1
            fi
            if [[ -z "${TELEGRAM_USER_API_ID:-}" || "${TELEGRAM_USER_API_ID}" == "replace_me" ]]; then
                log_error "节点配置了运行 Bot，但 TELEGRAM_USER_API_ID 未正确配置。"
                return 1
            fi
            if [[ -z "${TELEGRAM_USER_API_HASH:-}" || "${TELEGRAM_USER_API_HASH}" == "replace_me" ]]; then
                log_error "节点配置了运行 Bot，但 TELEGRAM_USER_API_HASH 未正确配置。"
                return 1
            fi

            # 校验端口范围 1-65535
            local web_port="${BRIDGE_WEB_PORT:-8082}"
            if ! [[ "${web_port}" =~ ^[0-9]+$ ]] || [ "${web_port}" -lt 1 ] || [ "${web_port}" -gt 65535 ]; then
                log_error "BRIDGE_WEB_PORT 必须在 1-65535 范围内，当前: ${web_port}"
                return 1
            fi

            local pub_port="${BRIDGE_PUBLIC_PORT:-8083}"
            if ! [[ "${pub_port}" =~ ^[0-9]+$ ]] || [ "${pub_port}" -lt 1 ] || [ "${pub_port}" -gt 65535 ]; then
                log_error "BRIDGE_PUBLIC_PORT 必须在 1-65535 范围内，当前: ${pub_port}"
                return 1
            fi
        fi
    fi
}

_validate_primary_env() {
    local required_primary=(PRIMARY_SERVER_IP PRIMARY_SUB_DOMAIN SUB_TOKEN PORTAL_PASSWORD FLASK_SECRET_KEY)
    for var in "${required_primary[@]}"; do
        if [[ -z "${!var:-}" || "${!var}" == "replace_me" ]]; then
            log_error "Primary 节点必需的环境变量未填或仍为占位符: ${var}"
            return 1
        fi
    done

    CLASH_PRIMARY_SOURCE="${CLASH_PRIMARY_SOURCE:-/var/www/clash/clash.yaml}"
    PRIMARY_PUBLISH_DIR="${PRIMARY_PUBLISH_DIR:-/opt/clash-sub/published}"
    SUBPUSH_USER="${SUBPUSH_USER:-subpush}"
    SUBPUSH_GROUP="${SUBPUSH_GROUP:-subpush}"
    PRIMARY_INSTALL_DIR="${PRIMARY_INSTALL_DIR:-/opt/clash-sub}"

    INSTALL_PROXY="${INSTALL_PROXY:-true}"
    PROXY_PORT_V4="${PROXY_PORT_V4:-20001}"
    PROXY_PORT_V6="${PROXY_PORT_V6:-20002}"
    PROXY_PORT_LEGACY="${PROXY_PORT_LEGACY:-20003}"
    PROXY_ENABLE_IPV6="${PROXY_ENABLE_IPV6:-true}"
    PROXY_ENABLE_LEGACY="${PROXY_ENABLE_LEGACY:-false}"
    PROXY_METHOD_V4="${PROXY_METHOD_V4:-2022-blake3-aes-128-gcm}"
    PROXY_METHOD_V6="${PROXY_METHOD_V6:-2022-blake3-aes-128-gcm}"
    CONFIGURE_UFW="${CONFIGURE_UFW:-true}"
    ENABLE_BBR="${ENABLE_BBR:-true}"

    ENABLE_WEB="${ENABLE_WEB:-true}"
    ENABLE_API="${ENABLE_API:-false}"
    ENABLE_BOTS="${ENABLE_BOTS:-false}"
    BOT_HOST_ROLE="${BOT_HOST_ROLE:-none}"

    XRAY_VERSION="${XRAY_VERSION:-v25.6.3}"
    MIHOMO_VERSION="${MIHOMO_VERSION:-v1.18.10}"

    export CLASH_PRIMARY_SOURCE PRIMARY_PUBLISH_DIR SUBPUSH_USER SUBPUSH_GROUP PRIMARY_INSTALL_DIR
    export INSTALL_PROXY PROXY_PORT_V4 PROXY_PORT_V6 PROXY_PORT_LEGACY
    export PROXY_ENABLE_IPV6 PROXY_ENABLE_LEGACY PROXY_METHOD_V4 PROXY_METHOD_V6
    export CONFIGURE_UFW ENABLE_BBR ENABLE_WEB ENABLE_API ENABLE_BOTS BOT_HOST_ROLE
    export XRAY_VERSION MIHOMO_VERSION

    log_info "Primary 主服务器环境变量校验通过。"
}

_validate_secondary_env() {
    local required_secondary=(SECONDARY_SERVER_IP SECONDARY_SUB_DOMAIN SUB_TOKEN PRIMARY_SERVER_IP)
    for var in "${required_secondary[@]}"; do
        if [[ -z "${!var:-}" || "${!var}" == "replace_me" ]]; then
            log_error "Secondary 节点必需的环境变量未填或仍为占位符: ${var}"
            return 1
        fi
    done

    # 隔离剥离仅属于 Primary Web 服务的敏感凭据，防止在镜像节点滞留
    local primary_secrets=(PORTAL_PASSWORD FLASK_SECRET_KEY)
    local found_secrets=()
    for var in "${primary_secrets[@]}"; do
        if [[ -n "${!var:-}" ]]; then
            found_secrets+=("${var}")
        fi
    done

    if [[ ${#found_secrets[@]} -gt 0 ]]; then
        log_warn "检测到 Secondary 环境变量中包含 Primary 专有凭据，已强制剥离: ${found_secrets[*]}"
        unset "${primary_secrets[@]}" 2>/dev/null || true
    fi

    CLASH_SECONDARY_SOURCE="${CLASH_SECONDARY_SOURCE:-/var/www/clash/clash.yaml}"
    SECONDARY_MIRROR_DIR="${SECONDARY_MIRROR_DIR:-/var/www/sub}"
    SUBMIRROR_USER="${SUBMIRROR_USER:-submirror}"
    SUBMIRROR_GROUP="${SUBMIRROR_GROUP:-submirror}"

    INSTALL_PROXY="${INSTALL_PROXY:-true}"
    PROXY_PORT_V4="${PROXY_PORT_V4:-20001}"
    PROXY_PORT_V6="${PROXY_PORT_V6:-20002}"
    PROXY_PORT_LEGACY="${PROXY_PORT_LEGACY:-20003}"
    PROXY_ENABLE_IPV6="${PROXY_ENABLE_IPV6:-true}"
    PROXY_ENABLE_LEGACY="${PROXY_ENABLE_LEGACY:-false}"
    PROXY_METHOD_V4="${PROXY_METHOD_V4:-2022-blake3-aes-128-gcm}"
    PROXY_METHOD_V6="${PROXY_METHOD_V6:-2022-blake3-aes-128-gcm}"
    CONFIGURE_UFW="${CONFIGURE_UFW:-true}"
    ENABLE_BBR="${ENABLE_BBR:-true}"

    ENABLE_WEB="${ENABLE_WEB:-false}"
    ENABLE_API="${ENABLE_API:-false}"
    ENABLE_BOTS="${ENABLE_BOTS:-false}"
    BOT_HOST_ROLE="${BOT_HOST_ROLE:-none}"

    XRAY_VERSION="${XRAY_VERSION:-v25.6.3}"
    MIHOMO_VERSION="${MIHOMO_VERSION:-v1.18.10}"

    export CLASH_SECONDARY_SOURCE SECONDARY_MIRROR_DIR SUBMIRROR_USER SUBMIRROR_GROUP
    export INSTALL_PROXY PROXY_PORT_V4 PROXY_PORT_V6 PROXY_PORT_LEGACY
    export PROXY_ENABLE_IPV6 PROXY_ENABLE_LEGACY PROXY_METHOD_V4 PROXY_METHOD_V6
    export CONFIGURE_UFW ENABLE_BBR ENABLE_WEB ENABLE_API ENABLE_BOTS BOT_HOST_ROLE
    export XRAY_VERSION MIHOMO_VERSION

    log_info "Secondary 副服务器环境变量校验与安全隔离过滤完成。"
}
