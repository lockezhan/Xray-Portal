#!/usr/bin/env bash
# =============================================================================
# Xray_portal 部署自检与验证脚本 (deploy/verify.sh)
# 用法: ./deploy/verify.sh <us|nl> --env <path_to_env_file>
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/common.sh"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/env.sh"

ROLE=""
ENV_FILE=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        us|nl)
            ROLE="$1"
            shift
            ;;
        --env)
            ENV_FILE="${2:-}"
            shift 2
            ;;
        *)
            log_error "未知参数: $1"
            exit 1
            ;;
    esac
done

if [[ -z "${ROLE}" || -z "${ENV_FILE}" ]]; then
    log_error "用法: $0 <us|nl> --env <文件路径>"
    exit 1
fi

log_info "=== 开始验证 [${ROLE^^}] 角色环境部署状态 ==="
env_load_and_validate "${ROLE}" "${ENV_FILE}"

ERRORS=0

verify_file_exists() {
    local f="$1"
    if [[ ! -e "${f}" ]]; then
        log_error "缺失预期目标文件或目录: ${f}"
        ERRORS=$((ERRORS + 1))
    else
        log_success "校验存在: ${f}"
    fi
}

verify_user_exists() {
    local u="$1"
    if ! id -u "${u}" >/dev/null 2>&1; then
        log_error "系统用户不存在: ${u}"
        ERRORS=$((ERRORS + 1))
    else
        log_success "校验用户存在: ${u}"
    fi
}

case "${ROLE}" in
    us)
        verify_user_exists "${SUBPUSH_USER:-subpush}"
        for d in incoming sources template generated published backups scripts logs; do
            verify_file_exists "${US_INSTALL_DIR:-/opt/clash-sub}/${d}"
        done
        verify_file_exists "${US_INSTALL_DIR:-/opt/clash-sub}/scripts/extract_merge.py"
        verify_file_exists "${US_INSTALL_DIR:-/opt/clash-sub}/scripts/upload_validator.py"
        verify_file_exists "${US_INSTALL_DIR:-/opt/clash-sub}/scripts/subpush-cmd-wrapper"
        verify_file_exists "/usr/local/sbin/rebuild-clash-subscription"
        verify_file_exists "${US_INSTALL_DIR:-/opt/clash-sub}/scripts/config.env"
        verify_file_exists "/usr/local/vpn-web/app.py"
        verify_file_exists "/usr/local/vpn-web/config.py"
        verify_file_exists "/etc/systemd/system/vpn-web.service"
        ;;
    nl)
        verify_user_exists "${SUBMIRROR_USER:-submirror}"
        verify_file_exists "${NL_MIRROR_DIR:-/var/www/sub}/${SUB_TOKEN}"
        verify_file_exists "/usr/local/sbin/push-clash-subscription-nl"
        verify_file_exists "/usr/local/sbin/nl_init"
        ;;
esac

# 检查 Nginx 语法状态
if command -v nginx >/dev/null 2>&1; then
    if nginx -t >/dev/null 2>&1; then
        log_success "Nginx 配置文件语法检查通过。"
    else
        log_error "Nginx 配置文件语法测试未通过，请检查 nginx -t 输出。"
        ERRORS=$((ERRORS + 1))
    fi
else
    log_warn "未在本机检测到 nginx 二进制命令，跳过 Nginx 语法自检。"
fi

if [[ ${ERRORS} -eq 0 ]]; then
    log_success "=== 所有针对 [${ROLE^^}] 角色的部署校验均已通过 ==="
    exit 0
else
    log_error "=== 自检发现 ${ERRORS} 项不合格配置，请排查修正 ==="
    exit 1
fi
