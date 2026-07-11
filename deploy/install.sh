#!/usr/bin/env bash
# =============================================================================
# Xray_portal 一键自动化部署主入口 (deploy/install.sh)
#
# 用法:
#   sudo ./deploy/install.sh <us|nl> --env <配置文件> [选项...]
#
# 选项:
#   --env <file>      必需，指定 0600 权限的环境变量配置文件
#   --skip-proxy      跳过 Xray 代理安装（默认：安装）
#   --proxy-only      仅安装代理，跳过控制面板和订阅系统
#   --control-only    仅安装控制面，跳过代理（等价于 --skip-proxy）
#   --skip-web        跳过 vpn-web Flask 面板安装
#   --skip-nginx      跳过 Nginx 配置渲染
#   --no-certbot      跳过 TLS 证书申请（保留 HTTP）
#   --with-proxy      [兼容] 现在是默认行为，保留此参数不报错
#   --dry-run         仅打印执行计划，不产生实际修改
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

# 加载基础通用库（必须先加载，后续函数依赖 log_*）
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/common.sh"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/env.sh"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/ssh-keys.sh"

# =============================================================================
# 用法帮助
# =============================================================================
usage() {
    cat <<'EOF'
用法: sudo ./deploy/install.sh <角色> --env <配置文件> [选项]

角色:
  us              部署美国主控制服务器（代理 + 订阅合并 + Web 面板 + Nginx）
  nl              部署荷兰备用镜像服务器（代理 + 镜像站 + Nginx）

必需参数:
  --env <file>    环境变量配置文件路径（权限必须为 0600）

可选参数:
  --skip-proxy    跳过 Xray 代理安装（当代理已单独安装时使用）
  --proxy-only    仅安装代理，不安装控制面板（无 Web/Nginx/订阅）
  --control-only  仅安装控制面板，跳过代理（等同于 --skip-proxy）
  --skip-web      跳过 Flask Web 面板安装
  --skip-nginx    跳过 Nginx 配置渲染
  --no-certbot    跳过 TLS 证书申请（仅部署 HTTP）
  --with-proxy    [已废弃] 代理安装现为默认行为，此参数可安全忽略
  --dry-run       仅打印执行计划，不执行任何系统修改
  -h, --help      显示此帮助并退出

示例:
  # 美国主服务器完整部署（默认包含代理安装）
  sudo ./deploy/install.sh us --env .env

  # 荷兰副服务器完整部署
  sudo ./deploy/install.sh nl --env .env

  # 仅安装代理（已有控制面板时）
  sudo ./deploy/install.sh us --env .env --proxy-only

  # 跳过代理（代理已提前单独安装）
  sudo ./deploy/install.sh us --env .env --skip-proxy

  # 干跑验证配置（不修改系统）
  sudo ./deploy/install.sh us --env .env --dry-run
EOF
    exit 1
}

# =============================================================================
# 参数解析（所有选项在同一 while/case 中处理）
# =============================================================================
ROLE=""
ENV_FILE=""
SKIP_PROXY="false"
PROXY_ONLY="false"
SKIP_WEB="false"
SKIP_NGINX="false"
NO_CERTBOT="false"
DRY_RUN="${DRY_RUN:-false}"
export DRY_RUN

while [[ $# -gt 0 ]]; do
    case "$1" in
        us|nl)
            ROLE="$1"
            shift
            ;;
        --env)
            if [[ -z "${2:-}" ]]; then
                log_error "--env 参数缺少文件路径"
                usage
            fi
            ENV_FILE="$2"
            shift 2
            ;;
        --skip-proxy|--control-only)
            SKIP_PROXY="true"
            shift
            ;;
        --proxy-only)
            PROXY_ONLY="true"
            shift
            ;;
        --skip-web)
            SKIP_WEB="true"
            shift
            ;;
        --skip-nginx)
            SKIP_NGINX="true"
            shift
            ;;
        --no-certbot)
            NO_CERTBOT="true"
            shift
            ;;
        --with-proxy)
            # 兼容旧参数：代理安装现为默认行为，此参数静默忽略
            log_warn "--with-proxy 现已是默认行为，此参数可从命令中移除。"
            shift
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

# =============================================================================
# 参数完整性校验
# =============================================================================
if [[ -z "${ROLE}" ]]; then
    log_error "缺少必需参数: 角色 (us|nl)"
    usage
fi

if [[ -z "${ENV_FILE}" ]]; then
    log_error "缺少必需参数: --env <文件路径>"
    usage
fi

# --proxy-only 与 --skip-proxy 互斥
if [[ "${PROXY_ONLY}" == "true" && "${SKIP_PROXY}" == "true" ]]; then
    log_error "--proxy-only 与 --skip-proxy/--control-only 不能同时使用"
    exit 1
fi

# =============================================================================
# 启动部署
# =============================================================================
log_info "================================================================"
log_info "  Xray_portal 一键部署系统启动"
log_info "  角色: ${ROLE^^}  |  配置: ${ENV_FILE}"
[[ "${DRY_RUN}" == "true" ]] && log_info "  模式: DRY-RUN（不修改系统）"
log_info "================================================================"

# 环境检查
check_root
check_os

# 安全加载环境变量（安全解析器，不使用 source）
env_load_and_validate "${ROLE}" "${ENV_FILE}"

# 初始化部署状态文件（记录本次部署开始时间）
_state_file="/var/lib/xray-portal/deployment-state.json"
_commit="$(git -C "${ROOT_DIR}" rev-parse --short HEAD 2>/dev/null || echo 'unknown')"
_started_at="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

if [[ "${DRY_RUN}" != "true" ]]; then
    mkdir -p /var/lib/xray-portal
    cat > "${_state_file}" <<EOF
{
  "role": "${ROLE}",
  "commit": "${_commit}",
  "started_at": "${_started_at}",
  "proxy": "pending",
  "proxy_source": "pending",
  "web": "pending",
  "nginx_http": "pending",
  "nginx_tls": "pending",
  "tls": "pending",
  "subscription": "pending",
  "peer_key": "pending",
  "verified_at": null
}
EOF
    chmod 644 "${_state_file}"
fi

# =============================================================================
# 加载角色安装模块（在参数解析和环境加载完成后 source）
# shellcheck disable=SC1091
# =============================================================================
source "${SCRIPT_DIR}/lib/install-us.sh"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/install-nl.sh"

# =============================================================================
# 执行角色流水线
# =============================================================================
case "${ROLE}" in
    us)
        install_us \
            --skip-proxy "${SKIP_PROXY}" \
            --proxy-only "${PROXY_ONLY}" \
            --skip-web "${SKIP_WEB}" \
            --skip-nginx "${SKIP_NGINX}" \
            --no-certbot "${NO_CERTBOT}" \
            --state-file "${_state_file}"
        ;;
    nl)
        install_nl \
            --skip-proxy "${SKIP_PROXY}" \
            --proxy-only "${PROXY_ONLY}" \
            --skip-nginx "${SKIP_NGINX}" \
            --no-certbot "${NO_CERTBOT}" \
            --state-file "${_state_file}"
        ;;
esac

log_success "================================================================"
log_success "  [${ROLE^^}] 角色部署已全部完成"
log_success "  验证: sudo ./deploy/verify.sh ${ROLE} --env ${ENV_FILE}"
log_success "================================================================"
