#!/usr/bin/env bash
# =============================================================================
# scan-git-history.sh — 仓库 Git 提交全历史机密扫描审计工具
# 流程：遍历所有 Git commit，对私钥、Token、代理协议等进行深度静态扫描并脱敏提报。
# =============================================================================
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
PLAIN='\033[0m'

echo "====================================================="
echo "开始执行 Git 全分支及历史 Commit 机密扫描审计..."
echo "====================================================="

LEAK_FOUND=0

# 正则表达式定义
TG_TOKEN_REGEX="[0-9]{8,10}:[a-zA-Z0-9_-]{35}"
KEY_HEADER_REGEX="BEGIN (OPENSSH|RSA) PRIVATE KEY"
# 仅匹配真实含有长 Base64 凭据或域名特征的代理链接，过滤短小纯协议字面量误报
PROXY_URI_REGEX="(ss|vmess|vless|trojan)://[a-zA-Z0-9+=@/:-]{15,}"

# 1. 扫描所有 Commit 的文件状态
commits=$(git rev-list --all)

for commit in $commits; do
  # 1. 扫描 SSH 私钥特征
  # 使用 git grep 在特定 commit 树下查找，只匹配文本文件
  res_keys=$(git grep -EIhn "$KEY_HEADER_REGEX" "$commit" 2>/dev/null || true)
  if [[ -n "$res_keys" ]]; then
    while read -r line; do
      # 格式: path:line_no:content
      file_path=$(echo "$line" | cut -d: -f1)
      line_no=$(echo "$line" | cut -d: -f2)
      echo -e "${RED}[⚠️ 历史泄露警告]${PLAIN} Commit: ${commit:0:7} | 文件: ${file_path} (第 ${line_no} 行) | 类型: SSH PRIVATE KEY"
      LEAK_FOUND=1
    done <<< "$res_keys"
  fi

  # 2. 扫描 Telegram Token 特征
  res_tg=$(git grep -EIhn "$TG_TOKEN_REGEX" "$commit" 2>/dev/null || true)
  if [[ -n "$res_tg" ]]; then
    while read -r line; do
      file_path=$(echo "$line" | cut -d: -f1)
      line_no=$(echo "$line" | cut -d: -f2)
      echo -e "${RED}[⚠️ 历史泄露警告]${PLAIN} Commit: ${commit:0:7} | 文件: ${file_path} (第 ${line_no} 行) | 类型: Telegram Bot Token"
      LEAK_FOUND=1
    done <<< "$res_tg"
  fi

  # 3. 扫描 Shadowsocks / VMess / VLess / Trojan 代理协议链接特征 (排除 example 占位行)
  res_proxy=$(git grep -EIhn "$PROXY_URI_REGEX" "$commit" 2>/dev/null || true)
  if [[ -n "$res_proxy" ]]; then
    while read -r line; do
      file_path=$(echo "$line" | cut -d: -f1)
      line_no=$(echo "$line" | cut -d: -f2)
      content=$(echo "$line" | cut -d: -f3-)
      # 忽略文字性描述或占位符行的干扰
      if [[ "$content" == *"format:"* ]] || [[ "$content" == *"URI"* ]] || [[ "$content" == *"replace"* ]] || [[ "$content" == *"test-token"* ]]; then
        continue
      fi
      # 验证是否为真实链接（长度通常大于15）
      if [[ ${#content} -gt 15 ]]; then
        echo -e "${RED}[⚠️ 历史泄露警告]${PLAIN} Commit: ${commit:0:7} | 文件: ${file_path} (第 ${line_no} 行) | 类型: Proxy URI"
        LEAK_FOUND=1
      fi
    done <<< "$res_proxy"
  fi
done

echo "-----------------------------------------------------"
if [[ $LEAK_FOUND -eq 1 ]]; then
  echo -e "${RED}⚠️ 扫描结束：在 Git 历史中发现了敏感信息残留！建议轮换受影响的私钥和 Token。${PLAIN}"
  exit 1
else
  echo -e "${GREEN}✅ 审计通过：未在任何 Git 历史 commit 中发现已暴露的真实私钥、Token 或代理链接。${PLAIN}"
  exit 0
fi
