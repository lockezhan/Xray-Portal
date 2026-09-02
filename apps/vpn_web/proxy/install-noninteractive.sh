#!/usr/bin/env bash
# =============================================================================
# Xray 非交互自动部署入口 (apps/vpn_web/proxy/install-noninteractive.sh)
#
# 用途: 由 deploy/install.sh 在自动部署流水线中调用
# 要求: 所有配置从环境变量读取，绝不调用 read 等交互命令
# 调用方式: bash install-noninteractive.sh（不直接执行）
# =============================================================================

set -euo pipefail

# 获取自身目录（处理 source 调用时 BASH_SOURCE 正确）
_PROXY_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 加载部署库函数（必须先加载 common.sh 才有 log_* 函数）
# shellcheck disable=SC1091
source "${_PROXY_SCRIPT_DIR}/lib/install-xray.sh"
# shellcheck disable=SC1091
source "${_PROXY_SCRIPT_DIR}/lib/render-xray-config.sh"
# shellcheck disable=SC1091
source "${_PROXY_SCRIPT_DIR}/lib/firewall.sh"
# shellcheck disable=SC1091
source "${_PROXY_SCRIPT_DIR}/lib/verify-xray.sh"

# =============================================================================
# 安装系统依赖包（不执行全系统 upgrade）
# =============================================================================
_install_proxy_packages() {
    log_info "安装代理服务依赖包（仅 apt-get update，不 upgrade）..."

    if [[ "${DRY_RUN:-false}" == "true" ]]; then
        log_info "[DRY-RUN] apt-get install curl jq openssl ufw unzip"
        return 0
    fi

    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    # 仅安装必要工具，不执行 apt-get upgrade（避免破坏系统稳定性）
    apt-get install -y --no-install-recommends \
        curl \
        jq \
        openssl \
        ufw \
        unzip \
        coreutils

    # 设置时区为 Asia/Shanghai（中国标准时间 CST UTC+8）
    timedatectl set-timezone Asia/Shanghai 2>/dev/null || true

    log_success "代理依赖包安装完成。"
}

# =============================================================================
# 启用 TCP BBR 拥塞控制（条件执行）
# =============================================================================
_enable_bbr() {
    if [[ "${ENABLE_BBR:-true}" != "true" ]]; then
        log_info "ENABLE_BBR=false，跳过 BBR 配置。"
        return 0
    fi

    log_info "启用 TCP BBR 拥塞控制..."

    if [[ "${DRY_RUN:-false}" == "true" ]]; then
        log_info "[DRY-RUN] 写入 BBR sysctl 配置"
        return 0
    fi

    # 避免重复添加（幂等）
    local sysctl_conf="/etc/sysctl.conf"
    if ! grep -q "net.core.default_qdisc=fq" "${sysctl_conf}" 2>/dev/null; then
        echo "net.core.default_qdisc=fq" >> "${sysctl_conf}"
    fi
    if ! grep -q "net.ipv4.tcp_congestion_control=bbr" "${sysctl_conf}" 2>/dev/null; then
        echo "net.ipv4.tcp_congestion_control=bbr" >> "${sysctl_conf}"
    fi

    sysctl -p -q 2>/dev/null || true
    log_info "BBR 已启用（重启后生效）"
}

# =============================================================================
# 主流水线
# =============================================================================
install_proxy_noninteractive() {
    log_info "=== 开始非交互式 Xray 代理安装 ==="

    # 1. 安装系统依赖
    _install_proxy_packages

    # 2. 安装 Xray（固定版本 + SHA256 校验）
    install_xray

    # 3. 渲染 Xray 配置（密钥安全生成，不打印）
    render_xray_config

    # 4. 配置 Xray systemd 服务
    configure_xray_service

    # 5. 启动 Xray（fail closed：失败则退出）
    restart_xray_service

    # 6. 配置 UFW（先 SSH，再代理端口，再 enable）
    configure_ufw

    # 7. 启用 BBR（可选）
    _enable_bbr

    # 8. 验证 Xray 服务（端口监听确认）
    verify_xray

    log_success "=== Xray 代理安装完成 ==="
}

# 如果脚本被直接执行（而非 source），则运行主函数
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    install_proxy_noninteractive
fi
