# Xray Portal

多机协作订阅合并 + Web 管理面板部署系统。

## 快速开始

### 准备工作

```bash
git clone https://github.com/lockezhan/Xray-Portal.git
cd Xray_portal
```

### 主机 (Primary)主服务器

```bash
# 1. 创建配置文件（权限必须 0600）
cp deploy/env/primary.env.example .env
chmod 600 .env
$EDITOR .env   # 必须填写所有 replace_me 字段

# 2. 一键部署（默认包含 Xray 代理安装）
sudo ./deploy/install.sh primary --env .env

# 3. 验证部署状态
sudo ./deploy/verify.sh primary --env .env
```

### 副机 (Secondary)

```bash
# 1. 创建配置文件
cp deploy/env/secondary.env.example .env
chmod 600 .env
$EDITOR .env   # SUB_TOKEN 必须与主机 (Primary)端一致

# 2. 一键部署
sudo ./deploy/install.sh secondary --env .env

# 3. 验证部署状态
sudo ./deploy/verify.sh secondary --env .env
```

### 完成部署后的人工操作

1. **安装受限 SSH 公钥**（Secondary → Primary）：
   在 Secondary 读取 `/opt/clash-sub-mirror/subpush_key.pub`，然后在 Primary 使用
   `sudo ./deploy/install-peer-key.sh primary --pubkey '<完整公钥>'` 安装。Primary 的实际授权文件为
   `/opt/clash-sub/.ssh/authorized_keys`。

2. **首次订阅推送**（Secondary 执行）：
   ```bash
   sudo /usr/local/sbin/push-clash-subscription-secondary
   ```

3. **分发订阅 URL** 给客户端

## 常用选项

```bash
# 仅安装代理（跳过控制面板）
sudo ./deploy/install.sh primary --env .env --proxy-only

# 跳过代理（代理已提前单独安装）
sudo ./deploy/install.sh primary --env .env --skip-proxy

# 跳过 TLS（仅 HTTP，用于内网测试）
sudo ./deploy/install.sh primary --env .env --no-certbot

# 干跑验证配置（不修改系统）
sudo ./deploy/install.sh primary --env .env --dry-run
```

## 查看部署状态

```bash
# 服务状态
systemctl status xray vpn-web nginx

# 验证脚本（包含订阅访问控制检查）
sudo ./deploy/verify.sh primary --env .env

# 部署状态记录
cat /var/lib/xray-portal/deployment-state.json
```

## 详细文档

- [完整部署指南](docs/DEPLOYMENT.md)
- [运维操作手册](docs/OPERATIONS.md)
- [故障排查](docs/TROUBLESHOOTING.md)
- [手动部署（排障专用）](docs/MANUAL_DEPLOYMENT.md)


- [架构设计](docs/ARCHITECTURE.md)
- [安全配置](docs/SECURITY.md)

## 🌐 Azure IPv6 与网络配置说明

- **Azure VM 私有 IPv6 现象**：Azure VM 内部网卡仅显示私有 IPv6 地址（例如 `fd00:...`），属于 Azure 网络架构设计的正常现象。公网 IPv6 由 Azure 网络层统一管理与 NAT 映射。
- **公网 IPv6 自动探测与手动配置**：
  - `install.sh` 与 `gen_clash_config.sh` 会优先通过 IPv6 出口自动探测公网 IPv6 地址。
  - 若云平台网络映射异常或需固定公网 IPv6，可在 `/etc/xray-portal/proxy-meta.conf` 或 `/etc/xray-meta.conf` 中手动配置：
    ```ini
    PUBLIC_IPV6=<YOUR_PUBLIC_IPV6>
    ```
  - 修改元配置后，运行 `gen_clash_config.sh` 或重新运行安装脚本即可自动重构节点订阅。
- **防火墙与安全组要求**：除了在系统内部配置 UFW 规则外，还必须在 **Azure NSG (Network Security Group / 网络安全组)** 中放行相应的 TCP 与 UDP 入站端口。