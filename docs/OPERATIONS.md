# 🛠️ 系统日常运维与维护手册 (`docs/OPERATIONS.md`)

本文用于指导系统管理员在节点变动、订阅回滚、健康状态排查等日常场景下的标准运维操作。

---

## 1. 核心服务状态查看

在美国主服务器上，以下三个服务负责整个控制面板与机器人的运行：
*   **Clash 订阅 Flask Web 控制台**：
    ```bash
    systemctl status clash-subscribe
    journalctl -u clash-subscribe -f -n 100
    ```
*   **QQ-TG 桥接 Bot**：
    ```bash
    systemctl status tg-qq-bridge
    journalctl -u tg-qq-bridge -f -n 100
    ```
*   **TG 拦截转发 Bot**：
    ```bash
    systemctl status tgbot
    journalctl -u tgbot -f -n 100
    ```

在荷兰副服务器上，可通过下述命令核验 Nginx 运行状况：
```bash
systemctl status nginx
journalctl -u nginx -f -n 50
```

---

## 2. 合并与订阅手动重建命令

当修改了基础模板或希望强行重新更新两端节点并分发时，在**美国主服务器**执行：
```bash
sudo /usr/local/sbin/rebuild-clash-subscription
```
该命令会自动检测 `/opt/clash-sub/incoming/clash.yaml` 处的最新荷兰配置，并在合成、验证通过后自动通过 rsync 回传给荷兰。

---

## 3. 手动从荷兰推送最新配置

当荷兰服务器重新部署了 Xray 产生了新的 `/var/www/clash/clash.yaml` 配置，或者希望手动测试同步链路时，在**荷兰副服务器**执行：
```bash
sudo /usr/local/sbin/push-clash-subscription-nl
```
这会完成荷兰本地的格式验证 ➡️ 上传至美国 ➡️ 触发美国 `rebuild` 构建 ➡️ 美国合成并回传最终订阅至荷兰，实现全闭环更新。

---

## 4. 订阅版本历史回滚操作

如果新合成的 Clash 订阅包含未知格式错误或节点失联，我们需要将其回滚到上一次成功的可用版本。

1.  **查看当前所有历史备份版本**（在美国服务器上）：
    ```bash
    sudo /usr/local/sbin/rollback-clash-subscription --list
    ```
2.  **执行回滚**（传入目标备份文件名）：
    ```bash
    sudo /usr/local/sbin/rollback-clash-subscription clash.yaml.20260710-080448
    ```
    *构建系统会自动执行 YAML 语法验证，验证通过后原子替换美国本地发布文件，并同步回传更新荷兰镜像，确保双端同步回滚成功。*

---

## 5. 两端节点重装指南

### 5.1 场景一：美国节点重装
1.  在美国端以 root 身份重新运行 `./install.sh` 或更新 Xray，生成新的 `/var/www/clash/clash.yaml`。
2.  更新后直接执行：
    ```bash
    sudo /usr/local/sbin/post-deploy-hook-us
    ```
    它会自动触发本机的 `rebuild` 构建流程，重新拉取本地新生成的美国节点与之前缓存的荷兰节点进行合成。

### 5.2 场景二：荷兰节点重装
1.  在荷兰端以 root 身份重装 Xray，生成新的 `/var/www/clash/clash.yaml`。
2.  更新后直接执行：
    ```bash
    sudo /usr/local/sbin/post-deploy-hook-nl
    ```
    这会触发荷兰向美国上传最新配置，唤醒美国重建并拉取回传，客户端无感完成更新。

---

## 6. 日志存储路径

*   **美国主重建与合成日志**：`/opt/clash-sub/logs/rebuild.log`
*   **美国回滚操作日志**：`/opt/clash-sub/logs/rollback.log`
*   **荷兰主动推送日志**：`/opt/clash-sub-mirror/logs/push.log`
*   **美国 Nginx 访问与安全审计日志**：`/var/log/nginx/access.log`
*   **荷兰 Nginx 访问与安全审计日志**：`/var/log/nginx/access.log`

---

## 7. 快速健康检查清单

以管理员身份进行下述只读检测，验证系统是否处于完全健康的状态：
1.  **验证 Nginx 配置**：
    ```bash
    sudo nginx -t
    ```
2.  **校验最终订阅 YAML 格式**：
    ```bash
    python3 -c "import yaml; yaml.safe_load(open('/opt/clash-sub/published/clash.yaml'))" && echo "Local YAML OK"
    ```
3.  **使用 Mihomo 内核校验（测试配置有效性）**：
    ```bash
    /usr/local/bin/mihomo -t -f /opt/clash-sub/published/clash.yaml
    ```
    *(确保输出 `test is successful`)*。
4.  **测试 HTTPS 订阅下载响应**（检查是否包含 header 和正确 mime）：
    ```bash
    curl -I -sS "https://test.finalfinal.dpdns.org/您的SUB_TOKEN/clash.yaml"
    ```
    *(确认返回 `HTTP/1.1 200 OK`，且包含 `X-Robots-Tag: noindex, nofollow` 标头)*。
