#!/usr/bin/env bash
# =============================================================================
# Xray_portal 部署系统通用基础库 (deploy/lib/common.sh)
# =============================================================================

set -euo pipefail

DRY_RUN="${DRY_RUN:-false}"

# =============================================================================
# 日志输出函数 (注意: 严禁在日志调用传入 Token/密码/私钥等敏感明文)
# =============================================================================
log_info() {
    printf '\033[0;34m[INFO]\033[0m %s\n' "$1"
}

log_success() {
    printf '\033[0;32m[SUCCESS]\033[0m %s\n' "$1"
}

log_warn() {
    printf '\033[0;33m[WARN]\033[0m %s\n' "$1" >&2
}

log_error() {
    printf '\033[0;31m[ERROR]\033[0m %s\n' "$1" >&2
}

# =============================================================================
# root 权限检查
# =============================================================================
check_root() {
    if [[ "${DRY_RUN}" == "true" ]]; then
        return 0
    fi
    if [[ "$(id -u)" -ne 0 ]]; then
        log_error "本操作需 root 权限执行，请使用 sudo 或切换至 root 用户运行。"
        exit 1
    fi
}

# =============================================================================
# 操作系统兼容性检查 (仅支持 Ubuntu/Debian 体系)
# =============================================================================
check_os() {
    if [[ -f /etc/os-release ]]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        case "${ID:-}" in
            ubuntu|debian)
                log_info "检测到兼容操作系统: ${PRETTY_NAME:-$ID}"
                ;;
            *)
                log_warn "操作系统 (${ID:-unknown}) 非官方测试支持的 Ubuntu/Debian，可能存在部分组件路径差异。"
                ;;
        esac
    else
        log_warn "未检测到 /etc/os-release，跳过操作系统环境校验。"
    fi
}

# =============================================================================
# 安全目录创建函数: safe_mkdir <dir> <mode> [owner:group]
# =============================================================================
safe_mkdir() {
    local dir="$1"
    local mode="$2"
    local owner="${3:-}"

    if [[ "${DRY_RUN}" == "true" ]]; then
        log_info "[DRY-RUN] 创建目录 ${dir} (权限: ${mode}, 所有者: ${owner:-默认})"
        return 0
    fi

    mkdir -p "${dir}"
    chmod "${mode}" "${dir}"
    if [[ -n "${owner}" ]]; then
        chown "${owner}" "${dir}"
    fi
}

# =============================================================================
# 原子安全文件部署函数: safe_install <src> <dest> <mode> [owner:group]
# 严禁直接使用 cp -f 暴力覆盖可能处于执行中的脚本，通过生成临时文件后原子 mv 提升
# =============================================================================
safe_install() {
    local src="$1"
    local dest="$2"
    local mode="$3"
    local owner="${4:-}"

    if [[ ! -f "${src}" ]]; then
        log_error "源文件不存在: ${src}"
        return 1
    fi

    if [[ "${DRY_RUN}" == "true" ]]; then
        log_info "[DRY-RUN] 安装文件 ${src} -> ${dest} (权限: ${mode}, 所有者: ${owner:-默认})"
        return 0
    fi

    local dest_dir
    dest_dir="$(dirname "${dest}")"
    mkdir -p "${dest_dir}"

    # 使用同目录下随机临时文件避免写断裂或执行文件占用报错
    local tmp_file
    tmp_file="$(mktemp "${dest_dir}/.$(basename "${dest}").tmp.XXXXXX")"

    # 安装并设定内容与权限
    install -m "${mode}" "${src}" "${tmp_file}"
    if [[ -n "${owner}" ]]; then
        chown "${owner}" "${tmp_file}"
    fi

    # 原子提升更新
    mv -f "${tmp_file}" "${dest}"
}
