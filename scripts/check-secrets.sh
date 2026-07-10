#!/usr/bin/env bash
# =============================================================================
# check-secrets.sh — 仓库本地安全泄漏审查扫描脚本
# 扫描本地工作区，验证是否有 SSH 私钥、Token、节点密码或配置文件误交 Git
# =============================================================================
set -euo pipefail

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
PLAIN='\033[0m'

echo -e "${YELLOW}开始执行安全审查与敏感信息扫描...${PLAIN}"
echo "-----------------------------------------------"

LEAK_FOUND=0

# 定义需要排查的文件过滤（排除脚本自身、.git 目录和备份目录）
SCAN_FILES=$(find . -type f \
  -not -path '*/.git/*' \
  -not -path '*/.venv/*' \
  -not -path '*/venv/*' \
  -not -path '*/.backup-*' \
  -not -path './scripts/check-secrets.sh' \
  -not -name '*.example' \
  -not -name 'README.md' \
  -not -name 'SECURITY.md' \
  -not -name 'DEPLOYMENT.md' \
  -not -name '.gitignore' \
  2>/dev/null || true)

if [[ -z "$SCAN_FILES" ]]; then
  echo -e "${GREEN}未发现需要扫描的普通文件，退出。${PLAIN}"
  exit 0
fi

# 1. 扫描 SSH 私钥泄露
echo "1. 扫描 SSH 私钥泄露..."
while read -r file; do
  if [[ -f "$file" ]]; then
    # 如果文件已被 git 忽略，跳过敏感硬编码扫描 (因为它不会被提交)
    if git check-ignore -q "$file" 2>/dev/null; then
      continue
    fi
    if grep -q "BEGIN OPENSSH PRIVATE KEY" "$file" 2>/dev/null || \
       grep -q "BEGIN RSA PRIVATE KEY" "$file" 2>/dev/null; then
      echo -e "${RED}[⚠️ 泄露警告]${PLAIN} 发现 SSH 私钥特征！"
      echo "  位置: ${file}"
      LEAK_FOUND=1
    fi
  fi
done <<< "$SCAN_FILES"

# 2. 扫描敏感硬编码字串 (如 SS 链接、Telegram Bot Token 等)
echo "2. 扫描 Token 与敏感密码参数硬编码..."
# 定义敏感词与正则
# Token格式如 123456:ABC-DEF
TG_TOKEN_REGEX="[0-9]{8,10}:[a-zA-Z0-9_-]{35}"
# SS 协议格式，更精准匹配真实的节点链接以防止注释行误报
SS_REGEX="ss://[a-zA-Z0-9+=@/:-]{15,}"

while read -r file; do
  if [[ -f "$file" ]]; then
    # 如果文件已被 git 忽略，跳过敏感硬编码扫描
    if git check-ignore -q "$file" 2>/dev/null; then
      continue
    fi
    # 逐行分析，不打印敏感内容本身，只打印行号和类型
    # 扫描疑似 Telegram Token
    line_no=1
    while read -r line; do
      if echo "$line" | grep -qE "$TG_TOKEN_REGEX" 2>/dev/null; then
        echo -e "${RED}[⚠️ 泄露警告]${PLAIN} 疑似 Telegram Bot Token 被硬编码！"
        echo "  位置: ${file} (行号: ${line_no})"
        LEAK_FOUND=1
      fi
      if echo "$line" | grep -qE "$SS_REGEX" 2>/dev/null; then
        echo -e "${RED}[⚠️ 泄露警告]${PLAIN} 疑似 Shadowsocks 代理配置链接被硬编码！"
        echo "  位置: ${file} (行号: ${line_no})"
        LEAK_FOUND=1
      fi
      # 简易检测 config.py 中的真实密码
      if echo "$line" | grep -qE "PORTAL_PASSWORD\s*=\s*\"[a-zA-Z0-9_]{4,}\"" 2>/dev/null && \
         ! echo "$line" | grep -q "config.py.example" 2>/dev/null && \
         ! echo "$line" | grep -q "replace-with" 2>/dev/null; then
        # 如果密码被设置了且不是 placeholder
        if [[ "$file" == *"config.py"* ]]; then
          echo -e "${RED}[⚠️ 泄露警告]${PLAIN} 疑似控制台登录密码被硬编码！"
          echo "  位置: ${file} (行号: ${line_no})"
          LEAK_FOUND=1
        fi
      fi
      line_no=$((line_no+1))
    done < "$file"
  fi
done <<< "$SCAN_FILES"

# 3. 检查是否有不该进入仓库的文件没有被 .gitignore 排除
echo "3. 检查 Git 未追踪的敏感残留文件..."
for file in .env config.env subpush_key submirror_key; do
  if [[ -f "$file" ]]; then
    # 验证是否已被 git ignore
    if ! git check-ignore -q "$file" 2>/dev/null; then
      echo -e "${RED}[⚠️ 泄露警告]${PLAIN} 核心敏感文件 [${file}] 存在于本地且未被 .gitignore 排除！"
      echo "  请立即编辑 .gitignore 将其排除，防止被 git commit。"
      LEAK_FOUND=1
    fi
  fi
done

echo "-----------------------------------------------"
if [[ $LEAK_FOUND -eq 1 ]]; then
  echo -e "${RED}❌ 安全审查失败！请修正上述泄露隐患后再进行提交。${PLAIN}"
  exit 1
else
  echo -e "${GREEN}✅ 安全审查通过！未在仓库中发现已暴露的敏感凭据。${PLAIN}"
  exit 0
fi
