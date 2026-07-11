#!/usr/bin/env bash
# =============================================================================
# Mihomo 固定版本安装库 (deploy/lib/install-mihomo.sh)
#
# 用于 US 角色流水线中安装 Mihomo（Clash Meta）内核，
# 用于订阅配置校验（mihomo -t）
# =============================================================================

set -euo pipefail

# 默认版本（可被环境变量覆盖）
MIHOMO_VERSION="${MIHOMO_VERSION:-v1.18.10}"

# SHA256 校验和（必须非空）
MIHOMO_SHA256_LINUX_AMD64="${MIHOMO_SHA256_LINUX_AMD64:-}"
MIHOMO_SHA256_LINUX_ARM64="${MIHOMO_SHA256_LINUX_ARM64:-}"

MIHOMO_BIN="/usr/local/bin/mihomo"

# =============================================================================
# 检测架构并返回 Mihomo 对应平台包名
# =============================================================================
_get_mihomo_pkg_name() {
    local arch
    arch=$(uname -m)
    case "${arch}" in
        x86_64)
            echo "mihomo-linux-amd64-${MIHOMO_VERSION}.gz"
            ;;
        aarch64)
            echo "mihomo-linux-arm64-${MIHOMO_VERSION}.gz"
            ;;
        *)
            log_error "不支持的系统架构: ${arch}"
            return 1
            ;;
    esac
}

# =============================================================================
# 获取对应架构的 SHA256
# =============================================================================
_get_mihomo_sha256() {
    local arch
    arch=$(uname -m)
    case "${arch}" in
        x86_64)
            if [[ -z "${MIHOMO_SHA256_LINUX_AMD64:-}" ]]; then
                log_error "未设置 MIHOMO_SHA256_LINUX_AMD64，拒绝安装！"
                log_error "获取方式: 查看 https://github.com/MetaCubeX/mihomo/releases/tag/${MIHOMO_VERSION}"
                return 1
            fi
            echo "${MIHOMO_SHA256_LINUX_AMD64}"
            ;;
        aarch64)
            if [[ -z "${MIHOMO_SHA256_LINUX_ARM64:-}" ]]; then
                log_error "未设置 MIHOMO_SHA256_LINUX_ARM64，拒绝安装！"
                return 1
            fi
            echo "${MIHOMO_SHA256_LINUX_ARM64}"
            ;;
        *)
            log_error "无对应架构的 SHA256 校验和: $(uname -m)"
            return 1
            ;;
    esac
}

# =============================================================================
# 主安装函数: install_mihomo
# =============================================================================
install_mihomo() {
    log_info "=== 安装 Mihomo ${MIHOMO_VERSION} ==="

    if [[ "${DRY_RUN:-false}" == "true" ]]; then
        log_info "[DRY-RUN] 下载并安装 Mihomo ${MIHOMO_VERSION}（含 SHA256 校验）"
        return 0
    fi

    # 如果已安装且版本匹配，复用已有版本
    if [[ -x "${MIHOMO_BIN}" ]]; then
        local installed_ver
        installed_ver=$("${MIHOMO_BIN}" -v 2>/dev/null | grep -oP 'v\d+\.\d+\.\d+' | head -1 || echo "unknown")
        if [[ "${installed_ver}" == "${MIHOMO_VERSION}" ]]; then
            log_info "Mihomo ${MIHOMO_VERSION} 已安装，跳过下载。"
            return 0
        fi
        log_info "当前安装版本 ${installed_ver}，目标版本 ${MIHOMO_VERSION}，将升级。"
    fi

    local pkg_name
    pkg_name=$(_get_mihomo_pkg_name)

    local expected_sha256
    expected_sha256=$(_get_mihomo_sha256)

    local download_url="https://github.com/MetaCubeX/mihomo/releases/download/${MIHOMO_VERSION}/${pkg_name}"
    local tmp_dir
    tmp_dir=$(mktemp -d /tmp/mihomo-install.XXXXXX)
    trap "rm -rf '${tmp_dir}'" RETURN

    log_info "下载 Mihomo: ${download_url}"
    if ! curl -fsSL --retry 3 --retry-delay 5 \
        -o "${tmp_dir}/${pkg_name}" \
        "${download_url}"; then
        log_error "Mihomo 下载失败！"
        return 1
    fi

    # SHA256 校验
    log_info "验证 SHA256 校验和..."
    local actual_sha256
    actual_sha256=$(sha256sum "${tmp_dir}/${pkg_name}" | cut -d' ' -f1)

    if [[ "${actual_sha256}" != "${expected_sha256}" ]]; then
        log_error "Mihomo SHA256 校验失败！拒绝安装！"
        log_error "  期望: ${expected_sha256}"
        log_error "  实际: ${actual_sha256}"
        return 1
    fi
    log_success "SHA256 校验通过: ${actual_sha256}"

    # 解压 .gz 文件
    log_info "解压并安装 Mihomo..."
    gunzip -c "${tmp_dir}/${pkg_name}" > "${tmp_dir}/mihomo"
    install -o root -g root -m 0755 "${tmp_dir}/mihomo" "${MIHOMO_BIN}"

    log_success "Mihomo ${MIHOMO_VERSION} 安装完成: ${MIHOMO_BIN}"
}

# =============================================================================
# 验证 Mihomo 可用性
# =============================================================================
verify_mihomo() {
    if [[ ! -x "${MIHOMO_BIN}" ]]; then
        log_error "Mihomo 未安装或不可执行: ${MIHOMO_BIN}"
        return 1
    fi

    local ver
    ver=$("${MIHOMO_BIN}" -v 2>/dev/null | head -1 || echo "unknown")
    log_info "Mihomo 版本: ${ver}"
    log_success "Mihomo 可用性验证通过。"
}
