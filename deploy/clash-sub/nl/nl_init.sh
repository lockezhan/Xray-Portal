#!/usr/bin/env bash
# =============================================================================
# nl_init.sh — 荷兰副服务器初始化配置模板
# 使用说明: 请将相关占位符替换为实际安全参数。
# =============================================================================
set -euo pipefail

SUB_TOKEN="<SUB_TOKEN>"
US_IP="<US_SERVER_IP>"
# 请将此公钥内容替换为您在美国服务器上生成的 /opt/clash-sub/scripts/submirror_key.pub 的真实公钥内容
SUBMIRROR_PUB="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAA...REPLACE_WITH_YOUR_ACTUAL_SUBMIRROR_PUB_KEY... submirror@clash-sub"

echo "=== 1. 配置 config.env ==="
mkdir -p /opt/clash-sub-mirror/scripts /opt/clash-sub-mirror/logs
cat > /opt/clash-sub-mirror/config.env << NLENV
SUB_TOKEN=${SUB_TOKEN}
US_IP=${US_IP}
US_DOMAIN=us-sub.example.com
NL_DOMAIN=nl-sub.example.com
NL_SUB_DIR=/var/www/sub/${SUB_TOKEN}
US_INCOMING=/opt/clash-sub/incoming
LOG_FILE=/opt/clash-sub-mirror/logs/sync.log
NLENV
chmod 600 /opt/clash-sub-mirror/config.env

echo "=== 2. 部署 submirror ssh 公钥 ==="
if ! id submirror &>/dev/null; then
  useradd --system --shell /bin/bash --home-dir /home/submirror --create-home submirror
fi
mkdir -p /home/submirror/.ssh
chmod 700 /home/submirror/.ssh
# 限制此 SSH 密钥只允许执行远程同步逻辑 (rsync 目标路径限制)
echo "restrict,no-agent-forwarding,no-port-forwarding,no-X11-forwarding,no-pty ${SUBMIRROR_PUB}" > /home/submirror/.ssh/authorized_keys
chmod 600 /home/submirror/.ssh/authorized_keys
chown -R submirror:submirror /home/submirror

echo "=== 3. 配置订阅镜像目录 ==="
mkdir -p "/var/www/sub/${SUB_TOKEN}"
chown -R submirror:submirror "/var/www/sub/${SUB_TOKEN}"
chmod 755 /var/www/sub
chmod 755 "/var/www/sub/${SUB_TOKEN}"

echo "初始化配置成功！"
