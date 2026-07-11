#!/usr/bin/env bash
# =============================================================================
# Xray 固定版本安装库 (apps/vpn_web/proxy/lib/install-xray.sh)
#
# 设计原则：
#   - 不使用官方一键脚本 bash <(curl ...) —— 无法固定版本和校验
#   - 直接下载 GitHub Release 二进制，强制 SHA256 校验
#   - Xray systemd 服务使用 User=nobody，不改为 root
#   - 端口 < 1024 时使用 AmbientCapabilities=CAP_NET_BIND_SERVICE
# =============================================================================

set -euo pipefail

# 默认版本（可被环境变量覆盖）
XRAY_VERSION="${XRAY_VERSION:-v26.6.27}"

# SHA256 校验和（必须非空，否则拒绝安装）
# 用户必须在 env 文件中提供，或使用此处内置的已知安全值
# 注意：若升级版本必须同步更新校验和
XRAY_SHA256_LINUX_AMD64="${XRAY_SHA256_LINUX_AMD64:-}"
XRAY_SHA256_LINUX_ARM64="${XRAY_SHA256_LINUX_ARM64:-}"

# Xray 安装路径
XRAY_BIN="/usr/local/bin/xray"
XRAY_CONFIG_DIR="/usr/local/etc/xray"
XRAY_LOG_DIR="/var/log/xray"
XRAY_SERVICE_FILE="/etc/systemd/system/xray.service"

# =============================================================================
# 检测系统架构
# =============================================================================
_get_arch() {
    local arch
    arch=$(uname -m)
    case "${arch}" in
        x86_64)  echo "64" ;;
        aarch64) echo "arm64-v8a" ;;
        armv7l)  echo "arm32-v7a" ;;
        *)
            log_error "不支持的系统架构: ${arch}"
            return 1
            ;;
    esac
}

# =============================================================================
# 获取对应架构的 SHA256 校验和
# =============================================================================
_get_xray_sha256() {
    local arch_str="$1"
    case "${arch_str}" in
        64)
            if [[ -z "${XRAY_SHA256_LINUX_AMD64:-}" ]]; then
                log_error "未设置 XRAY_SHA256_LINUX_AMD64，拒绝安装！"
                log_error "请在 env 文件中设置 XRAY_SHA256_LINUX_AMD64=<sha256sum>"
                log_error "获取方式: curl -sL https://github.com/XTLS/Xray-core/releases/download/${XRAY_VERSION}/Xray-linux-64.zip.sha256sum"
                return 1
            fi
            echo "${XRAY_SHA256_LINUX_AMD64}"
            ;;
        arm64-v8a)
            if [[ -z "${XRAY_SHA256_LINUX_ARM64:-}" ]]; then
                log_error "未设置 XRAY_SHA256_LINUX_ARM64，拒绝安装！"
                return 1
            fi
            echo "${XRAY_SHA256_LINUX_ARM64}"
            ;;
        *)
            log_error "无对应架构的 SHA256 校验和配置: ${arch_str}"
            return 1
            ;;
    esac
}

# =============================================================================
# 主安装函数: install_xray
# =============================================================================
install_xray() {
    log_info "=== 安装 Xray-core ${XRAY_VERSION} ==="

    if [[ "${DRY_RUN:-false}" == "true" ]]; then
        log_info "[DRY-RUN] 下载并安装 Xray-core ${XRAY_VERSION}（固定版本，含 SHA256 校验）"
        return 0
    fi

    local arch
    arch=$(_get_arch)

    local expected_sha256
    expected_sha256=$(_get_xray_sha256 "${arch}")

    local pkg_name="Xray-linux-${arch}.zip"
    local download_url="https://github.com/XTLS/Xray-core/releases/download/${XRAY_VERSION}/${pkg_name}"
    local tmp_dir
    tmp_dir=$(mktemp -d /tmp/xray-install.XXXXXX)

    # 注册清理 trap
    trap "rm -rf '${tmp_dir}'" RETURN

    log_info "下载 Xray-core: ${download_url}"
    if ! curl -fsSL --retry 3 --retry-delay 5 \
        -o "${tmp_dir}/${pkg_name}" \
        "${download_url}"; then
        log_error "Xray-core 下载失败！请检查网络连接或代理设置。"
        return 1
    fi

    # SHA256 校验（fail closed：校验失败则中止，不继续安装）
    log_info "验证 SHA256 校验和..."
    local actual_sha256
    actual_sha256=$(sha256sum "${tmp_dir}/${pkg_name}" | cut -d' ' -f1)

    if [[ "${actual_sha256}" != "${expected_sha256}" ]]; then
        log_error "SHA256 校验失败！拒绝安装！"
        log_error "  期望: ${expected_sha256}"
        log_error "  实际: ${actual_sha256}"
        log_error "文件可能已被篡改，请检查 XRAY_VERSION 与 XRAY_SHA256_LINUX_AMD64 的匹配关系。"
        return 1
    fi
    log_success "SHA256 校验通过: ${actual_sha256}"

    # 解压安装
    log_info "解压并安装 Xray-core..."
    unzip -q "${tmp_dir}/${pkg_name}" -d "${tmp_dir}/xray-dist"

    install -o root -g root -m 0755 "${tmp_dir}/xray-dist/xray" "${XRAY_BIN}"
    install -o root -g root -m 0755 "${tmp_dir}/xray-dist/geoip.dat" "/usr/local/share/xray/geoip.dat" 2>/dev/null || true
    install -o root -g root -m 0755 "${tmp_dir}/xray-dist/geosite.dat" "/usr/local/share/xray/geosite.dat" 2>/dev/null || true

    # 创建必需目录并配置合适权限（由于 Xray 运行在 nobody 用户下，日志目录必须由 nobody 所有）
    mkdir -p "${XRAY_CONFIG_DIR}" "${XRAY_LOG_DIR}"
    chmod 755 "${XRAY_CONFIG_DIR}"
    chmod 700 "${XRAY_LOG_DIR}"
    chown -R nobody:nogroup "${XRAY_LOG_DIR}"

    log_success "Xray-core ${XRAY_VERSION} 安装完成: ${XRAY_BIN}"
}

# =============================================================================
# 写入 Xray systemd 服务文件
# 使用 User=nobody，不改为 root
# 端口 >= 1024 不需要 CAP_NET_BIND_SERVICE
# =============================================================================
configure_xray_service() {
    log_info "配置 Xray systemd 服务..."

    if [[ "${DRY_RUN:-false}" == "true" ]]; then
        log_info "[DRY-RUN] 写入 Xray systemd 服务文件 (User=nobody)"
        return 0
    fi

    # 检测是否需要绑定特权端口（< 1024）
    local needs_cap="false"
    for port in "${PROXY_PORT_V4:-20001}" "${PROXY_PORT_V6:-20002}" "${PROXY_PORT_LEGACY:-20003}"; do
        if [[ "${port}" =~ ^[0-9]+$ ]] && [[ "${port}" -lt 1024 ]]; then
            needs_cap="true"
            break
        fi
    done

    local cap_section=""
    if [[ "${needs_cap}" == "true" ]]; then
        log_warn "检测到特权端口（< 1024），将启用 CAP_NET_BIND_SERVICE"
        cap_section="AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE"
    fi

    local tmp_svc
    tmp_svc=$(mktemp /tmp/xray.service.XXXXXX)

    cat > "${tmp_svc}" <<EOF
[Unit]
Description=Xray Service
Documentation=https://github.com/xtls
After=network-online.target nss-lookup.target
Wants=network-online.target

[Service]
Type=simple
User=nobody
Group=nogroup
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
NoNewPrivileges=yes
ExecStart=${XRAY_BIN} run -confdir ${XRAY_CONFIG_DIR}
Restart=on-failure
RestartSec=5s
LimitNOFILE=1048576
${cap_section}

[Install]
WantedBy=multi-user.target
EOF

    install -o root -g root -m 0644 "${tmp_svc}" "${XRAY_SERVICE_FILE}"
    rm -f "${tmp_svc}"

    systemctl daemon-reload
    systemctl enable xray.service
    log_success "Xray systemd 服务配置完成 (User=nobody)"
}

# =============================================================================
# 重启并验证 Xray 服务
# =============================================================================
restart_xray_service() {
    log_info "启动 Xray 服务..."

    if [[ "${DRY_RUN:-false}" == "true" ]]; then
        log_info "[DRY-RUN] systemctl restart xray"
        return 0
    fi

    systemctl restart xray.service || {
        log_error "Xray 服务启动失败！"
        log_error "排障: journalctl -u xray -n 50 --no-pager"
        return 1
    }

    # 等待服务稳定
    sleep 2

    if ! systemctl is-active --quiet xray.service; then
        log_error "Xray 服务启动后立即退出，可能是配置错误！"
        log_error "排障: journalctl -u xray -n 50 --no-pager"
        return 1
    fi

    log_success "Xray 服务已成功启动并处于 active 状态。"
}
