#!/usr/bin/env bash
# =============================================================================
# Xray_portal 远程一键自动化部署工具 (deploy/remote-deploy.sh)
# 用法: ./deploy/remote-deploy.sh <us|nl> --host <user@remote_ip> --env <path_to_env>
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/common.sh"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/env.sh"

ROLE=""
REMOTE_HOST=""
ENV_FILE=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        us|nl)
            ROLE="$1"
            shift
            ;;
        --host)
            REMOTE_HOST="${2:-}"
            shift 2
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

if [[ -z "${ROLE}" || -z "${REMOTE_HOST}" || -z "${ENV_FILE}" ]]; then
    log_error "用法: $0 <us|nl> --host <user@remote_ip> --env <本地配置文件路径>"
    exit 1
fi

log_info "=== 准备远程自动化部署 [${ROLE^^}] 至机器: ${REMOTE_HOST} ==="

# 本地先校验环境配置文件
env_load_and_validate "${ROLE}" "${ENV_FILE}"

# 创建临时工作区推送
REMOTE_TMP="/tmp/xray_portal_deploy_$(date +%s)"

log_info "正在推送项目脚本和环境配置至远程机器..."
ssh "${REMOTE_HOST}" "mkdir -p ${REMOTE_TMP} && chmod 700 ${REMOTE_TMP}"

rsync -a --exclude=".git" --exclude="__pycache__" --exclude="*.log" \
      "${ROOT_DIR}/deploy" "${REMOTE_HOST}:${REMOTE_TMP}/"

scp -p "${ENV_FILE}" "${REMOTE_HOST}:${REMOTE_TMP}/deploy.env"
ssh "${REMOTE_HOST}" "chmod 600 ${REMOTE_TMP}/deploy.env"

log_info "在远程机器上以 root 权限执行一键安装指令..."
ssh -t "${REMOTE_HOST}" "sudo ${REMOTE_TMP}/deploy/install.sh ${ROLE} --env ${REMOTE_TMP}/deploy.env && sudo ${REMOTE_TMP}/deploy/verify.sh ${ROLE} --env ${REMOTE_TMP}/deploy.env"

log_info "清理远程构建临时目录..."
ssh "${REMOTE_HOST}" "rm -rf ${REMOTE_TMP}"

log_success "=== 远程机器 [${ROLE^^}] 自动化部署执行成功 ==="
