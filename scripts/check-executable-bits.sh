#!/usr/bin/env bash
# =============================================================================
# 验证所有应具有 executable bit 的 Shell 脚本
# scripts/check-executable-bits.sh
# =============================================================================

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# 应当具有 executable bit 的所有入口/库文件
EXPECTED_EXECUTABLE=(
    "deploy/install.sh"
    "deploy/verify.sh"
    "apps/vpn_web/proxy/install.sh"
    "apps/vpn_web/proxy/install-noninteractive.sh"
    "apps/vpn_web/proxy/gen_clash_config.sh"
    "apps/vpn_web/proxy/lib/install-xray.sh"
    "apps/vpn_web/proxy/lib/render-xray-config.sh"
    "apps/vpn_web/proxy/lib/firewall.sh"
    "apps/vpn_web/proxy/lib/verify-xray.sh"
    "deploy/lib/env.sh"
    "deploy/lib/common.sh"
    "deploy/lib/install-primary.sh"
    "deploy/lib/install-secondary.sh"
    "deploy/lib/install-mihomo.sh"
    "deploy/lib/ssh-keys.sh"
    "deploy/clash-sub/primary/rebuild-clash-subscription.sh"
    "deploy/clash-sub/secondary/push-clash-subscription-secondary.sh"
    "scripts/tests/test-install.sh"
    "scripts/check-executable-bits.sh"
)

ERRORS=0

echo "检查 Shell 脚本 executable bit..."

for script in "${EXPECTED_EXECUTABLE[@]}"; do
    full="${ROOT_DIR}/${script}"
    if [[ ! -f "${full}" ]]; then
        printf '\033[0;33m[MISS]\033[0m %s (文件不存在，跳过)\n' "${script}"
        continue
    fi
    if [[ ! -x "${full}" ]]; then
        printf '\033[0;31m[FAIL]\033[0m %s\n' "${script}"
        echo "  修复: chmod +x ${script}"
        ERRORS=$((ERRORS+1))
    else
        printf '\033[0;32m[OK  ]\033[0m %s\n' "${script}"
    fi
done

if [[ ${ERRORS} -gt 0 ]]; then
    echo ""
    echo "发现 ${ERRORS} 个脚本缺少 executable bit。"
    echo "批量修复："
    for script in "${EXPECTED_EXECUTABLE[@]}"; do
        full="${ROOT_DIR}/${script}"
        [[ -f "${full}" && ! -x "${full}" ]] && echo "  chmod +x ${ROOT_DIR}/${script}"
    done
    exit 1
fi

echo ""
echo "所有脚本 executable bit 检查通过。"
exit 0
