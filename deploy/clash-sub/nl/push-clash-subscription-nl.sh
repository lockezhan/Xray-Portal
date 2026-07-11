#!/usr/bin/env bash
# =============================================================================
# push-clash-subscription-nl — 荷兰节点配置上传与触发重建脚本
# 流程：读取荷兰原始配置 → 验证有效性 → 上传到美国服务器 → 触发美国服务器构建
# =============================================================================
set -euo pipefail

# 加载配置
CONFIG_ENV="/opt/clash-sub-mirror/config.env"
if [[ ! -f "$CONFIG_ENV" ]]; then
  echo "[FATAL] 配置文件不存在: $CONFIG_ENV" >&2
  exit 1
fi
# shellcheck disable=SC1090
US_IP=""

while IFS='=' read -r key value || [[ -n "${key}" ]]; do
    value="${value%$'\r'}"

    case "${key}" in
        US_IP)
            US_IP="${value}"
            ;;
        ""|\#*)
            ;;
        *)
            # 忽略所有非白名单键。
            ;;
    esac
done < "${CONFIG_ENV}"

if [[ -z "${US_IP}" ]]; then
    echo "[FATAL] config.env 中缺少 US_IP" >&2
    exit 1
fi

# 只允许普通主机名、IPv4 或 IPv6 字符。
if [[ ! "${US_IP}" =~ ^[A-Za-z0-9._:-]+$ ]]; then
    echo "[FATAL] US_IP 格式不合法" >&2
    exit 1
fi

LOG_FILE="/opt/clash-sub-mirror/logs/push.log"
mkdir -p "$(dirname "$LOG_FILE")"

log() {
  local level="$1"; shift
  local ts; ts=$(date "+%Y-%m-%d %H:%M:%S")
  echo "[$ts] [$level] $*" | tee -a "$LOG_FILE"
}

log INFO "=========================================="
log INFO "开始推送荷兰原始 Clash 配置到美国"
log INFO "=========================================="

NL_CLASH_SOURCE="/var/www/clash/clash.yaml"
PRIVATE_KEY="/opt/clash-sub-mirror/subpush_key"

if [[ ! -f "$NL_CLASH_SOURCE" ]]; then
  log ERROR "未找到荷兰原始 Clash 配置: $NL_CLASH_SOURCE"
  exit 1
fi

if [[ ! -f "$PRIVATE_KEY" ]]; then
  log ERROR "未找到推送私钥: $PRIVATE_KEY"
  exit 1
fi

# 1. 验证 YAML 和 proxies 字段
python3 -c "
import yaml, sys
try:
    with open('$NL_CLASH_SOURCE', 'r', encoding='utf-8') as f:
        data = yaml.safe_load(f)
    assert isinstance(data, dict), 'YAML root must be dict'
    assert 'proxies' in data, 'missing proxies'
    assert isinstance(data['proxies'], list), 'proxies must be a list'
    assert len(data['proxies']) > 0, 'proxies list is empty'
    valid_proxies = [p for p in data['proxies'] if isinstance(p, dict) and p.get('type','').lower() not in ('direct','reject','dns') and 'server' in p and 'port' in p]
    assert len(valid_proxies) > 0, 'no remote proxies found'
    print('YAML有效性验证通过，含有 {} 个远程节点'.format(len(valid_proxies)))
except Exception as e:
    print('YAML有效性验证失败: {}'.format(e), file=sys.stderr)
    sys.exit(1)
" 2>&1 | tee -a "$LOG_FILE" || {
  log ERROR "荷兰配置 YAML 验证未通过，中止推送"
  exit 2
}

# 2. 通过标准输入传输配置并触发美国端重新构建
log INFO "正在通过安全标准输入协议传输配置并唤醒美国端重建..."
if ! cat "$NL_CLASH_SOURCE" | ssh -i "$PRIVATE_KEY" \
  -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
  "subpush@${US_IP}" upload-nl 2>&1 | tee -a "$LOG_FILE"; then
  log ERROR "配置传输与重建触发失败"
  exit 3
fi

log INFO "=========================================="
log INFO "荷兰配置推送且触发重建成功！"
log INFO "=========================================="
