#!/usr/bin/env bash
# =============================================================================
# Xray_portal 部署状态完整验证脚本 (deploy/verify.sh)
#
# 用法: sudo ./deploy/verify.sh <us|nl> --env <配置文件> [--verbose]
#
# 输出格式:
#   [PASS]    - 检查通过
#   [FAIL]    - 检查失败（脚本以非零退出）
#   [SKIP]    - 检查被跳过（组件未安装）
#   [PENDING] - 等待人工操作（不报错，但不算成功）
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/common.sh"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/env.sh"

ROLE=""
ENV_FILE=""
VERBOSE="false"

while [[ $# -gt 0 ]]; do
    case "$1" in
        us|nl)   ROLE="$1"; shift ;;
        --env)   ENV_FILE="${2:-}"; shift 2 ;;
        --verbose|-v) VERBOSE="true"; shift ;;
        *)
            log_error "未知参数: $1"
            echo "用法: $0 <us|nl> --env <文件路径> [--verbose]"
            exit 1
            ;;
    esac
done

if [[ -z "${ROLE}" || -z "${ENV_FILE}" ]]; then
    log_error "用法: $0 <us|nl> --env <文件路径>"
    exit 1
fi

log_info "=== 开始验证 [${ROLE^^}] 角色部署状态 ==="
env_load_and_validate "${ROLE}" "${ENV_FILE}"

# =============================================================================
# 验证计数器
# =============================================================================
PASS=0
FAIL=0
SKIP=0
PENDING=0

# =============================================================================
# 辅助函数
# =============================================================================

_check() {
    local label="$1"
    local result="$2"  # PASS|FAIL|SKIP|PENDING
    local detail="${3:-}"

    case "${result}" in
        PASS)
            PASS=$((PASS+1))
            printf '\033[0;32m[PASS]\033[0m %s\n' "${label}"
            ;;
        FAIL)
            FAIL=$((FAIL+1))
            printf '\033[0;31m[FAIL]\033[0m %s\n' "${label}"
            [[ -n "${detail}" ]] && printf '       → %s\n' "${detail}"
            ;;
        SKIP)
            SKIP=$((SKIP+1))
            printf '\033[0;33m[SKIP]\033[0m %s\n' "${label}"
            ;;
        PENDING)
            PENDING=$((PENDING+1))
            printf '\033[0;34m[PENDING]\033[0m %s\n' "${label}"
            [[ -n "${detail}" ]] && printf '          → %s\n' "${detail}"
            ;;
    esac
}

_svc_active() {
    local svc="$1"
    systemctl is-active --quiet "${svc}" 2>/dev/null && echo "PASS" || echo "FAIL"
}

_port_listening() {
    local port="$1"
    ss -tulpn 2>/dev/null | grep -q ":${port}[[:space:]]" && echo "PASS" || echo "FAIL"
}

_http_check() {
    local url="$1"
    local expected_code="${2:-200}"
    local actual_code
    actual_code=$(curl --silent --fail --max-time 10 \
        --write-out '%{http_code}' --output /dev/null \
        "${url}" 2>/dev/null || echo "000")
    [[ "${actual_code}" == "${expected_code}" ]] && echo "PASS" || echo "FAIL:${actual_code}"
}

_yaml_valid() {
    local file="$1"
    [[ -f "${file}" ]] || { echo "FAIL:not-found"; return; }
    python3 -c "import yaml; yaml.safe_load(open('${file}'))" 2>/dev/null && echo "PASS" || echo "FAIL:invalid-yaml"
}

_file_perm() {
    local file="$1"
    local expected_perm="$2"
    [[ -f "${file}" ]] || { echo "FAIL:not-found"; return; }
    local actual_perm
    actual_perm=$(stat -c "%a" "${file}" 2>/dev/null || echo "unknown")
    [[ "${actual_perm}" == "${expected_perm}" ]] && echo "PASS" || echo "FAIL:${actual_perm}"
}

# =============================================================================
# US 角色验证
# =============================================================================

verify_us() {
    log_info ""
    log_info "--- Xray 代理服务 ---"

    _check "xray.service 处于 active 状态" "$(_svc_active xray.service)" \
        "排障: systemctl status xray; journalctl -u xray -n 30 --no-pager"

    local port_v4="${PROXY_PORT_V4:-20001}"
    _check "IPv4 代理端口 ${port_v4} 正在监听" "$(_port_listening "${port_v4}")" \
        "排障: ss -tulpn | grep ${port_v4}"

    if [[ "${PROXY_ENABLE_IPV6:-true}" == "true" ]]; then
        local port_v6="${PROXY_PORT_V6:-20002}"
        _check "IPv6 代理端口 ${port_v6} 正在监听" "$(_port_listening "${port_v6}")"
    else
        _check "IPv6 代理端口" "SKIP"
    fi

    log_info ""
    log_info "--- Clash 订阅构建 ---"

    local clash_source="${CLASH_US_SOURCE:-/var/www/clash/clash.yaml}"
    _check "Clash 原始配置 ${clash_source} 存在" \
        "$([ -f "${clash_source}" ] && echo PASS || echo FAIL)" \
        "排障: sudo bash apps/vpn_web/proxy/gen_clash_config.sh"

    _check "Clash 原始配置 YAML 语法合法" "$(_yaml_valid "${clash_source}")"

    _check "mihomo 可执行文件存在" \
        "$(command -v mihomo >/dev/null 2>&1 && echo PASS || echo FAIL)"

    local published="${US_PUBLISH_DIR:-/opt/clash-sub/published}/clash.yaml"
    _check "最终订阅文件存在: ${published}" \
        "$([ -f "${published}" ] && echo PASS || echo FAIL)" \
        "排障: sudo /usr/local/sbin/rebuild-clash-subscription"

    if command -v mihomo >/dev/null 2>&1 && [[ -f "${published}" ]]; then
        local test_dir
        test_dir=$(mktemp -d /tmp/mihomo-verify.XXXXXX)
        cp "${published}" "${test_dir}/config.yaml"
        local mihomo_result
        if mihomo -t -d "${test_dir}" >/dev/null 2>&1; then
            mihomo_result="PASS"
        else
            mihomo_result="FAIL"
        fi
        rm -rf "${test_dir}"
        _check "最终订阅通过 Mihomo 内核校验 (-t)" "${mihomo_result}" \
            "排障: mihomo -t -d /tmp/test-dir（复制 published clash.yaml 后测试）"
    else
        _check "Mihomo 内核校验" "SKIP"
    fi

    # 验证 GENERAL-PROXY 为 fallback 类型、SENSITIVE-NL 不含美国节点
    if [[ -f "${published}" ]]; then
        local gp_type
        gp_type=$(python3 -c "
import yaml, sys
c = yaml.safe_load(open('${published}'))
groups = {g['name']: g for g in c.get('proxy-groups', [])}
gp = groups.get('GENERAL-PROXY', {})
print(gp.get('type', 'missing'))
" 2>/dev/null || echo "error")
        _check "GENERAL-PROXY 代理组类型为 fallback" \
            "$([ "${gp_type}" = "fallback" ] && echo PASS || echo "FAIL:${gp_type}")"

        local sensitive_us_count
        sensitive_us_count=$(python3 -c "
import yaml
c = yaml.safe_load(open('${published}'))
groups = {g['name']: g for g in c.get('proxy-groups', [])}
nl = groups.get('SENSITIVE-NL', {})
proxies = nl.get('proxies', [])
bad = [p for p in proxies if p.startswith('US-') or p == 'DIRECT' or p == 'GENERAL-PROXY']
print(len(bad))
" 2>/dev/null || echo "error")
        _check "SENSITIVE-NL 不含美国节点或 DIRECT" \
            "$([ "${sensitive_us_count}" = "0" ] && echo PASS || echo "FAIL:found-${sensitive_us_count}")"
    fi

    log_info ""
    log_info "--- Web 面板 ---"

    _check "vpn-web.service 处于 active 状态" "$(_svc_active vpn-web.service)" \
        "排障: journalctl -u vpn-web -n 50 --no-pager"

    local health_result
    health_result=$(_http_check "http://127.0.0.1:8080/health" "200")
    _check "本地 Web 健康检查 http://127.0.0.1:8080/health 返回 200" "${health_result}" \
        "排障: curl -v http://127.0.0.1:8080/health; journalctl -u vpn-web -n 20"

    log_info ""
    log_info "--- Nginx 与 TLS ---"

    _check "nginx.service 处于 active 状态" "$(_svc_active nginx.service)"

    if command -v nginx >/dev/null 2>&1; then
        local nginx_test
        nginx_test=$(nginx -t 2>&1 >/dev/null && echo "PASS" || echo "FAIL")
        _check "Nginx 配置语法测试通过 (nginx -t)" "${nginx_test}"
    fi

    # 访问控制验证（通过 127.0.0.1 + Host 头）
    local domain="${US_SUB_DOMAIN}"
    local token="${SUB_TOKEN}"

    if systemctl is-active --quiet nginx.service 2>/dev/null; then
        # 无 Token 路径应返回 410
        local no_token_code
        no_token_code=$(curl --silent --max-time 5 \
            --write-out '%{http_code}' --output /dev/null \
            --resolve "${domain}:80:127.0.0.1" \
            "http://${domain}/clash.yaml" 2>/dev/null || echo "000")
        _check "/clash.yaml（无 Token）返回 410" \
            "$([ "${no_token_code}" = "410" ] && echo PASS || echo "FAIL:${no_token_code}")"

        # 错误 Token 不应返回 200
        local wrong_token_code
        wrong_token_code=$(curl --silent --max-time 5 \
            --write-out '%{http_code}' --output /dev/null \
            --resolve "${domain}:80:127.0.0.1" \
            "http://${domain}/invalid-fake-token-12345/clash.yaml" 2>/dev/null || echo "000")
        _check "错误 Token 不返回 200" \
            "$([ "${wrong_token_code}" != "200" ] && echo PASS || echo "FAIL:${wrong_token_code}")"

        # 正确 Token 应返回 200（仅当订阅文件存在时）
        if [[ -f "${published}" ]]; then
            local correct_token_code
            correct_token_code=$(curl --silent --max-time 5 \
                --write-out '%{http_code}' --output /dev/null \
                --resolve "${domain}:80:127.0.0.1" \
                "http://${domain}/${token}/clash.yaml" 2>/dev/null || echo "000")
            _check "正确 Token URL 返回 200" \
                "$([ "${correct_token_code}" = "200" ] && echo PASS || echo "FAIL:${correct_token_code}")"
        fi
    else
        _check "Nginx 访问控制验证" "SKIP"
    fi
}

# =============================================================================
# NL 角色验证
# =============================================================================

verify_nl() {
    log_info ""
    log_info "--- Xray 代理服务 ---"

    _check "xray.service 处于 active 状态" "$(_svc_active xray.service)" \
        "排障: systemctl status xray; journalctl -u xray -n 30 --no-pager"

    local port_v4="${PROXY_PORT_V4:-20001}"
    _check "IPv4 代理端口 ${port_v4} 正在监听" "$(_port_listening "${port_v4}")"

    log_info ""
    log_info "--- NL Clash 源配置 ---"

    local nl_source="${CLASH_NL_SOURCE:-/var/www/clash/clash.yaml}"
    _check "NL Clash 源文件存在" "$([ -f "${nl_source}" ] && echo PASS || echo FAIL)"
    _check "NL Clash 源 YAML 语法合法" "$(_yaml_valid "${nl_source}")"

    log_info ""
    log_info "--- 镜像服务 ---"

    local submirror="${SUBMIRROR_USER:-submirror}"
    _check "submirror 用户存在" \
        "$(id -u "${submirror}" >/dev/null 2>&1 && echo PASS || echo FAIL)"

    local mirror_dir="${NL_MIRROR_DIR:-/var/www/sub}/${SUB_TOKEN}"
    _check "镜像目录存在: ${mirror_dir}" \
        "$([ -d "${mirror_dir}" ] && echo PASS || echo FAIL)"

    if [[ -d "${mirror_dir}" ]]; then
        local dir_perm
        dir_perm=$(stat -c "%a" "${mirror_dir}" 2>/dev/null || echo "unknown")
        _check "镜像目录权限 775" \
            "$([ "${dir_perm}" = "775" ] && echo PASS || echo "FAIL:${dir_perm}")"
    fi

    log_info ""
    log_info "--- Nginx ---"

    _check "nginx.service 处于 active 状态" "$(_svc_active nginx.service)"

    if command -v nginx >/dev/null 2>&1; then
        local nginx_test
        nginx_test=$(nginx -t 2>&1 >/dev/null && echo "PASS" || echo "FAIL")
        _check "Nginx 配置语法测试通过" "${nginx_test}"
    fi

    local domain="${NL_SUB_DOMAIN}"
    local token="${SUB_TOKEN}"
    local mirror_file="${mirror_dir}/clash.yaml"

    if systemctl is-active --quiet nginx.service 2>/dev/null; then
        # 无 Token 路径应返回 410
        local no_token_code
        no_token_code=$(curl --silent --max-time 5 \
            --write-out '%{http_code}' --output /dev/null \
            --resolve "${domain}:80:127.0.0.1" \
            "http://${domain}/clash.yaml" 2>/dev/null || echo "000")
        _check "/clash.yaml（无 Token）返回 410" \
            "$([ "${no_token_code}" = "410" ] && echo PASS || echo "FAIL:${no_token_code}")"

        # 镜像文件可能尚未同步（PENDING 状态）
        if [[ -f "${mirror_file}" ]]; then
            local mirror_code
            mirror_code=$(curl --silent --max-time 5 \
                --write-out '%{http_code}' --output /dev/null \
                --resolve "${domain}:80:127.0.0.1" \
                "http://${domain}/${token}/clash.yaml" 2>/dev/null || echo "000")
            _check "正确 Token 返回 200（镜像文件存在）" \
                "$([ "${mirror_code}" = "200" ] && echo PASS || echo "FAIL:${mirror_code}")"
        else
            _check "订阅镜像文件" "PENDING" \
                "等待美国端首次推送。命令: sudo /usr/local/sbin/push-clash-subscription-nl"
        fi
    fi

    log_info ""
    log_info "--- SSH 密钥 ---"

    local key_path="/home/${SUBMIRROR_USER:-submirror}/.ssh/subpush_key"
    if [[ -f "${key_path}" ]]; then
        _check "subpush 私钥权限 0600" "$(_file_perm "${key_path}" "600")"
        _check "subpush 公钥存在" "$([ -f "${key_path}.pub" ] && echo PASS || echo FAIL)"
    else
        _check "subpush 私钥" "PENDING" "尚未生成密钥（正常，若部署时跳过了密钥生成阶段）"
    fi
}

# =============================================================================
# 执行验证
# =============================================================================
case "${ROLE}" in
    us) verify_us ;;
    nl) verify_nl ;;
esac

# =============================================================================
# 输出汇总
# =============================================================================
log_info ""
log_info "================================================================"
log_info "  验证结果汇总 [${ROLE^^}]"
log_info "================================================================"
printf '\033[0;32m[PASS]\033[0m %d 项\n' "${PASS}"
printf '\033[0;31m[FAIL]\033[0m %d 项\n' "${FAIL}"
printf '\033[0;33m[SKIP]\033[0m %d 项\n' "${SKIP}"
printf '\033[0;34m[PENDING]\033[0m %d 项\n' "${PENDING}"
log_info "================================================================"

if [[ ${FAIL} -gt 0 ]]; then
    log_error "=== 存在 ${FAIL} 项验证失败，请参照上方排障命令逐项修复 ==="
    exit 1
fi

if [[ ${PENDING} -gt 0 ]]; then
    log_warn "=== 存在 ${PENDING} 项待处理事项，需要人工操作完成 ==="
fi

log_success "=== [${ROLE^^}] 所有必需验证均已通过 ==="
exit 0
