[返回首页](../README.md) · [部署指南](DEPLOYMENT.md) · [故障排查](TROUBLESHOOTING.md) · [手动排障](MANUAL_DEPLOYMENT.md)

# 🛠️ 日常运维手册 (OPERATIONS.md)

---

## 1. 服务状态速查

### Primary主机

```bash
# 一键状态总览
systemctl status xray vpn-web nginx

# 各服务日志（实时）
journalctl -u xray -f -n 50
journalctl -u vpn-web -f -n 50
journalctl -u nginx -f -n 50
```

### Secondary副机

```bash
systemctl status xray nginx
journalctl -u xray -f -n 50
```

---

## 2. 一键健康验证

```bash
# Primary（完整检查：服务、端口、HTTP、YAML、访问控制）
sudo ./deploy/verify.sh primary --env .env

# Secondary（含订阅同步 PENDING 状态检测）
sudo ./deploy/verify.sh secondary --env .env
```

---

## 3. 订阅手动重建与推送

### 重建Primary订阅

```bash
# 重新生成 Clash 源文件并发布
sudo /usr/local/sbin/rebuild-clash-subscription

# 查看最新发布文件
ls -la /opt/clash-sub/published/clash.yaml

# 校验发布文件（YAML 语法 + Mihomo 内核）
python3 -c "import yaml; yaml.safe_load(open('/opt/clash-sub/published/clash.yaml'))" && echo "YAML OK"
mihomo -t -d /opt/clash-sub/published/
```

### 手动推送到Secondary（在Secondary机执行）

```bash
# Secondary机：推送本地 Clash 源到Primary存储
sudo /usr/local/sbin/push-clash-subscription-secondary

# 验证Secondary镜像文件存在
ls -la /var/www/sub/<SUB_TOKEN>/clash.yaml
```

---

## 4. 订阅版本回滚

```bash
# 查看历史备份
ls -lt /opt/clash-sub/backup/ | head -20

# 回滚到指定版本
sudo cp /opt/clash-sub/backup/clash.yaml.20260710-080448 \
    /opt/clash-sub/published/clash.yaml

# 回滚后重新验证
python3 -c "import yaml; yaml.safe_load(open('/opt/clash-sub/published/clash.yaml'))"
sudo nginx -s reload
```

---

## 5. 节点重装后更新流程

### 5.1 Primary节点 Xray 更新

```bash
# 重新渲染 Xray 配置（保持原密钥）
sudo bash apps/vpn_web/proxy/lib/render-xray-config.sh
sudo systemctl restart xray

# 重新生成订阅源
sudo bash apps/vpn_web/proxy/gen_clash_config.sh

# 重建发布版本
sudo /usr/local/sbin/rebuild-clash-subscription

# 验证
sudo ./deploy/verify.sh primary --env .env
```

### 5.2 Secondary节点 Xray 更新

```bash
# Secondary机：重渲染配置，重启服务
sudo bash apps/vpn_web/proxy/lib/render-xray-config.sh
sudo systemctl restart xray

# 更新Secondary Clash 源
sudo bash apps/vpn_web/proxy/gen_clash_config.sh

# 推送到Primary触发重建
sudo /usr/local/sbin/push-clash-subscription-secondary
```

---

## 6. 证书续期

Certbot 已配置自动续期（由 systemd timer 驱动），一般无需手动操作。

```bash
# 检查续期定时任务
systemctl status certbot.timer
certbot certificates

# 手动续期（测试）
sudo certbot renew --dry-run

# 强制立即续期
sudo certbot renew --force-renewal
sudo nginx -s reload
```

---

## 7. 密钥轮换

> [!CAUTION]
> 密钥轮换会导致所有现有客户端连接中断，必须同步更新客户端 Clash 配置。

```bash
# 1. 删除旧密钥文件（触发下次部署时重新生成）
sudo rm /etc/xray-portal/proxy.env

# 2. 重新渲染（自动生成新密钥）
sudo bash apps/vpn_web/proxy/lib/render-xray-config.sh

# 3. 重启 Xray
sudo systemctl restart xray

# 4. 重建订阅（客户端需重新下载）
sudo bash apps/vpn_web/proxy/gen_clash_config.sh
sudo /usr/local/sbin/rebuild-clash-subscription
```

---

## 8. 更新部署系统

```bash
git pull
# 更新 Web 面板（不重装代理）
sudo ./deploy/install.sh primary --env .env --skip-proxy

# 仅更新代理（不重装 Web 面板）
sudo ./deploy/install.sh primary --env .env --proxy-only
```

---

## 9. 日志路径参考

| 日志内容 | 路径 |
|---------|------|
| Web 面板访问日志 | `/var/log/vpn-web/access.log` |
| Web 面板错误日志 | `/var/log/vpn-web/error.log` |
| Nginx 访问日志 | `/var/log/nginx/access.log` |
| Nginx 错误日志 | `/var/log/nginx/error.log` |
| 重建订阅日志 | `/opt/clash-sub/logs/rebuild.log` |
| Secondary推送日志 | 通过 `journalctl -u push-clash-secondary` 查看 |
| 部署状态记录 | `/var/lib/xray-portal/deployment-state.json` |

---

## 10. 紧急恢复

### Nginx 配置损坏

```bash
# 恢复到上一次已知良好配置
sudo nginx -t 2>&1  # 查看错误
sudo cp /etc/nginx/sites-available/xray-portal.conf.bak \
    /etc/nginx/sites-enabled/xray-portal.conf
sudo nginx -s reload
```

### vpn-web 服务宕机

```bash
journalctl -u vpn-web -n 100 --no-pager
sudo systemctl restart vpn-web
# 若重启失败，检查 Python 依赖
sudo /usr/local/vpn-web/venv/bin/pip install -r \
    /usr/local/vpn-web/requirements.txt
sudo systemctl start vpn-web
```

### Xray 服务宕机

```bash
xray run -test -c /usr/local/etc/xray/config.json
sudo systemctl restart xray
```

---

[返回 README](../README.md)
