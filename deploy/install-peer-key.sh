#!/usr/bin/env bash
# =============================================================================
# Xray_portal 互信节点公钥受限注入工具 (deploy/install-peer-key.sh)
# 用法: sudo ./deploy/install-peer-key.sh <us|nl> --pubkey <公钥字符串或文件路径>
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/common.sh"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/ssh-keys.sh"

ROLE=""
PUBKEY_INPUT=""
USER_OVERRIDE=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        us|nl)
            ROLE="$1"
            shift
            ;;
        --pubkey)
            PUBKEY_INPUT="${2:-}"
            shift 2
            ;;
        --user)
            USER_OVERRIDE="${2:-}"
            shift 2
            ;;
        *)
            log_error "未知参数: $1"
            exit 1
            ;;
    esac
done

if [[ -z "${ROLE}" || -z "${PUBKEY_INPUT}" ]]; then
    log_error "用法: $0 <us|nl> --pubkey <公钥字符串或公钥文件路径>"
    exit 1
fi

check_root

# 解析公钥内容 (支持传入文件路径或公钥字符串本身)
PUBKEY=""
if [[ -f "${PUBKEY_INPUT}" ]]; then
    PUBKEY="$(cat "${PUBKEY_INPUT}")"
else
    PUBKEY="${PUBKEY_INPUT}"
fi

case "${ROLE}" in
    us)
        # 写入美国服务器受限账户 subpush，强制执行 subpush-cmd-wrapper
        target_user="${USER_OVERRIDE:-subpush}"
        auth_file="/opt/clash-sub/.ssh/authorized_keys"
        install_authorized_key "${PUBKEY}" "${auth_file}" "/opt/clash-sub/scripts/subpush-cmd-wrapper" "${target_user}:${target_user}"
        ;;
    nl)
        # 写入荷兰服务器受限账户 submirror
        target_user="${USER_OVERRIDE:-submirror}"
        auth_file="/home/${target_user}/.ssh/authorized_keys"
        install_authorized_key "${PUBKEY}" "${auth_file}" "none" "${target_user}:${target_user}"
        ;;
esac

log_success "互信节点 SSH 公钥已受限注入至目标账户 [${ROLE^^}]。"
