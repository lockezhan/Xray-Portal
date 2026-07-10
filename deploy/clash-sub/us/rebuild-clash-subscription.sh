#!/usr/bin/env bash
# =============================================================================
# rebuild-clash-subscription — 美国主构建脚本
# =============================================================================
set -euo pipefail

# 加载配置
CONFIG_ENV="/opt/clash-sub/scripts/config.env"
if [[ ! -f "$CONFIG_ENV" ]]; then
  echo "[FATAL] 配置文件不存在: $CONFIG_ENV" >&2
  exit 1
fi
# shellcheck disable=SC1090
source "$CONFIG_ENV"

# 日志函数
mkdir -p "$(dirname "$LOG_FILE")"
log() {
  local level="$1"; shift
  local msg="$*"
  local ts
  ts=$(date "+%Y-%m-%d %H:%M:%S")
  echo "[$ts] [$level] $msg" | tee -a "$LOG_FILE"
}

log INFO "=========================================="
log INFO "开始重建 Clash 订阅"
log INFO "=========================================="

# =============================================================================
# 步骤 1：检查依赖
# =============================================================================
PYTHON3=$(which python3 2>/dev/null || true)
if [[ -z "$PYTHON3" ]]; then
  log ERROR "python3 未安装"
  exit 1
fi

if ! "$PYTHON3" -c "import yaml" 2>/dev/null; then
  log INFO "安装 PyYAML..."
  pip3 install pyyaml -q
fi

MIHOMO_BIN=""
for bin_name in mihomo clash-meta clash; do
  bin_path=$(which "$bin_name" 2>/dev/null || find /usr/local/bin /usr/bin /opt -name "$bin_name" 2>/dev/null | head -1 || true)
  if [[ -n "$bin_path" && -x "$bin_path" ]]; then
    MIHOMO_BIN="$bin_path"
    log INFO "找到 mihomo 可执行文件: $MIHOMO_BIN"
    break
  fi
done
if [[ -z "$MIHOMO_BIN" ]]; then
  log WARN "未找到 mihomo 二进制，跳过 mihomo 语法验证"
fi

# =============================================================================
# 步骤 2：获取美国原始配置
# =============================================================================
log INFO "步骤2: 读取美国原始配置: $US_SOURCE"
if [[ ! -f "$US_SOURCE" ]]; then
  log ERROR "美国原始配置不存在: $US_SOURCE"
  exit 2
fi
cp "$US_SOURCE" /opt/clash-sub/sources/us-full.yaml
log INFO "美国配置已快照: /opt/clash-sub/sources/us-full.yaml"

# =============================================================================
# 步骤 3：检查并更新荷兰原始配置
# =============================================================================
log INFO "步骤3: 检查并更新荷兰原始配置..."
if [[ -f "$INCOMING_DIR/clash.yaml" ]]; then
  log INFO "发现新上传的荷兰配置，正在移动到 $NL_SOURCE"
  mv "$INCOMING_DIR/clash.yaml" "$NL_SOURCE"
fi

NL_SOURCE_PARAM="$NL_SOURCE"
if [[ ! -f "$NL_SOURCE" ]]; then
  log WARN "荷兰配置不存在，且 incoming 目录中无新文件。将自动采用单机模式降级合并！"
  NL_SOURCE_PARAM="/tmp/empty_nl.yaml"
  echo "proxies: []" > "$NL_SOURCE_PARAM"
fi

# =============================================================================
# 步骤 4-6：合并
# =============================================================================
log INFO "步骤4-6: 运行节点提取与合并脚本..."
MERGE_SCRIPT="/opt/clash-sub/scripts/extract_merge.py"
GENERATED_TMP="/opt/clash-sub/generated/clash.yaml.building"

if ! "$PYTHON3" "$MERGE_SCRIPT" \
    /opt/clash-sub/sources/us-full.yaml \
    "$NL_SOURCE_PARAM" \
    "$GENERATED_TMP" 2>&1 | tee -a "$LOG_FILE"; then
  log ERROR "节点提取合并失败"
  exit 4
fi

log INFO "节点合并完成，临时文件: $GENERATED_TMP"

# =============================================================================
# 步骤 7：YAML 语法检查
# =============================================================================
log INFO "步骤7: YAML 语法验证..."
if ! "$PYTHON3" - "$GENERATED_TMP" << 'PYEOF' 2>&1 | tee -a "$LOG_FILE"
import yaml
import sys
try:
    filepath = sys.argv[1]
    with open(filepath, "r", encoding="utf-8") as f:
        data = yaml.safe_load(f)
    assert 'proxies' in data, 'missing proxies'
    assert 'proxy-groups' in data, 'missing proxy-groups'
    assert 'rules' in data, 'missing rules'
    assert len(data['proxies']) > 0, 'proxies is empty'
    print("YAML 有效: {} 个节点".format(len(data['proxies'])))
except Exception as e:
    print("验证失败: {}".format(e), file=sys.stderr)
    sys.exit(1)
PYEOF
then
  log ERROR "YAML 语法验证失败，中止"
  rm -f "$GENERATED_TMP"
  exit 5
fi

# =============================================================================
# 步骤 8：Mihomo 配置验证
# =============================================================================
if [[ -n "$MIHOMO_BIN" ]]; then
  log INFO "步骤8: 使用 mihomo 验证配置..."
  MIHOMO_TEST_DIR=$(mktemp -d)
  cp "$GENERATED_TMP" "$MIHOMO_TEST_DIR/config.yaml"
  if ! "$MIHOMO_BIN" -t -d "$MIHOMO_TEST_DIR" 2>&1 | tee -a "$LOG_FILE"; then
    log ERROR "Mihomo 配置检查失败，中止发布"
    rm -rf "$MIHOMO_TEST_DIR"
    rm -f "$GENERATED_TMP"
    exit 6
  fi
  rm -rf "$MIHOMO_TEST_DIR"
  log INFO "Mihomo 验证通过"
fi

mv "$GENERATED_TMP" "$GENERATED"

# =============================================================================
# 步骤 9：备份旧版本
# =============================================================================
PUBLISHED_FILE="$PUBLISHED_DIR/clash.yaml"
if [[ -f "$PUBLISHED_FILE" ]]; then
  BACKUP_NAME="clash.yaml.$(date "+%Y%m%d-%H%M%S")"
  cp "$PUBLISHED_FILE" "$BACKUP_DIR/$BACKUP_NAME"
  log INFO "步骤9: 旧版本已备份: $BACKUP_DIR/$BACKUP_NAME"

  BACKUP_COUNT=$(ls -1 "$BACKUP_DIR"/clash.yaml.* 2>/dev/null | wc -l)
  if [[ "$BACKUP_COUNT" -gt 10 ]]; then
    ls -1t "$BACKUP_DIR"/clash.yaml.* | tail -n +11 | xargs -r rm -f
    log INFO "清理旧备份，保留最近 10 个"
  fi
fi

# =============================================================================
# 步骤 10：原子发布
# =============================================================================
log INFO "步骤10: 原子替换发布..."
mkdir -p "$PUBLISHED_DIR"
cp "$GENERATED" "$PUBLISHED_DIR/clash.yaml.new"
mv "$PUBLISHED_DIR/clash.yaml.new" "$PUBLISHED_FILE"
chmod 644 "$PUBLISHED_FILE"
log INFO "新订阅已发布: $PUBLISHED_FILE"

# =============================================================================
# 步骤 11：同步到荷兰副站
# =============================================================================
NL_MIRROR_KEY="/opt/clash-sub/scripts/submirror_key"
NL_MIRROR_PATH="/var/www/sub/${SUB_TOKEN}/clash.yaml"

if [[ -f "$NL_MIRROR_KEY" ]]; then
  log INFO "步骤11: 同步订阅到荷兰副站..."
  if rsync -az --timeout=30 \
    -e "ssh -i $NL_MIRROR_KEY -o StrictHostKeyChecking=no -o ConnectTimeout=10" \
    "$PUBLISHED_FILE" \
    "${NL_MIRROR_USER}@${NL_IP}:${NL_MIRROR_PATH}" 2>&1 | tee -a "$LOG_FILE"; then
    log INFO "荷兰镜像同步成功"
  else
    log WARN "荷兰镜像同步失败（不影响美国主订阅）"
  fi
else
  log WARN "步骤11: 荷兰同步密钥不存在，跳过同步"
fi

log INFO "=========================================="
log INFO "构建完成！"
log INFO "=========================================="
exit 0
