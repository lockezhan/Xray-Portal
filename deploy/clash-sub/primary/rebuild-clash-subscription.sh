#!/usr/bin/env bash
# =============================================================================
# rebuild-clash-subscription — Primary端主订阅重建与事务发布脚本 (高安全回滚版)
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
SECONDARY_SNAP_BACKED=0
PRIMARY_SNAP_BACKED=0
PUB_BACKED=0
STATUS_OK=0

# 回滚与清理逻辑函数 (必须在 flock 锁持有期间退出前被调用)
cleanup_on_error() {
  local exit_code=$?

  # 清理临时零碎文件
  rm -f "/tmp/empty_primary.yaml" "/tmp/empty_secondary.yaml"
  rm -f "${CANDIDATE_OUT:-}"

  if [[ "$STATUS_OK" -ne 1 ]]; then
    log WARN "检测到事务中途故障退出 (Code: $exit_code)，自动恢复原快照和发布哈希..."

    # 还原Secondary快照
    if [[ "$SECONDARY_SNAP_BACKED" -eq 1 && -f "${SECONDARY_SNAPSHOT}.bak" ]]; then
      mv -f "${SECONDARY_SNAPSHOT}.bak" "$SECONDARY_SNAPSHOT"
      log INFO "已回退恢复旧Secondary快照"
    fi

    # 还原Primary快照
    if [[ "$PRIMARY_SNAP_BACKED" -eq 1 && -f "${PRIMARY_SNAPSHOT}.bak" ]]; then
      mv -f "${PRIMARY_SNAPSHOT}.bak" "$PRIMARY_SNAPSHOT"
      log INFO "已回退恢复旧Primary快照"
    fi

    # 还原发布文件
    if [[ "$PUB_BACKED" -eq 1 && -f "${PUBLISHED_FILE}.bak" ]]; then
      mv -f "${PUBLISHED_FILE}.bak" "$PUBLISHED_FILE"
      log INFO "已回退恢复旧订阅文件"
    fi

    # 既然失败了，必须把 ready 文件清除，防止其再次被错误提升
    rm -f "${SECONDARY_READY:-}"
  else
    log INFO "事务发布一切正常，清理备份..."
    rm -f "${SECONDARY_SNAPSHOT}.bak" "${PRIMARY_SNAPSHOT}.bak" "${PUBLISHED_FILE}.bak"
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
PRIMARY_REAL="$PRIMARY_SOURCE"
PRIMARY_SNAPSHOT="/opt/clash-sub/sources/primary-full.yaml"
PRIMARY_CANDIDATE=""

SECONDARY_READY="$INCOMING_DIR/secondary-full.yaml.ready"
SECONDARY_SNAPSHOT="/opt/clash-sub/sources/secondary-full.yaml"
SECONDARY_CANDIDATE=""

# 确定源文件
if [[ -f "$PRIMARY_REAL" ]]; then
  log INFO "采用实时Primary配置作为构建候选: $PRIMARY_REAL"
  PRIMARY_CANDIDATE="$PRIMARY_REAL"
elif [[ -f "$PRIMARY_SNAPSHOT" ]]; then
  log INFO "Primary实时配置不存在，将采用历史快照作为构建候选: $PRIMARY_SNAPSHOT"
  PRIMARY_CANDIDATE="$PRIMARY_SNAPSHOT"
else
  log WARN "无任何有效Primary配置源（既无实时配置又无历史快照）"
fi

if [[ -f "$SECONDARY_READY" ]]; then
  log INFO "发现新上传的就绪Secondary配置，作为构建候选: $SECONDARY_READY"
  SECONDARY_CANDIDATE="$SECONDARY_READY"
elif [[ -f "$SECONDARY_SNAPSHOT" ]]; then
  log INFO "无新上传就绪Secondary配置，将采用历史快照作为构建候选: $SECONDARY_SNAPSHOT"
  SECONDARY_CANDIDATE="$SECONDARY_SNAPSHOT"
else
  log WARN "无任何有效Secondary配置源（既无新上传文件又无历史快照）"
fi

# 双缺阻断
if [[ -z "$PRIMARY_CANDIDATE" && -z "$SECONDARY_CANDIDATE" ]]; then
  log ERROR "Primary与Secondary双端均无可用的有效配置源，中止构建。"
  rm -f "$SECONDARY_READY"
  exit 2
fi

# 传参规整
PRIMARY_MERGE_INPUT="$PRIMARY_CANDIDATE"
if [[ -z "$PRIMARY_MERGE_INPUT" ]]; then
  PRIMARY_MERGE_INPUT="/tmp/empty_primary.yaml"
  echo "proxies: []" > "$PRIMARY_MERGE_INPUT"
fi

SECONDARY_MERGE_INPUT="$SECONDARY_CANDIDATE"
if [[ -z "$SECONDARY_MERGE_INPUT" ]]; then
  SECONDARY_MERGE_INPUT="/tmp/empty_secondary.yaml"
  echo "proxies: []" > "$SECONDARY_MERGE_INPUT"
fi

# 在 generated 目录中合成候选配置文件
MERGE_SCRIPT="/opt/clash-sub/scripts/extract_merge.py"
CANDIDATE_OUT="/opt/clash-sub/generated/clash.yaml.candidate"
mkdir -p "$(dirname "$CANDIDATE_OUT")"

log INFO "运行合并器逻辑，输入 Primary: ${PRIMARY_MERGE_INPUT} | Secondary: ${SECONDARY_MERGE_INPUT}"
if ! "$PYTHON3" "$MERGE_SCRIPT" "$PRIMARY_MERGE_INPUT" "$SECONDARY_MERGE_INPUT" "$CANDIDATE_OUT" 2>&1 | tee -a "$LOG_FILE"; then
  log ERROR "Python 逻辑校验失败！中止发布。"
  rm -f "$SECONDARY_READY"
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
  rm -f "$SECONDARY_READY"
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
    rm -f "$SECONDARY_READY"
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

if [[ -f "$SECONDARY_SNAPSHOT" ]]; then
  cp -f "$SECONDARY_SNAPSHOT" "${SECONDARY_SNAPSHOT}.bak"
  SECONDARY_SNAP_BACKED=1
fi

if [[ -f "$PRIMARY_SNAPSHOT" ]]; then
  cp -f "$PRIMARY_SNAPSHOT" "${PRIMARY_SNAPSHOT}.bak"
  PRIMARY_SNAP_BACKED=1
fi

if [[ -f "$PUBLISHED_FILE" ]]; then
  cp -f "$PUBLISHED_FILE" "${PUBLISHED_FILE}.bak"
  PUB_BACKED=1
fi

# =============================================================================
# 事务发布提升阶段
# =============================================================================
log INFO "开始执行原子替换与版本提升事务..."

# 1. 提升Secondary源快照
if [[ -f "$SECONDARY_READY" ]]; then
  log INFO "提升Secondary ready 临时文件为 sources 快照"
  mv -f "$SECONDARY_READY" "$SECONDARY_SNAPSHOT"
fi

# 2. 提升Primary源快照
if [[ -f "$PRIMARY_REAL" ]]; then
  log INFO "提升Primary实时源为 sources 快照"
  cp -f "$PRIMARY_REAL" "$PRIMARY_SNAPSHOT"
fi

# 3. 原子发布最新的最终订阅文件
cp "$CANDIDATE_OUT" "$PUBLISHED_DIR/clash.yaml.new"
mv -f "$PUBLISHED_DIR/clash.yaml.new" "$PUBLISHED_FILE"
chmod 644 "$PUBLISHED_FILE"

# 4. 同步至Secondary副站镜像目录
SECONDARY_MIRROR_KEY="/opt/clash-sub/scripts/submirror_key"
SECONDARY_MIRROR_PATH="/var/www/sub/${SUB_TOKEN}/clash.yaml"

if [[ -f "$SECONDARY_MIRROR_KEY" ]]; then
  log INFO "同步已生成的订阅副本到Secondary副站..."
  if rsync -az --timeout=30 \
    -e "ssh -i $SECONDARY_MIRROR_KEY -o StrictHostKeyChecking=no -o ConnectTimeout=10" \
    "$PUBLISHED_FILE" \
    "${SECONDARY_MIRROR_USER}@${SECONDARY_IP}:${SECONDARY_MIRROR_PATH}" 2>&1 | tee -a "$LOG_FILE"; then
    log INFO "同步Secondary物理镜像成功！"

    # 校验哈希一致性
    log INFO "核对双端文件 SHA-256 哈希值..."
    local_sha=$(sha256sum "$PUBLISHED_FILE" | cut -d' ' -f1)
    remote_sha=$(ssh -i "$SECONDARY_MIRROR_KEY" -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
      "${SECONDARY_MIRROR_USER}@${SECONDARY_IP}" "sha256sum $SECONDARY_MIRROR_PATH" 2>/dev/null | cut -d' ' -f1 || echo "")
    if [[ "$local_sha" == "$remote_sha" ]]; then
      log INFO "哈希核对一致: $local_sha"
    else
      log WARN "双端哈希不一致或远程哈希获取失败！本地: $local_sha | 远程: $remote_sha"
    fi
  else
    log WARN "物理镜像同步失败，已记录告警并保留待下一次构建重试..."
  fi
else
  log WARN "Secondary同步密钥不存在，跳过同步"
fi

# 到这里表示全部提升和原子替换均成功完成，设置 STATUS_OK 为 1
STATUS_OK=1
log INFO "=========================================="
log INFO "合并与发布事务成功结束！"
log INFO "=========================================="
