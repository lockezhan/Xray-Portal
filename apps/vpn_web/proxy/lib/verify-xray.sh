#!/usr/bin/env bash
# =============================================================================
# Xray 服务验证库 (apps/vpn_web/proxy/lib/verify-xray.sh)
# =============================================================================

set -euo pipefail

# =============================================================================
# 验证 Xray 服务是否正常运行并监听预期端口
# =============================================================================
verify_xray() {
    log_info "验证 Xray 服务状态..."

    if [[ "${DRY_RUN:-false}" == "true" ]]; then
        log_info "[DRY-RUN] 验证 xray.service active + 端口监听"
        return 0
    fi

    local errors=0

    # 1. 检查服务 active 状态
    if systemctl is-active --quiet xray.service; then
        log_success "[PASS] xray.service 处于 active 状态"
    else
        log_error "[FAIL] xray.service 未运行"
        log_error "排障: journalctl -u xray -n 30 --no-pager"
        errors=$((errors + 1))
    fi

    # 2. 验证 IPv4 代理端口监听
    local port_v4="${PROXY_PORT_V4:-20001}"
    if ss -tulpn 2>/dev/null | grep -q ":${port_v4}[[:space:]]"; then
        log_success "[PASS] IPv4 代理端口 ${port_v4} 正在监听"
    else
        log_error "[FAIL] IPv4 代理端口 ${port_v4} 未监听"
        errors=$((errors + 1))
    fi

    # 3. 验证 IPv6 代理端口（可选）
    if [[ "${PROXY_ENABLE_IPV6:-true}" == "true" ]]; then
        local port_v6="${PROXY_PORT_V6:-20002}"
        if ss -tulpn 2>/dev/null | grep -q ":${port_v6}[[:space:]]"; then
            log_success "[PASS] IPv6 代理端口 ${port_v6} 正在监听"
        else
            log_error "[FAIL] IPv6 代理端口 ${port_v6} 未监听"
            errors=$((errors + 1))
        fi
    fi

    # 4. 验证 Legacy 端口（可选）
    if [[ "${PROXY_ENABLE_LEGACY:-false}" == "true" ]]; then
        local port_legacy="${PROXY_PORT_LEGACY:-20003}"
        if ss -tulpn 2>/dev/null | grep -q ":${port_legacy}[[:space:]]"; then
            log_success "[PASS] Legacy 代理端口 ${port_legacy} 正在监听"
        else
            log_error "[FAIL] Legacy 代理端口 ${port_legacy} 未监听"
            errors=$((errors + 1))
        fi
    fi

    if [[ ${errors} -gt 0 ]]; then
        log_error "Xray 验证失败（${errors} 项）！"
        return 1
    fi

    log_success "Xray 服务验证全部通过。"
}
