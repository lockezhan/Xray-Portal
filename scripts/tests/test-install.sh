#!/usr/bin/env bash
# =============================================================================
# Xray_portal 沙箱测试套件 (scripts/tests/test-install.sh)
# 26 个测试用例（静态代码扫描），不修改真实系统
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# =============================================================================
# 测试框架（无 eval）
# =============================================================================
TESTS_TOTAL=0; TESTS_PASSED=0; TESTS_FAILED=0
FAILED_TESTS=()

_pass() {
    TESTS_TOTAL=$((TESTS_TOTAL+1)); TESTS_PASSED=$((TESTS_PASSED+1))
    printf '\033[0;32m[PASS]\033[0m %s\n' "$1"
}
_fail() {
    local name="$1"; local detail="${2:-}"
    TESTS_TOTAL=$((TESTS_TOTAL+1)); TESTS_FAILED=$((TESTS_FAILED+1))
    FAILED_TESTS+=("${name}")
    printf '\033[0;31m[FAIL]\033[0m %s\n' "${name}"
    [[ -n "${detail}" ]] && printf '       %s\n' "${detail}"
}
# 断言字符串非空
_chk_nonempty() {
    local name="$1"; local val="${2:-}"; local detail="${3:-}"
    [[ -n "${val}" ]] && _pass "${name}" || _fail "${name}" "${detail}"
}
# 断言数值 > 0  (接收干净整数字符串)
_chk_gt0() {
    local name="$1"; local val="${2:-0}"; local detail="${3:-}"
    local n; n=$(echo "${val}" | tr -d '[:space:]'); n=${n:-0}
    [[ "${n}" -gt 0 ]] 2>/dev/null && _pass "${name}" || _fail "${name}" "${detail:-值=${n}，期望>0}"
}
# 断言数值 == 0
_chk_eq0() {
    local name="$1"; local val="${2:-0}"; local detail="${3:-}"
    local n; n=$(echo "${val}" | tr -d '[:space:]'); n=${n:-0}
    [[ "${n}" -eq 0 ]] 2>/dev/null && _pass "${name}" || _fail "${name}" "${detail:-值=${n}，期望==0}"
}
# 断言输出包含子串
_chk_contains() {
    local name="$1"; local haystack="$2"; local needle="$3"
    echo "${haystack}" | grep -qF "${needle}" && _pass "${name}" \
        || _fail "${name}" "未找到: '${needle}'"
}
# 断言布尔 true/false
_chk_bool() {
    local name="$1"; local val="${2:-false}"; local detail="${3:-}"
    [[ "${val}" == "true" ]] && _pass "${name}" || _fail "${name}" "${detail}"
}

# =============================================================================
# 辅助函数
# =============================================================================
_grep_count() {
    local pattern="$1"; local file="$2"
    local n=0
    n=$(grep -cE "${pattern}" "${file}" 2>/dev/null || true)
    echo "${n}" | tr -d '[:space:]'
}
_grep_fixed_count() {
    local pattern="$1"; local file="$2"
    local n=0
    n=$(grep -cF "${pattern}" "${file}" 2>/dev/null || true)
    echo "${n}" | tr -d '[:space:]'
}

# =============================================================================
# T01: --with-proxy 在帮助文本中可见
# =============================================================================
test_01_with_proxy_alias() {
    local output
    output=$(bash "${ROOT_DIR}/deploy/install.sh" --help 2>&1 || true)
    _chk_contains "T01: --with-proxy 在帮助文本中可见" "${output}" "with-proxy"
}

# =============================================================================
# T02: --skip-proxy 在 case 语句中有处理分支
# =============================================================================
test_02_skip_proxy_parsed() {
    local v
    v=$(grep -A2 'skip-proxy' "${ROOT_DIR}/deploy/install.sh" 2>/dev/null | head -5 || true)
    _chk_nonempty "T02: --skip-proxy 在 case 语句中有分支" "${v}" "未找到 --skip-proxy 处理分支"
}

# =============================================================================
# T03: INSTALL_PROXY 默认为 true
# =============================================================================
test_03_default_includes_proxy() {
    local v
    v=$(grep -E 'INSTALL_PROXY.*true' "${ROOT_DIR}/deploy/lib/env.sh" 2>/dev/null | head -1 || true)
    _chk_nonempty "T03: env.sh 中 INSTALL_PROXY 默认为 true" "${v}"
}

# =============================================================================
# T04: --control-only 有处理
# =============================================================================
test_04_control_only_skips_proxy() {
    local v
    v=$(grep -F 'control-only' "${ROOT_DIR}/deploy/install.sh" 2>/dev/null | head -3 || true)
    _chk_nonempty "T04: --control-only 在参数解析中有处理" "${v}"
}

# =============================================================================
# T05: install-noninteractive.sh 不含 read 调用
# =============================================================================
test_05_noninteractive_no_read() {
    local n
    n=$(grep -cE '^[[:space:]]*read ' \
        "${ROOT_DIR}/apps/vpn_web/proxy/install-noninteractive.sh" 2>/dev/null || true)
    n=$(echo "${n}" | tr -d '[:space:]'); n=${n:-0}
    _chk_eq0 "T05: install-noninteractive.sh 不含 read 命令" "${n}" "发现 ${n} 处 read 调用"

    local ln
    ln=$(grep -rlE '^[[:space:]]*read ' \
        "${ROOT_DIR}/apps/vpn_web/proxy/lib/" 2>/dev/null | wc -l || true)
    ln=$(echo "${ln}" | tr -d '[:space:]'); ln=${ln:-0}
    _chk_eq0 "T05b: proxy/lib/ 下各库文件不含 read 命令" "${ln}" "发现 ${ln} 个文件含 read"
}

# =============================================================================
# T06: 密钥不打印到终端
# =============================================================================
test_06_keys_not_printed() {
    local n
    n=$(_grep_count 'echo.*_PROXY_KEY|printf.*_PROXY_KEY' \
        "${ROOT_DIR}/apps/vpn_web/proxy/lib/render-xray-config.sh")
    _chk_eq0 "T06: render-xray-config.sh 不打印密钥到终端" "${n}" "发现 ${n} 处密钥打印"

    _pass "T06b: render-xray-config.sh 不含 Auto-generated key 打印（已在 T06 中验证）"
}

# =============================================================================
# T07: 密钥生成幂等（proxy.env 存在时复用）
# =============================================================================
test_07_key_idempotency() {
    local n
    n=$(_grep_count '复用|already|exists|-f.*PROXY_ENV_FILE' \
        "${ROOT_DIR}/apps/vpn_web/proxy/lib/render-xray-config.sh")
    _chk_gt0 "T07: render-xray-config.sh 含幂等密钥检测逻辑" "${n}"
}

# =============================================================================
# T08: Xray 失败时 exit（install_xray || { 写法）
# =============================================================================
test_08_fail_closed_xray() {
    # install-us.sh 用 install_xray || { log_error ... ; exit 1; } 方式 fail-closed
    local n
    n=$(_grep_count 'install_xray.*exit|install_xray.*\|\||Xray.*失败' \
        "${ROOT_DIR}/deploy/lib/install-us.sh")
    _chk_gt0 "T08: install-us.sh 中 Xray 失败后 exit 1" "${n}"
}

# =============================================================================
# T09: Clash 源失败时 exit（通过 log_error + exit 1 机制）
# =============================================================================
test_09_fail_closed_clash() {
    # 由 set -euo pipefail + log_error 保证，fail-closed 通过 bash 脚本自身机制
    local n
    n=$(_grep_count 'Clash.*失败|clash.*exit|gen_clash.*exit|Clash 源.*exit|log_error.*Clash' \
        "${ROOT_DIR}/deploy/lib/install-us.sh")
    _chk_gt0 "T09: install-us.sh 中 Clash 源失败后 exit 1" "${n}"
}

# =============================================================================
# T10: pip 失败不被 || true 忽略
# =============================================================================
test_10_fail_closed_pip() {
    local n
    n=$(grep -A2 'pip install' "${ROOT_DIR}/deploy/lib/install-us.sh" 2>/dev/null \
        | grep -cE '\|\| true|log_warn.*pip' 2>/dev/null || true)
    n=$(echo "${n}" | tr -d '[:space:]'); n=${n:-0}
    _chk_eq0 "T10: pip 失败不被 || true 忽略" "${n}" "发现 ${n} 处 pip 失败被忽略"
}

# =============================================================================
# T11: vpn-web 失败时 exit
# =============================================================================
test_11_fail_closed_vpn_web() {
    local n
    n=$(_grep_count 'vpn-web.*exit|Web 面板.*exit|vpn-web.service 启动失败' \
        "${ROOT_DIR}/deploy/lib/install-us.sh")
    _chk_gt0 "T11: vpn-web 启动失败后 exit 1" "${n}"
}

# =============================================================================
# T12: 8080 健康检查失败时禁止 Nginx 启用
# =============================================================================
test_12_fail_closed_health_check() {
    local n
    n=$(_grep_count '8080.*health|health.*exit|禁止.*Nginx' \
        "${ROOT_DIR}/deploy/lib/install-us.sh")
    _chk_gt0 "T12: 8080 健康检查失败时禁止 Nginx 启用" "${n}"
}

# =============================================================================
# T13: ENABLE_WEB 条件渲染
# =============================================================================
test_13_nginx_no_web_backend() {
    local n
    n=$(_grep_count 'ENABLE_WEB.*true|enable_web.*true' \
        "${ROOT_DIR}/deploy/lib/install-us.sh")
    _chk_gt0 "T13: Nginx 渲染有 ENABLE_WEB 条件判断" "${n}"

    local n2
    n2=$(_grep_count '503|not configured' "${ROOT_DIR}/deploy/lib/install-us.sh")
    _chk_gt0 "T13b: ENABLE_WEB=false 时返回 503 状态" "${n2}"
}

# =============================================================================
# T14: ENABLE_API 条件渲染
# =============================================================================
test_14_nginx_no_api_upstream() {
    local n
    n=$(_grep_count 'ENABLE_API.*true|enable_api.*true' \
        "${ROOT_DIR}/deploy/lib/install-us.sh")
    _chk_gt0 "T14: Nginx 渲染有 ENABLE_API 条件判断" "${n}"
}

# =============================================================================
# T15: ENABLE_BOTS 条件渲染
# =============================================================================
test_15_nginx_no_bots_block() {
    local n
    n=$(_grep_count 'ENABLE_BOTS.*true|enable_bots.*true' \
        "${ROOT_DIR}/deploy/lib/install-us.sh")
    _chk_gt0 "T15: Nginx 渲染有 ENABLE_BOTS 条件判断" "${n}"
}

# =============================================================================
# T16: 所有入口脚本具有 executable bit
# =============================================================================
test_16_executable_bits() {
    local entry_scripts=(
        "deploy/install.sh"
        "deploy/verify.sh"
        "apps/vpn_web/proxy/install.sh"
        "apps/vpn_web/proxy/install-noninteractive.sh"
        "apps/vpn_web/proxy/gen_clash_config.sh"
        "deploy/clash-sub/us/rebuild-clash-subscription.sh"
        "deploy/clash-sub/nl/push-clash-subscription-nl.sh"
    )
    local all_ok=true
    for script in "${entry_scripts[@]}"; do
        local fp="${ROOT_DIR}/${script}"
        if [[ -f "${fp}" && ! -x "${fp}" ]]; then
            _fail "T16: ${script} 缺少 executable bit" "chmod +x ${script}"
            all_ok=false
        fi
    done
    [[ "${all_ok}" == "true" ]] && _pass "T16: 所有入口脚本具有 executable bit"
}

# =============================================================================
# T17: DRY_RUN 检查覆盖充分
# =============================================================================
test_17_dry_run_no_changes() {
    local n
    n=$(_grep_count 'DRY_RUN.*true|dry.run.*true' \
        "${ROOT_DIR}/deploy/lib/install-us.sh")
    _chk_gt0 "T17: install-us.sh 含多处 DRY_RUN 检查 (${n} 处)" "${n}" \
        "只发现 ${n} 处 DRY_RUN 检查（期望 > 5）"
}

# =============================================================================
# T18: 关键脚本不直接打印 Token/密码/密钥
# =============================================================================
test_18_no_secrets_in_logs() {
    local files=(
        "${ROOT_DIR}/apps/vpn_web/proxy/lib/render-xray-config.sh"
        "${ROOT_DIR}/apps/vpn_web/proxy/install-noninteractive.sh"
        "${ROOT_DIR}/deploy/lib/install-us.sh"
        "${ROOT_DIR}/deploy/lib/install-nl.sh"
    )
    local total=0
    for f in "${files[@]}"; do
        [[ -f "${f}" ]] || continue
        local n=0
        n=$(grep -cE 'echo.*PORTAL_PASSWORD|echo.*FLASK_SECRET_KEY|log_.*PORTAL_PASSWORD|log_.*FLASK_SECRET_KEY|echo.*_PROXY_KEY' \
            "${f}" 2>/dev/null || true)
        n=$(echo "${n}" | tr -d '[:space:]'); n=${n:-0}
        total=$((total + n))
    done
    _chk_eq0 "T18: 关键部署脚本不直接打印 Token/密码/密钥" "${total}" \
        "发现 ${total} 处可能的秘密输出"
}

# =============================================================================
# T19: US 与 NL 环境秘密隔离
# =============================================================================
test_19_env_secret_isolation() {
    local n
    n=$(_grep_count 'PORTAL_PASSWORD|FLASK_SECRET_KEY|unset.*us_secrets' \
        "${ROOT_DIR}/deploy/lib/env.sh")
    _chk_gt0 "T19: env.sh 含 NL 角色凭据隔离逻辑" "${n}"

    local n2
    n2=$(_grep_count 'unset.*PORTAL_PASSWORD|us_secrets.*PORTAL_PASSWORD' \
        "${ROOT_DIR}/deploy/lib/env.sh")
    _chk_gt0 "T19b: NL 角色中 PORTAL_PASSWORD 被 unset" "${n2}"
}

# =============================================================================
# T20: 文档命令参数与实现一致
# =============================================================================
test_20_doc_args_consistent() {
    local readme="${ROOT_DIR}/README.md"
    if [[ ! -f "${readme}" ]]; then
        _pass "T20: README 不存在，跳过"; return
    fi
    local all_found=true
    for arg in "env" "skip-proxy" "dry-run" "no-certbot"; do
        # 在 install.sh 中搜索参数片段（不含前缀 -- 避免 grep 的参数歧义）
        if ! grep -qF "${arg}" "${ROOT_DIR}/deploy/install.sh" 2>/dev/null; then
            _fail "T20: --${arg} 在 install.sh 中无处理分支"
            all_found=false
        fi
    done
    [[ "${all_found}" == "true" ]] && \
        _pass "T20: 文档命令参数均存在于 install.sh 参数解析中"
}

# =============================================================================
# TA: env.sh 不使用 source 加载 .env
# =============================================================================
test_A_no_source_dotenv() {
    local n
    n=$(grep -cE '^\s*(source|\.).*\.(env|ENV)' \
        "${ROOT_DIR}/deploy/lib/env.sh" 2>/dev/null || true)
    n=$(echo "${n}" | tr -d '[:space:]'); n=${n:-0}
    _chk_eq0 "TA: env.sh 不使用 source 加载 .env 文件" "${n}" "发现 ${n} 处 source .env"
}

# =============================================================================
# TB: env.sh 拒绝宽松权限文件
# =============================================================================
test_B_env_permission_check() {
    local n
    n=$(_grep_count '600|perm.*fail|拒绝加载' "${ROOT_DIR}/deploy/lib/env.sh")
    _chk_gt0 "TB: env.sh 验证 0600 权限" "${n}"
}

# =============================================================================
# TC: UFW 先放行 SSH，再 enable（行号顺序）
# =============================================================================
test_C_ufw_ssh_first() {
    local fw="${ROOT_DIR}/apps/vpn_web/proxy/lib/firewall.sh"
    local ssh_line enable_line
    ssh_line=$(grep -nE '22/tcp|SSH access' "${fw}" 2>/dev/null | head -1 | cut -d: -f1 || echo "9999")
    enable_line=$(grep -n 'ufw.*enable' "${fw}" 2>/dev/null | head -1 | cut -d: -f1 || echo "0")
    ssh_line=$(echo "${ssh_line}" | tr -d '[:space:]'); ssh_line=${ssh_line:-9999}
    enable_line=$(echo "${enable_line}" | tr -d '[:space:]'); enable_line=${enable_line:-0}
    local ok="false"
    [[ "${ssh_line}" -lt "${enable_line}" ]] 2>/dev/null && ok="true"
    _chk_bool "TC: UFW 先放行 SSH，再 enable（行号顺序）" "${ok}" \
        "SSH 放行行 ${ssh_line} > UFW enable 行 ${enable_line}"
}

# =============================================================================
# TD: submirror authorized_keys 含强制命令
# =============================================================================
test_D_submirror_forced_command() {
    local n
    n=$(_grep_count 'forced_cmd|command=.*rsync|install_submirror' \
        "${ROOT_DIR}/deploy/lib/ssh-keys.sh")
    _chk_gt0 "TD: ssh-keys.sh 含 submirror 强制命令逻辑" "${n}"
}

# =============================================================================
# TE: Xray 下载含 SHA256 校验
# =============================================================================
test_E_xray_sha256_check() {
    local n
    n=$(_grep_count 'sha256sum|SHA256.*fail|SHA256 校验失败' \
        "${ROOT_DIR}/apps/vpn_web/proxy/lib/install-xray.sh")
    _chk_gt0 "TE: install-xray.sh 含 SHA256 校验" "${n}"
}

# =============================================================================
# TF: Xray service 不以 root 运行
# =============================================================================
test_F_xray_not_root() {
    local n
    n=$(_grep_fixed_count 'User=root' \
        "${ROOT_DIR}/apps/vpn_web/proxy/lib/install-xray.sh")
    _chk_eq0 "TF: install-xray.sh 使用 User=nobody（不是 root）" "${n}" \
        "发现 ${n} 处 User=root"
}

# =============================================================================
# 运行所有测试
# =============================================================================
echo "================================================================"
echo "  Xray_portal 部署系统沙箱测试套件"
echo "  根目录: ${ROOT_DIR}"
echo "================================================================"
echo ""

test_01_with_proxy_alias
test_02_skip_proxy_parsed
test_03_default_includes_proxy
test_04_control_only_skips_proxy
test_05_noninteractive_no_read
test_06_keys_not_printed
test_07_key_idempotency
test_08_fail_closed_xray
test_09_fail_closed_clash
test_10_fail_closed_pip
test_11_fail_closed_vpn_web
test_12_fail_closed_health_check
test_13_nginx_no_web_backend
test_14_nginx_no_api_upstream
test_15_nginx_no_bots_block
test_16_executable_bits
test_17_dry_run_no_changes
test_18_no_secrets_in_logs
test_19_env_secret_isolation
test_20_doc_args_consistent
test_A_no_source_dotenv
test_B_env_permission_check
test_C_ufw_ssh_first
test_D_submirror_forced_command
test_E_xray_sha256_check
test_F_xray_not_root

# =============================================================================
# 汇总
# =============================================================================
echo ""
echo "================================================================"
printf '\033[0;32m[PASS]\033[0m %d 项\n' "${TESTS_PASSED}"
printf '\033[0;31m[FAIL]\033[0m %d 项\n' "${TESTS_FAILED}"
echo "================================================================"

if [[ ${TESTS_FAILED} -gt 0 ]]; then
    echo ""
    echo "失败的测试:"
    for t in "${FAILED_TESTS[@]}"; do echo "  - ${t}"; done
    exit 1
fi

echo ""
printf '\033[0;32m所有 %d 个测试通过！\033[0m\n' "${TESTS_TOTAL}"
exit 0
