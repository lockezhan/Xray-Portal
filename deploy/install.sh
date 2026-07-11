#!/usr/bin/env bash
# =============================================================================
# Xray_portal 一键自动化部署主入口 (deploy/install.sh)
# 用法: sudo ./deploy/install.sh <us|nl> --env <path_to_env_file> [--dry-run]
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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
用法: $0 <角色: us | nl> --env <配置文件路径> [--dry-run]

参数说明:
  us         部署美国主控制服务器角色 (需使用完整的 us.env)
  nl         部署荷兰备用镜像服务器角色 (需使用精简的 nl.env)
  --env      指定环境变量配置文件路径 (必须为 0600 严格受限文件)
  --dry-run  仅打印执行计划与目标路径，不产生实际文件修改
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

if [[ -z "${ROLE}" || -z "${ENV_FILE}" ]]; then
    log_error "缺少必需参数: 角色 (us|nl) 或 --env <文件>"
    usage
fi

log_info "=== Xray_portal 一键部署系统启动 (目标角色: ${ROLE^^}) ==="

check_root
check_os
env_load_and_validate "${ROLE}" "${ENV_FILE}"

case "${ROLE}" in
    us)
        install_us
        ;;
    nl)
        install_nl
        ;;
esac

log_success "=== [${ROLE^^}] 角色环境部署已全部完成 ==="
log_info "您可以运行 ./deploy/verify.sh ${ROLE} --env ${ENV_FILE} 执行自检校验。"
