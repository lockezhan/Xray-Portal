#!/usr/bin/env bash
# =============================================================================
# UFW 防火墙配置库 (apps/vpn_web/proxy/lib/firewall.sh)
#
# 安全规则：必须先放行 SSH（22/tcp），再启用 UFW
# 防止：启用 UFW 后因缺少 SSH 规则而被锁死服务器
# =============================================================================

set -euo pipefail

# =============================================================================
# 配置 UFW：先 SSH 后代理端口，最后 enable
# =============================================================================
configure_ufw() {
    log_info "配置 UFW 防火墙..."

    if [[ "${CONFIGURE_UFW:-true}" != "true" ]]; then
        log_info "CONFIGURE_UFW=false，跳过防火墙配置。"
        return 0
    fi

    if [[ "${DRY_RUN:-false}" == "true" ]]; then
        log_info "[DRY-RUN] UFW 配置（顺序: SSH → 代理端口 → enable）"
        log_info "[DRY-RUN]   ufw allow 22/tcp"
        log_info "[DRY-RUN]   ufw allow ${PROXY_PORT_V4:-20001}/tcp+udp"
        [[ "${PROXY_ENABLE_IPV6:-true}" == "true" ]] && \
            log_info "[DRY-RUN]   ufw allow ${PROXY_PORT_V6:-20002}/tcp+udp"
        [[ "${PROXY_ENABLE_LEGACY:-false}" == "true" ]] && \
            log_info "[DRY-RUN]   ufw allow ${PROXY_PORT_LEGACY:-20003}/tcp+udp"
        log_info "[DRY-RUN]   ufw --force enable"
        return 0
    fi

    if ! command -v ufw >/dev/null 2>&1; then
        log_error "未找到 ufw 命令，请先安装: apt-get install -y ufw"
        return 1
    fi

    # 第一步：无条件放行 SSH（必须在 enable 之前）
    log_info "放行 SSH (22/tcp)..."
    ufw allow 22/tcp comment 'SSH access - required before enable'

    # 第二步：放行代理端口
    local port_v4="${PROXY_PORT_V4:-20001}"
    log_info "放行 IPv4 代理端口 ${port_v4}..."
    ufw allow "${port_v4}"/tcp comment 'Xray SS IPv4 TCP'
    ufw allow "${port_v4}"/udp comment 'Xray SS IPv4 UDP'

    if [[ "${PROXY_ENABLE_IPV6:-true}" == "true" ]]; then
        local port_v6="${PROXY_PORT_V6:-20002}"
        log_info "放行 IPv6 代理端口 ${port_v6}..."
        ufw allow "${port_v6}"/tcp comment 'Xray SS IPv6 TCP'
        ufw allow "${port_v6}"/udp comment 'Xray SS IPv6 UDP'
    fi

    if [[ "${PROXY_ENABLE_LEGACY:-false}" == "true" ]]; then
        local port_legacy="${PROXY_PORT_LEGACY:-20003}"
        log_info "放行 Legacy 代理端口 ${port_legacy}..."
        ufw allow "${port_legacy}"/tcp comment 'Xray SS Legacy TCP'
        ufw allow "${port_legacy}"/udp comment 'Xray SS Legacy UDP'
    fi

    # 放行 Web 服务与订阅分发端口
    if [[ "${ENABLE_WEB:-true}" == "true" || -n "${US_SUB_DOMAIN:-}" || -n "${NL_SUB_DOMAIN:-}" ]]; then
        log_info "放行 HTTP/HTTPS 端口..."
        ufw allow 80/tcp comment 'Nginx HTTP'
        ufw allow 443/tcp comment 'Nginx HTTPS'
        ufw allow 443/udp comment 'Nginx HTTPS UDP (QUIC)'
    fi

    if [[ "${ENABLE_BOTS:-false}" == "true" ]]; then
        log_info "放行 Bot 服务端口 8083..."
        ufw allow 8083/tcp comment 'Xray Portal Bot HTTPS'
    fi

    # 最后启用 UFW（--force 避免交互确认）
    log_info "启用 UFW（SSH 规则已提前放行，不会锁死连接）..."
    ufw --force enable

    log_info "当前 UFW 规则状态:"
    ufw status numbered | head -30 || true

    log_success "UFW 防火墙配置完成。"
}

# =============================================================================
# 验证 UFW 状态
# =============================================================================
verify_ufw() {
    if command -v ufw >/dev/null 2>&1; then
        local ufw_status
        ufw_status=$(ufw status 2>/dev/null | head -1 || echo "unknown")
        log_info "UFW 状态: ${ufw_status}"
    fi
}
