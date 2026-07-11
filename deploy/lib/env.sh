#!/usr/bin/env bash
# =============================================================================
# Xray_portal 部署系统 - 安全环境变量解析库 (deploy/lib/env.sh)
#
# 安全设计：
#   - 严禁使用 source / . 直接加载 .env 文件，防止 Shell 注入
#   - 仅允许 KEY=VALUE 格式（KEY：字母/数字/下划线，且首字符不为数字）
#   - 自动过滤注释行、空行
#   - 拒绝值中包含 $() 或反引号等命令替换语法
#   - env 文件权限必须为 0600，否则拒绝加载（不降级为 warn）
# =============================================================================

set -euo pipefail

# =============================================================================
# 安全逐行加载环境变量: env_load_safe <env_file>
# =============================================================================
env_load_safe() {
    local env_file="$1"

    if [[ ! -f "${env_file}" ]]; then
        log_error "指定的环境变量配置文件不存在: ${env_file}"
        return 1
    fi

    # 强制权限检查：必须为 0600，拒绝加载宽松权限文件
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

        # 去除首尾空白
        stripped="${line#"${line%%[![:space:]]*}"}"
        stripped="${stripped%"${stripped##*[![:space:]]}"}"

        # 跳过空行
        [[ -z "${stripped}" ]] && continue

        # 跳过注释行（以 # 开头）
        [[ "${stripped}" == \#* ]] && continue

        # 严格匹配 KEY=VALUE 格式
        # KEY: 必须由字母或下划线开头，后续为字母/数字/下划线
        if [[ "${stripped}" =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]]; then
            key="${BASH_REMATCH[1]}"
            val="${BASH_REMATCH[2]}"

            # 去除值首尾的双引号（"value" → value）
            if [[ "${val}" == '"'*'"' ]]; then
                val="${val:1:${#val}-2}"
            fi
            # 去除值首尾的单引号（'value' → value）
            if [[ "${val}" == "'"*"'" ]]; then
                val="${val:1:${#val}-2}"
            fi

            # 拒绝值中包含命令替换语法（防止注入）
            if [[ "${val}" == *'$('* ]]; then
                log_error "env 文件第 ${line_num} 行包含非法命令替换语法 \$(: ${key}"
                return 1
            fi
            if [[ "${val}" == *'`'* ]]; then
                log_error "env 文件第 ${line_num} 行包含非法反引号命令替换: ${key}"
                return 1
            fi

            # 安全导出变量（使用 printf 避免 eval）
            export "${key}"="${val}"
        else
            # 不符合格式的行：如果非空且非注释，记录警告
            log_warn "env 文件第 ${line_num} 行格式不合规，已跳过: ${stripped:0:60}"
        fi

    done < "${env_file}"

    log_info "环境变量安全解析完成: ${env_file} (共 ${line_num} 行)"
}

# =============================================================================
# 加载并严格校验环境变量: env_load_and_validate <role: us|nl> <env_file>
# =============================================================================
env_load_and_validate() {
    local role="$1"
    local env_file="$2"

    # 使用安全解析器加载（不使用 source）
    env_load_safe "${env_file}"

    # 通用必需项校验（SUB_TOKEN 长度与占位符校验）
    if [[ -z "${SUB_TOKEN:-}" || "${SUB_TOKEN}" == "replace_me" ]]; then
        log_error "未正确配置 SUB_TOKEN，请在配置文件中填入强随机合规 Token。"
        return 1
    fi

    # 校验 SUB_TOKEN 最低长度（建议 32 字节 hex = 64 字符）
    if [[ "${#SUB_TOKEN}" -lt 32 ]]; then
        log_error "SUB_TOKEN 长度不足 32 字符（当前: ${#SUB_TOKEN}），安全强度不够，请重新生成。"
        return 1
    fi

    case "${role}" in
        us)
            _validate_us_env
            ;;
        nl)
            _validate_nl_env
            ;;
        *)
            log_error "未知的节点部署角色: ${role} (支持参数: us 或 nl)"
            return 1
            ;;
    esac
}

# =============================================================================
# 美国角色环境变量校验与默认值填充
# =============================================================================
_validate_us_env() {
    local required_us=(US_SERVER_IP US_SUB_DOMAIN SUB_TOKEN PORTAL_PASSWORD FLASK_SECRET_KEY)
    for var in "${required_us[@]}"; do
        if [[ -z "${!var:-}" || "${!var}" == "replace_me" ]]; then
            log_error "美国节点必需的环境变量未填或仍为占位符: ${var}"
            return 1
        fi
    done

    # 设置美国环境默认路径与账户配置
    CLASH_US_SOURCE="${CLASH_US_SOURCE:-/var/www/clash/clash.yaml}"
    US_PUBLISH_DIR="${US_PUBLISH_DIR:-/opt/clash-sub/published}"
    SUBPUSH_USER="${SUBPUSH_USER:-subpush}"
    SUBPUSH_GROUP="${SUBPUSH_GROUP:-subpush}"
    US_INSTALL_DIR="${US_INSTALL_DIR:-/opt/clash-sub}"

    # 代理安装默认值
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

    # Nginx 条件渲染开关默认值
    ENABLE_WEB="${ENABLE_WEB:-true}"
    ENABLE_API="${ENABLE_API:-false}"
    ENABLE_BOTS="${ENABLE_BOTS:-false}"

    # 固定版本默认值（可在 env 中覆盖）
    XRAY_VERSION="${XRAY_VERSION:-v25.6.3}"
    MIHOMO_VERSION="${MIHOMO_VERSION:-v1.18.10}"

    export CLASH_US_SOURCE US_PUBLISH_DIR SUBPUSH_USER SUBPUSH_GROUP US_INSTALL_DIR
    export INSTALL_PROXY PROXY_PORT_V4 PROXY_PORT_V6 PROXY_PORT_LEGACY
    export PROXY_ENABLE_IPV6 PROXY_ENABLE_LEGACY PROXY_METHOD_V4 PROXY_METHOD_V6
    export CONFIGURE_UFW ENABLE_BBR ENABLE_WEB ENABLE_API ENABLE_BOTS
    export XRAY_VERSION MIHOMO_VERSION

    log_info "美国主服务器环境变量校验通过。"
}

# =============================================================================
# 荷兰角色环境变量校验与默认值填充
# =============================================================================
_validate_nl_env() {
    local required_nl=(NL_SERVER_IP NL_SUB_DOMAIN SUB_TOKEN)
    for var in "${required_nl[@]}"; do
        if [[ -z "${!var:-}" || "${!var}" == "replace_me" ]]; then
            log_error "荷兰节点必需的环境变量未填或仍为占位符: ${var}"
            return 1
        fi
    done

    # 安全隔离：严格清理美国专有凭据，绝不泄露给荷兰系统环境
    local us_secrets=(PORTAL_PASSWORD FLASK_SECRET_KEY BRIDGE_BOT_TOKEN CHANNEL_BOT_TOKEN
                      CHANNEL_GROUP_ID CHANNEL_ADMIN_ID BRIDGE_TARGET_QQ_GROUP BRIDGE_NAPCAT_API_URL)
    local found_secrets=()
    for var in "${us_secrets[@]}"; do
        if [[ -n "${!var:-}" ]]; then
            found_secrets+=("${var}")
        fi
    done

    if [[ ${#found_secrets[@]} -gt 0 ]]; then
        log_warn "检测到荷兰环境变量中包含以下美国专有凭据，已强制剥离: ${found_secrets[*]}"
        unset "${us_secrets[@]}" 2>/dev/null || true
    fi

    # 设置荷兰环境默认路径与账户配置
    CLASH_NL_SOURCE="${CLASH_NL_SOURCE:-/var/www/clash/clash.yaml}"
    NL_MIRROR_DIR="${NL_MIRROR_DIR:-/var/www/sub}"
    SUBMIRROR_USER="${SUBMIRROR_USER:-submirror}"
    SUBMIRROR_GROUP="${SUBMIRROR_GROUP:-submirror}"

    # 代理安装默认值（同 US）
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

    # NL 不启用 Web/API/Bots
    ENABLE_WEB="${ENABLE_WEB:-false}"
    ENABLE_API="${ENABLE_API:-false}"
    ENABLE_BOTS="${ENABLE_BOTS:-false}"

    XRAY_VERSION="${XRAY_VERSION:-v25.6.3}"
    MIHOMO_VERSION="${MIHOMO_VERSION:-v1.18.10}"

    export CLASH_NL_SOURCE NL_MIRROR_DIR SUBMIRROR_USER SUBMIRROR_GROUP
    export INSTALL_PROXY PROXY_PORT_V4 PROXY_PORT_V6 PROXY_PORT_LEGACY
    export PROXY_ENABLE_IPV6 PROXY_ENABLE_LEGACY PROXY_METHOD_V4 PROXY_METHOD_V6
    export CONFIGURE_UFW ENABLE_BBR ENABLE_WEB ENABLE_API ENABLE_BOTS
    export XRAY_VERSION MIHOMO_VERSION

    log_info "荷兰副服务器环境变量校验与安全隔离过滤完成。"
}
