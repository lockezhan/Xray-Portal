# 🛠️ 仓库辅助验证与敏感扫描工具 (`scripts`)

本目录包含用于保障本仓库安全、语法严谨以及没有秘密外泄的本地审计脚本。

## 1. 核心工具说明
*   **`validate-project.sh`**：
    *   **用途**：在提交 Git 或部署前，对整个本地仓库的脚本语法（Shell）、代码语法（Python编译）、配置文件模板（YAML、JSON、Systemd、Nginx 格式）以及文档链接有效性进行综合诊断。
*   **`check-secrets.sh`**：
    *   **用途**：防止任何开发人员无意中将生产环境的密码、Shadowsocks 代理密码、订阅 Token、Telegram Bot Token、QQ 凭据或 SSH 敏感私钥打包提交到 Git 中。

---

## 2. 常用开发提报流程
在您对代码进行任何修改或准备执行 `git commit` 前，请务必在仓库根目录下运行：
```bash
# 1. 检查是否存在敏感信息外泄
./scripts/check-secrets.sh

# 2. 检查各模块语法和配置模板有无致命错误
./scripts/validate-project.sh
```

---

## 3. 安全扫描机制
`check-secrets.sh` 会在本地仓库中自动执行正则匹配扫描。如果发现敏感特征（如私钥特征、疑似 Token、ss 节点配置等），它仅会报告发生泄漏的**文件名、行号及特征类型**，**绝对不会**在控制台日志中完整输出泄漏的具体敏感数值，最大程度保护隐私安全。
