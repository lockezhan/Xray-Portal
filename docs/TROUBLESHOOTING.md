# 🔍 常见故障排查与诊断手册 (`docs/TROUBLESHOOTING.md`)

本文汇总了系统在运行、合并订阅、同步或客户端连接时可能遇到的故障，并提供标准排查和修复方案。

---

## 1. 客户端下载主/备订阅返回 404 Not Found

### 现象
客户端导入或浏览器访问 `https://test.finalfinal.dpdns.org/<TOKEN>/clash.yaml` 时返回 `404 Not Found`。

### 可能原因
1.  Nginx 配置文件中的 Token 路径与实际 `SUB_TOKEN` 不匹配。
2.  最终订阅文件 `/opt/clash-sub/published/clash.yaml` 不存在或权限被拒绝。
3.  Nginx 运行账户 `www-data` 对 `/opt/clash-sub/published/` 目录没有搜索 (`+x`) 和读取 (`+r`) 权限。

### 检查与诊断命令
1.  **确认美国端 Token 的真实数值**：
    ```bash
    grep "^SUB_TOKEN=" /opt/clash-sub/scripts/config.env
    ```
2.  **检查 Nginx 实际载入的配置**：
    ```bash
    nginx -T | grep -A 10 "clash.yaml"
    ```
3.  **测试 www-data 用户的读取权限**：
    ```bash
    sudo -u www-data head -n 5 /opt/clash-sub/published/clash.yaml
    ```
    *(若返回 Permission Denied，说明权限有误)*。

### 修复方式
1.  修正 Nginx 路径中的 Token。
2.  修正群组所有权并把 `www-data` 加进 `subpush` 组：
    ```bash
    sudo usermod -aG subpush www-data
    sudo systemctl restart nginx
    ```

---

## 2. 荷兰无法推送配置到美国

### 现象
荷兰运行 `push-clash-subscription-nl` 提示 `Permission denied (publickey)` 或 `scp: Connection closed`。

### 可能原因
1.  美国 `subpush` 用户的登录 shell 被设置为了 `/usr/sbin/nologin`（sshd 拒绝其执行 command）。
2.  美国端 `/opt/clash-sub/` 的目录对群组开放了写权限（权限为 `770`），触发了 sshd 的 `StrictModes` 安全保护。
3.  荷兰端使用了现代 SFTP 协议，而美国的 wrapper 脚本没有支持，直接被断开连接。

### 检查与诊断命令
1.  在美国端以 root 身份检查 `subpush` 的 shell：
    ```bash
    getent passwd subpush
    ```
2.  查看 SSHD 报错日志（在美国服务器上）：
    ```bash
    sudo grep "subpush" /var/log/auth.log 2>/dev/null || journalctl -u ssh -n 20
    ```
    *(如果看到 "bad ownership or modes for directory"，说明目录权限不合规)*。

### 修复方式
1.  将 `subpush` 用户的 shell 设为 `/bin/bash`。
2.  严格修正美国主机的 SSH 目录所有者为 `subpush` 且主目录 `/opt/clash-sub` 为 `755`，禁止 group 写入：
    ```bash
    chown root:root /opt/clash-sub && chmod 755 /opt/clash-sub
    chown -R subpush:subpush /opt/clash-sub/.ssh && chmod 700 /opt/clash-sub/.ssh
    ```
3.  确保荷兰推送脚本中使用 `scp -O` (传统协议) 兼容模式。

---

## 3. 美国主站无法向荷兰同步最终订阅

### 现象
重建脚本执行到最后时，提示 `submirror@NL_IP: Permission denied`。

### 可能原因
1.  美国端的 `/opt/clash-sub/scripts/submirror_key` 权限设置过于开放（如 `640`），导致 SSH 客户端出于安全直接忽略该私钥。
2.  荷兰端的 `/home/submirror/.ssh/authorized_keys` 中没有正确写入公钥。

### 检查与诊断命令
在美国端以 root 身份查看密钥权限：
```bash
ls -la /opt/clash-sub/scripts/submirror_key
```

### 修复方式
1.  将美国端私钥文件所有者改为 `subpush`，并严格设为 `600`：
    ```bash
    chown subpush:subpush /opt/clash-sub/scripts/submirror_key
    chmod 600 /opt/clash-sub/scripts/submirror_key
    ```
2.  检查并确保荷兰端 `/home/submirror/.ssh/authorized_keys` 含有正确的公钥。

---

## 4. 订阅合并失败（Mihomo 语法校验未通过）

### 现象
重建脚本提示 `Mihomo 配置检查失败，中止发布`，且日志包含 `if "respect-rules" is turned on, "proxy-server-nameserver" cannot be empty` 等报错。

### 可能原因
合并脚本在构建 DNS 及代理配置时，加入了与本机的 Mihomo/Clash-Meta 内核不兼容的规则或未完善的 DNS 参数。

### 检查与诊断命令
查看日志：
```bash
cat /opt/clash-sub/logs/rebuild.log
```

### 修复方式
1.  修改 `extract_merge.py`，将基础 DNS 中的 `respect-rules` 改为 `false`（或在 `dns` 块中补全 `proxy-server-nameserver`）。
2.  手动运行 `rebuild-clash-subscription` 测试其是否能顺利通过校验并完成原子替换。
