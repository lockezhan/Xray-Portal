#!/usr/bin/env bash
# =============================================================================
# Xray_portal 一键自动化部署主入口 (deploy/install.sh)
# 用法: sudo ./deploy/install.sh <us|nl> --env <path_to_env_file> [--dry-run]
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 自动修复项目中所有入口与运维脚本的可执行权限（解决直接压缩复制文件丢失 +x 的情况）
chmod +x "${SCRIPT_DIR}/"*.sh "${SCRIPT_DIR}/lib/"*.sh "${SCRIPT_DIR}/../apps/vpn_web/proxy/"*.sh "${SCRIPT_DIR}/../scripts/"*.sh 2>/dev/null || true

# 加载基础通用库
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/common.sh"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/env.sh"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/ssh-keys.sh"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/install-us.sh"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/install-nl.sh"

usage() {
    cat <<EOF
用法: $0 <角色: us | nl> --env <配置文件路径> [--with-proxy] [--dry-run]

参数说明:
  us           部署美国主控制服务器角色 (需使用完整的 us.env)
  nl           部署荷兰备用镜像服务器角色 (需使用精简的 nl.env)
  --env        指定环境变量配置文件路径 (必须为 0600 严格受限文件)
  --with-proxy 在部署控制面前，自动顺带执行 Xray 翻墙代理服务安装
  --dry-run    仅打印执行计划与目标路径，不产生实际文件修改
EOF
    exit 1
}

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
        --dry-run)
            DRY_RUN="true"
            export DRY_RUN
            shift
            ;;
        -h|--help)
            usage
            ;;
        *)
            log_error "未知参数: $1"
            usage
            ;;
    esac
done

WITH_PROXY="false"
# 重新解析一次可选开关参数支持 --with-proxy
for arg in "$@"; do
    if [[ "${arg}" == "--with-proxy" ]]; then
        WITH_PROXY="true"
    fi
done

if [[ -z "${ROLE}" || -z "${ENV_FILE}" ]]; then
    log_error "缺少必需参数: 角色 (us|nl) 或 --env <文件>"
    usage
fi

log_info "=== Xray_portal 一键部署系统启动 (目标角色: ${ROLE^^}) ==="

check_root
check_os
env_load_and_validate "${ROLE}" "${ENV_FILE}"

# 1. 如果传递了 --with-proxy，优先执行底层 Xray/Shadowsocks 翻墙节点引擎安装
if [[ "${WITH_PROXY}" == "true" ]]; then
    log_info "=== [阶段 1/2] 正在安装底层 Xray 代理节点核心服务 ==="
    if [[ "${DRY_RUN}" == "true" ]]; then
        log_info "[DRY-RUN] 执行: ${SCRIPT_DIR}/../apps/vpn_web/proxy/install.sh"
    else
        bash "${SCRIPT_DIR}/../apps/vpn_web/proxy/install.sh"
        log_success "底层 Xray 代理服务安装完成。"
    fi
fi

# 2. 执行控制面与订阅面板安装
log_info "=== [阶段 2/2] 正在安装控制面板与订阅合并系统 ==="
case "${ROLE}" in
    us)
        install_us
        ;;
    nl)
        install_nl
        ;;
esac

log_success "=== [${ROLE^^}] 角色控制面与环境部署已全部完成 ==="
log_info "----------------------------------------------------------------------"
log_info "提示：完整系统部署执行次序清单说明："
log_info "  1. 代理节点引擎 (Xray): 如尚未安装，可执行 sudo ./apps/vpn_web/proxy/install.sh"
log_info "  2. 节点配置导出: 安装代理后运行 sudo ./apps/vpn_web/proxy/gen_clash_config.sh"
log_info "  3. 控制面板与分发: 运行本脚本 sudo ./deploy/install.sh ${ROLE} --env ${ENV_FILE}"
log_info "  4. 自检校验命令: ./deploy/verify.sh ${ROLE} --env ${ENV_FILE}"
log_info "----------------------------------------------------------------------"
