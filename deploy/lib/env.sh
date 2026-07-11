#!/usr/bin/env bash
# =============================================================================
# Xray_portal 部署系统环境变量解析与隔离安全验证库 (deploy/lib/env.sh)
# =============================================================================

set -euo pipefail

# =============================================================================
# 加载并严格校验环境变量: env_load_and_validate <role: us|nl> <env_file>
# =============================================================================
env_load_and_validate() {
    local role="$1"
    local env_file="$2"

    if [[ ! -f "${env_file}" ]]; then
        log_error "指定的环境变量配置文件不存在: ${env_file}"
        return 1
    fi

    # 安全检查: 检查并提示收紧配置文件权限至 0600
    local perm
    if [[ "$(uname -s)" == "Linux" ]]; then
        perm=$(stat -c "%a" "${env_file}" 2>/dev/null || echo "unknown")
        if [[ "${perm}" != "600" && "${perm}" != "unknown" ]]; then
            log_warn "配置文件 ${env_file} 权限当前为 ${perm}，建议设置为 0600 以防机密泄露。"
            if [[ "${DRY_RUN}" == "false" ]] && [[ -w "${env_file}" ]]; then
                chmod 600 "${env_file}" 2>/dev/null || true
            fi
        fi
    fi

    # 加载环境变量
    set -a
    # shellcheck disable=SC1090
    source "${env_file}"
    set +a

    # 通用必需项校验 (SUB_TOKEN 长度与占位符校验)
    if [[ -z "${SUB_TOKEN:-}" || "${SUB_TOKEN}" == "replace_me" ]]; then
        log_error "未正确配置 SUB_TOKEN，请修改配置文件填入强随机合规 Token。"
        return 1
    fi

    case "${role}" in
        us)
            # 美国角色必填项检验
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
            export CLASH_US_SOURCE US_PUBLISH_DIR SUBPUSH_USER SUBPUSH_GROUP US_INSTALL_DIR
            log_info "美国主服务器环境变量校验通过。"
            ;;

        nl)
            # 荷兰角色必填项检验
            local required_nl=(NL_SERVER_IP NL_SUB_DOMAIN SUB_TOKEN)
            for var in "${required_nl[@]}"; do
                if [[ -z "${!var:-}" || "${!var}" == "replace_me" ]]; then
                    log_error "荷兰节点必需的环境变量未填或仍为占位符: ${var}"
                    return 1
                fi
            done

            # 安全隔离检测: 严格清理美国专有的密码与 Bot Token，绝不泄露给荷兰系统环境
            if [[ -n "${PORTAL_PASSWORD:-}" || -n "${FLASK_SECRET_KEY:-}" || -n "${BRIDGE_BOT_TOKEN:-}" || -n "${CHANNEL_BOT_TOKEN:-}" ]]; then
                log_warn "检测到荷兰环境变量中包含无关的 Flask/Bot 凭据，已启动安全隔离剥离！"
                unset PORTAL_PASSWORD FLASK_SECRET_KEY BRIDGE_BOT_TOKEN CHANNEL_BOT_TOKEN CHANNEL_GROUP_ID CHANNEL_ADMIN_ID BRIDGE_TARGET_QQ_GROUP BRIDGE_NAPCAT_API_URL || true
            fi

            # 设置荷兰环境默认路径与账户配置
            CLASH_NL_SOURCE="${CLASH_NL_SOURCE:-/var/www/clash/clash.yaml}"
            NL_MIRROR_DIR="${NL_MIRROR_DIR:-/var/www/sub}"
            SUBMIRROR_USER="${SUBMIRROR_USER:-submirror}"
            SUBMIRROR_GROUP="${SUBMIRROR_GROUP:-submirror}"
            export CLASH_NL_SOURCE NL_MIRROR_DIR SUBMIRROR_USER SUBMIRROR_GROUP
            log_info "荷兰副服务器环境变量校验与安全隔离过滤完成。"
            ;;

        *)
            log_error "未知的节点部署角色: ${role} (支持参数: us 或 nl)"
            return 1
            ;;
    esac
}
