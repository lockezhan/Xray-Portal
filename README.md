# Xray Portal

多机协作订阅合并 + Web 管理面板部署系统。

## 快速开始

### 准备工作

```bash
git clone <repo-url>
cd Xray_portal
```

### 美国主服务器

```bash
# 1. 创建配置文件（权限必须 0600）
cp deploy/env/us.env.example .env
chmod 600 .env
$EDITOR .env   # 必须填写所有 replace_me 字段

# 2. 一键部署（默认包含 Xray 代理安装）
sudo ./deploy/install.sh us --env .env

# 3. 验证部署状态
sudo ./deploy/verify.sh us --env .env
```

### 荷兰副服务器

```bash
# 1. 创建配置文件
cp deploy/env/nl.env.example .env
chmod 600 .env
$EDITOR .env   # SUB_TOKEN 必须与美国端一致

# 2. 一键部署
sudo ./deploy/install.sh nl --env .env

# 3. 验证部署状态
sudo ./deploy/verify.sh nl --env .env
```

### 完成部署后的人工操作

1. **互换 SSH 公钥**（荷兰 → 美国）：  
   部署摘要会打印荷兰机的 `subpush_key.pub`，将其添加到美国机的 subpush 用户 `authorized_keys`

2. **首次订阅推送**（荷兰机执行）：  
   ```bash
   sudo /usr/local/sbin/push-clash-subscription-nl
   ```

3. **分发订阅 URL** 给客户端

## 常用选项

```bash
# 仅安装代理（跳过控制面板）
sudo ./deploy/install.sh us --env .env --proxy-only

# 跳过代理（代理已提前单独安装）
sudo ./deploy/install.sh us --env .env --skip-proxy

# 跳过 TLS（仅 HTTP，用于内网测试）
sudo ./deploy/install.sh us --env .env --no-certbot

# 干跑验证配置（不修改系统）
sudo ./deploy/install.sh us --env .env --dry-run
```

## 查看部署状态

```bash
# 服务状态
systemctl status xray vpn-web nginx

# 验证脚本（包含订阅访问控制检查）
sudo ./deploy/verify.sh us --env .env

# 部署状态记录
cat /var/lib/xray-portal/deployment-state.json
```

## 详细文档

- [完整部署指南](docs/DEPLOYMENT.md)
- [运维操作手册](docs/OPERATIONS.md)
- [故障排查](docs/TROUBLESHOOTING.md)
- [手动部署（排障专用）](docs/MANUAL_DEPLOYMENT.md)
