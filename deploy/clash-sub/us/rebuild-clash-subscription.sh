#!/usr/bin/env bash
# =============================================================================
# rebuild-clash-subscription — 美国端主订阅重建与事务发布脚本 (高安全回滚版)
# =============================================================================
set -euo pipefail

# 1. 强制进程锁 (flock 串行化，防止并发冲突)
LOCKFILE="/opt/clash-sub/rebuild.lock"
touch "$LOCKFILE"
exec 9>>"$LOCKFILE"
if ! flock -n 9; then
  echo "[WARN] Another rebuild process is running. Waiting for lock..." >&2
  flock -x 9
fi

# 加载配置变量
CONFIG_ENV="/opt/clash-sub/scripts/config.env"
if [[ ! -f "$CONFIG_ENV" ]]; then
  echo "[FATAL] Configuration file not found: $CONFIG_ENV" >&2
  exit 1
fi
# shellcheck disable=SC1090
source "$CONFIG_ENV"

# 日志输出目录创建
mkdir -p "$(dirname "$LOG_FILE")"
log() {
  local level="$1"; shift
  local msg="$*"
  local ts; ts=$(date "+%Y-%m-%d %H:%M:%S")
  echo "[$ts] [$level] $msg" | tee -a "$LOG_FILE"
}

log INFO "=========================================="
log INFO "开始订阅重建流程"
log INFO "=========================================="

# 2. 声明回滚控制变量
NL_SNAP_BACKED=0
US_SNAP_BACKED=0
PUB_BACKED=0
STATUS_OK=0

# 回滚与清理逻辑函数 (必须在 flock 锁持有期间退出前被调用)
cleanup_on_error() {
  local exit_code=$?

  # 清理临时零碎文件
  rm -f "/tmp/empty_us.yaml" "/tmp/empty_nl.yaml"
  rm -f "${CANDIDATE_OUT:-}"

  if [[ "$STATUS_OK" -ne 1 ]]; then
    log WARN "检测到事务中途故障退出 (Code: $exit_code)，自动恢复原快照和发布哈希..."

    # 还原荷兰快照
    if [[ "$NL_SNAP_BACKED" -eq 1 && -f "${NL_SNAPSHOT}.bak" ]]; then
      mv -f "${NL_SNAPSHOT}.bak" "$NL_SNAPSHOT"
      log INFO "已回退恢复旧荷兰快照"
    fi

    # 还原美国快照
    if [[ "$US_SNAP_BACKED" -eq 1 && -f "${US_SNAPSHOT}.bak" ]]; then
      mv -f "${US_SNAPSHOT}.bak" "$US_SNAPSHOT"
      log INFO "已回退恢复旧美国快照"
    fi

    # 还原发布文件
    if [[ "$PUB_BACKED" -eq 1 && -f "${PUBLISHED_FILE}.bak" ]]; then
      mv -f "${PUBLISHED_FILE}.bak" "$PUBLISHED_FILE"
      log INFO "已回退恢复旧订阅文件"
    fi

    # 既然失败了，必须把 ready 文件清除，防止其再次被错误提升
    rm -f "${NL_READY:-}"
  else
    log INFO "事务发布一切正常，清理备份..."
    rm -f "${NL_SNAPSHOT}.bak" "${US_SNAPSHOT}.bak" "${PUBLISHED_FILE}.bak"
  fi
}

# 注册 trap
trap cleanup_on_error EXIT ERR

# 依赖检验
PYTHON3=$(which python3 2>/dev/null || true)
if [[ -z "$PYTHON3" ]]; then
  log ERROR "python3 未安装"
  exit 1
fi

# 只有当 MIHOMO_BIN 未定义或为空时，才自动检测
if [[ -z "${MIHOMO_BIN:-}" ]]; then
  for bin_name in mihomo clash-meta clash; do
    bin_path=$(which "$bin_name" 2>/dev/null || find /usr/local/bin /usr/bin /opt -name "$bin_name" 2>/dev/null | head -1 || true)
    if [[ -n "$bin_path" && -x "$bin_path" ]]; then
      MIHOMO_BIN="$bin_path"
      log INFO "找到 mihomo 可执行文件: $MIHOMO_BIN"
      break
    fi
  done
fi

# 物理快照路径设定
US_REAL="$US_SOURCE"
US_SNAPSHOT="/opt/clash-sub/sources/us-full.yaml"
US_CANDIDATE=""

NL_READY="$INCOMING_DIR/nl-full.yaml.ready"
NL_SNAPSHOT="/opt/clash-sub/sources/nl-full.yaml"
NL_CANDIDATE=""

# 确定源文件
if [[ -f "$US_REAL" ]]; then
  log INFO "采用实时美国配置作为构建候选: $US_REAL"
  US_CANDIDATE="$US_REAL"
elif [[ -f "$US_SNAPSHOT" ]]; then
  log INFO "美国实时配置不存在，将采用历史快照作为构建候选: $US_SNAPSHOT"
  US_CANDIDATE="$US_SNAPSHOT"
else
  log WARN "无任何有效美国配置源（既无实时配置又无历史快照）"
fi

if [[ -f "$NL_READY" ]]; then
  log INFO "发现新上传的就绪荷兰配置，作为构建候选: $NL_READY"
  NL_CANDIDATE="$NL_READY"
elif [[ -f "$NL_SNAPSHOT" ]]; then
  log INFO "无新上传就绪荷兰配置，将采用历史快照作为构建候选: $NL_SNAPSHOT"
  NL_CANDIDATE="$NL_SNAPSHOT"
else
  log WARN "无任何有效荷兰配置源（既无新上传文件又无历史快照）"
fi

# 双缺阻断
if [[ -z "$US_CANDIDATE" && -z "$NL_CANDIDATE" ]]; then
  log ERROR "美国与荷兰双端均无可用的有效配置源，中止构建。"
  rm -f "$NL_READY"
  exit 2
fi

# 传参规整
US_MERGE_INPUT="$US_CANDIDATE"
if [[ -z "$US_MERGE_INPUT" ]]; then
  US_MERGE_INPUT="/tmp/empty_us.yaml"
  echo "proxies: []" > "$US_MERGE_INPUT"
fi

NL_MERGE_INPUT="$NL_CANDIDATE"
if [[ -z "$NL_MERGE_INPUT" ]]; then
  NL_MERGE_INPUT="/tmp/empty_nl.yaml"
  echo "proxies: []" > "$NL_MERGE_INPUT"
fi

# 在 generated 目录中合成候选配置文件
MERGE_SCRIPT="/opt/clash-sub/scripts/extract_merge.py"
CANDIDATE_OUT="/opt/clash-sub/generated/clash.yaml.candidate"
mkdir -p "$(dirname "$CANDIDATE_OUT")"

log INFO "运行合并器逻辑，输入 US: ${US_MERGE_INPUT} | NL: ${NL_MERGE_INPUT}"
if ! "$PYTHON3" "$MERGE_SCRIPT" "$US_MERGE_INPUT" "$NL_MERGE_INPUT" "$CANDIDATE_OUT" 2>&1 | tee -a "$LOG_FILE"; then
  log ERROR "Python 逻辑校验失败！中止发布。"
  rm -f "$NL_READY"
  exit 3
fi

# YAML 语法物理校验
log INFO "校验合并后的候选 YAML 语法有效性..."
python3 -c "
import yaml, sys
try:
    with open('$CANDIDATE_OUT', 'r', encoding='utf-8') as f:
        yaml.safe_load(f)
    print('YAML 基本语义结构验证通过')
except Exception as e:
    print('YAML 语法错误: {}'.format(e), file=sys.stderr)
    sys.exit(1)
" 2>&1 | tee -a "$LOG_FILE" || {
  log ERROR "合成配置语法无效！中止发布。"
  rm -f "$NL_READY"
  exit 4
}

# 真实内核测试 (mihomo -t)
if [[ -n "${MIHOMO_BIN:-}" ]]; then
  log INFO "使用 Mihomo 真实内核测试候选配置文件..."
  MIHOMO_TEST_DIR=$(mktemp -d)
  cp "$CANDIDATE_OUT" "$MIHOMO_TEST_DIR/config.yaml"
  if ! "$MIHOMO_BIN" -t -d "$MIHOMO_TEST_DIR" 2>&1 | tee -a "$LOG_FILE"; then
    log ERROR "Mihomo 内核校验失败，拒绝发布！"
    rm -rf "$MIHOMO_TEST_DIR"
    rm -f "$NL_READY"
    exit 5
  fi
  rm -rf "$MIHOMO_TEST_DIR"
  log INFO "Mihomo 测试通过！"
fi

# =============================================================================
# 事务备份阶段
# =============================================================================
log INFO "备份旧快照与发布文件哈希..."
PUBLISHED_FILE="$PUBLISHED_DIR/clash.yaml"

if [[ -f "$NL_SNAPSHOT" ]]; then
  cp -f "$NL_SNAPSHOT" "${NL_SNAPSHOT}.bak"
  NL_SNAP_BACKED=1
fi

if [[ -f "$US_SNAPSHOT" ]]; then
  cp -f "$US_SNAPSHOT" "${US_SNAPSHOT}.bak"
  US_SNAP_BACKED=1
fi

if [[ -f "$PUBLISHED_FILE" ]]; then
  cp -f "$PUBLISHED_FILE" "${PUBLISHED_FILE}.bak"
  PUB_BACKED=1
fi

# =============================================================================
# 事务发布提升阶段
# =============================================================================
log INFO "开始执行原子替换与版本提升事务..."

# 1. 提升荷兰源快照
if [[ -f "$NL_READY" ]]; then
  log INFO "提升荷兰 ready 临时文件为 sources 快照"
  mv -f "$NL_READY" "$NL_SNAPSHOT"
fi

# 2. 提升美国源快照
if [[ -f "$US_REAL" ]]; then
  log INFO "提升美国实时源为 sources 快照"
  cp -f "$US_REAL" "$US_SNAPSHOT"
fi

# 3. 原子发布最新的最终订阅文件
cp "$CANDIDATE_OUT" "$PUBLISHED_DIR/clash.yaml.new"
mv -f "$PUBLISHED_DIR/clash.yaml.new" "$PUBLISHED_FILE"
chmod 644 "$PUBLISHED_FILE"

# 4. 同步至荷兰副站镜像目录
NL_MIRROR_KEY="/opt/clash-sub/scripts/submirror_key"
NL_MIRROR_PATH="/var/www/sub/${SUB_TOKEN}/clash.yaml"

if [[ -f "$NL_MIRROR_KEY" ]]; then
  log INFO "同步已生成的订阅副本到荷兰副站..."
  if rsync -az --timeout=30 \
    -e "ssh -i $NL_MIRROR_KEY -o StrictHostKeyChecking=no -o ConnectTimeout=10" \
    "$PUBLISHED_FILE" \
    "${NL_MIRROR_USER}@${NL_IP}:${NL_MIRROR_PATH}" 2>&1 | tee -a "$LOG_FILE"; then
    log INFO "同步荷兰物理镜像成功！"

    # 校验哈希一致性
    log INFO "核对双端文件 SHA-256 哈希值..."
    local_sha=$(sha256sum "$PUBLISHED_FILE" | cut -d' ' -f1)
    remote_sha=$(ssh -i "$NL_MIRROR_KEY" -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
      "${NL_MIRROR_USER}@${NL_IP}" "sha256sum $NL_MIRROR_PATH" 2>/dev/null | cut -d' ' -f1 || echo "")
    if [[ "$local_sha" == "$remote_sha" ]]; then
      log INFO "哈希核对一致: $local_sha"
    else
      log WARN "双端哈希不一致或远程哈希获取失败！本地: $local_sha | 远程: $remote_sha"
    fi
  else
    log WARN "物理镜像同步失败，已记录告警并保留待下一次构建重试..."
  fi
else
  log WARN "荷兰同步密钥不存在，跳过同步"
fi

# 到这里表示全部提升和原子替换均成功完成，设置 STATUS_OK 为 1
STATUS_OK=1
log INFO "=========================================="
log INFO "合并与发布事务成功结束！"
log INFO "=========================================="
