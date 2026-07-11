#!/usr/bin/env bash
# =============================================================================
# validate-project.sh — 本地项目语法、文档与模板综合校验脚本 (含安全门禁)
# =============================================================================
set -euo pipefail

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
PLAIN='\033[0m'

# 参数解析
SECURITY_GATE=0
for arg in "$@"; do
  if [[ "$arg" == "--security-gate" ]]; then
    SECURITY_GATE=1
  fi
done

echo -e "${YELLOW}开始执行本地项目完整性与语法校验...${PLAIN}"
echo "-----------------------------------------------"

VALIDATION_FAILED=0

# 1. Python 语法编译校验
echo "1. 验证 Python 语法..."
if python3 -m compileall -q . 2>/dev/null; then
  echo -e "  [${GREEN}通过${PLAIN}] Python 脚本编译正常"
else
  echo -e "  [${RED}失败${PLAIN}] 存在 Python 脚本语法错误，请运行 python3 -m compileall . 检查"
  VALIDATION_FAILED=1
fi

# 2. Shell 脚本语法校验
echo "2. 验证 Shell 脚本语法..."
SHELL_FILES=$(find . -name "*.sh" -not -path '*/.venv/*' -not -path '*/venv/*' -not -path '*/.backup-*' 2>/dev/null || true)
shell_ok=1
for file in $SHELL_FILES; do
  if ! bash -n "$file" 2>/dev/null; then
    echo -e "  [${RED}失败${PLAIN}] Shell 语法错误: ${file}"
    shell_ok=0
    VALIDATION_FAILED=1
  fi
done
if [[ $shell_ok -eq 1 ]]; then
  echo -e "  [${GREEN}通过${PLAIN}] 所有 Shell 脚本语法检验正常"
fi

# 3. Systemd 配置文件结构校验
echo "3. 验证 Systemd 配置文件格式..."
SYSTEMD_FILES=$(find deploy/systemd -name "*.service" 2>/dev/null || true)
systemd_ok=1
for file in $SYSTEMD_FILES; do
  # 校验是否包含 Service 和 ExecStart 关键节点
  if ! grep -q "\[Service\]" "$file" || ! grep -q "ExecStart=" "$file"; then
    echo -e "  [${RED}失败${PLAIN}] Systemd 模板不完整: ${file}"
    systemd_ok=0
    VALIDATION_FAILED=1
  fi
done
if [[ $systemd_ok -eq 1 ]]; then
  echo -e "  [${GREEN}通过${PLAIN}] 所有 Systemd 服务文件基本结构正常"
fi

# 4. Nginx 配置文件与模板基本校验
echo "4. 验证 Nginx 配置模板结构..."
NGINX_FILES=$(find deploy/nginx -type f 2>/dev/null || true)
nginx_ok=1
for file in $NGINX_FILES; do
  # 验证大括号配对
  open_braces=$(tr -cd '{' < "$file" | wc -c)
  close_braces=$(tr -cd '}' < "$file" | wc -c)
  if [[ "$open_braces" -ne "$close_braces" ]]; then
    echo -e "  [${RED}失败${PLAIN}] Nginx 括号不配对: ${file} (左括号: ${open_braces}, 右括号: ${close_braces})"
    nginx_ok=0
    VALIDATION_FAILED=1
  fi
done
if [[ $nginx_ok -eq 1 ]]; then
  echo -e "  [${GREEN}通过${PLAIN}] 所有 Nginx 模板基本结构配对正常"
fi

# 5. 文档链接与引用存在性校验
echo "5. 验证文档中的交叉链接..."
markdown_ok=1
MD_FILES=$(find . -name "*.md" -not -path '*/.venv/*' -not -path '*/venv/*' -not -path '*/.backup-*' 2>/dev/null || true)
for file in $MD_FILES; do
  # 探测 README 相对链接的健康状况
  if [[ "$file" == "./README.md" ]]; then
    for doc in ARCHITECTURE.md DEPLOYMENT.md OPERATIONS.md SECURITY.md TROUBLESHOOTING.md; do
      if ! grep -q "$doc" "$file"; then
        echo -e "  [${YELLOW}警告${PLAIN}] README.md 中未提及核心文档: docs/${doc}"
      fi
      if [[ ! -f "docs/${doc}" ]]; then
        echo -e "  [${RED}失败${PLAIN}] 引用的核心文档不存在: docs/${doc}"
        markdown_ok=0
        VALIDATION_FAILED=1
      fi
    done
  fi
done
if [[ $markdown_ok -eq 1 ]]; then
  echo -e "  [${GREEN}通过${PLAIN}] 文档链接基础关联校验正常"
fi

# 6. 大文件拦截检查
echo "6. 检查是否存在超大残留文件..."
large_ok=1
LARGE_FILES=$(find . -type f -size +10M -not -path '*/.git/*' -not -path '*/.venv/*' -not -path '*/venv/*' -not -path '*/.backup-*' 2>/dev/null || true)
if [[ -n "$LARGE_FILES" ]]; then
  for file in $LARGE_FILES; do
    echo -e "  [${RED}警告${PLAIN}] 发现超大文件(>10MB): ${file}"
    large_ok=0
    VALIDATION_FAILED=1
  done
else
  echo -e "  [${GREEN}通过${PLAIN}] 未发现超大残留文件"
fi

# 7. 安全审计门禁校验 (当开启 --security-gate 时)
if [[ $SECURITY_GATE -eq 1 ]]; then
  echo "7. 执行 Git 历史安全机密审计门禁..."

  leaks=$(python3 -c "
import subprocess, sys
try:
    out = subprocess.check_output(['git', 'log', '-S', 'finalfinal', '--oneline']).decode('utf-8').strip()
    commits = [line.split()[0] for line in out.split('\n') if line.strip()]
except Exception:
    commits = []

found_any = False
for commit in commits:
    try:
        # 获取受修改的文件列表
        show_out = subprocess.check_output(['git', 'show', '--name-only', commit]).decode('utf-8').strip().split('\n')
        # 提取被改动的文件名
        files = [line for line in show_out if line.strip() and '/' in line and not line.startswith(' ')][:2]
        for f in files:
            print('  [FAIL] Commit: {} | File: {} | Type: production-domain-leak'.format(commit[:7], f))
            found_any = True
    except Exception:
        pass

if found_any:
    sys.exit(1)
" 2>/dev/null || echo "failed")

  if [[ "$leaks" == *"failed"* || -n "$leaks" ]]; then
    echo -e "$leaks"
    echo -e "  [${RED}失败${PLAIN}] 检测到 Git 历史中依然残留机密凭证或生产域名！门禁阻断。"
    VALIDATION_FAILED=1
  else
    echo -e "  [${GREEN}通过${PLAIN}] 未在 Git 历史中发现任何机密或敏感词残留"
  fi
fi

echo "-----------------------------------------------"
if [[ $VALIDATION_FAILED -eq 1 ]]; then
  echo -e  "${RED}❌ 项目自检失败！请修复逻辑/语法错误或执行 Git 历史脱敏重写。${PLAIN}"
  exit 1
else
  echo -e  "${GREEN}✅ 项目自检全部通过！项目处于健康状态。${PLAIN}"
  exit 0
fi
