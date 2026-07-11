# 完整部署指南 (DEPLOYMENT.md)

本文档描述在空白 Ubuntu 24.04 服务器上完成完整部署所需的所有步骤。

## 前置条件

| 条件 | 美国主机 | 荷兰副机 |
|------|---------|---------|
| 系统 | Ubuntu 24.04 | Ubuntu 24.04 |
| 最低内存 | 1GB | 512MB |
| 公网 IP | ✓ | ✓ |
| 域名 DNS | 已指向此 IP | 已指向此 IP |
| Root 访问 | ✓ | ✓ |

> [!IMPORTANT]
> 域名的 DNS 必须在部署前已经生效（`dig +short us.example.com` 应返回正确 IP），否则 Certbot TLS 申请会失败。若未配置 DNS，请使用 `--no-certbot` 先完成 HTTP 部署。

## 一、准备 .env 文件

### 美国主机

```bash
# 下载仓库
git clone <repo-url>
cd Xray_portal

# 从模板复制
cp deploy/env/us.env.example .env
chmod 600 .env

# 编辑配置（必须填写所有 replace_me 字段）
nano .env
```

**必填字段：**

| 变量 | 说明 |
|------|------|
| `US_SERVER_IP` | 本机公网 IPv4 |
| `NL_SERVER_IP` | 荷兰副机公网 IPv4 |
| `US_SUB_DOMAIN` | 订阅服务域名（已 DNS 到此机）|
| `NL_SUB_DOMAIN` | 荷兰订阅域名 |
| `SUB_TOKEN` | 32 字节十六进制随机 Token |
| `PORTAL_PASSWORD` | 面板登录密码 |
| `FLASK_SECRET_KEY` | 64 字节十六进制 Flask Secret |
| `XRAY_SHA256_LINUX_AMD64` | Xray 对应版本 SHA256 |
| `MIHOMO_SHA256_LINUX_AMD64` | Mihomo 对应版本 SHA256 |

生成 Token 和 Secret Key：
```bash
python3 -c "import secrets; print(secrets.token_hex(32))"   # Token
python3 -c "import secrets; print(secrets.token_hex(64))"   # Secret Key
```

获取 SHA256：
```bash
# Xray
XRAY_VER=v25.6.3
curl -sL "https://github.com/XTLS/Xray-core/releases/download/${XRAY_VER}/Xray-linux-64.zip.sha256sum"

# Mihomo
MIHOMO_VER=v1.18.10
# 查看 https://github.com/MetaCubeX/mihomo/releases/tag/${MIHOMO_VER}
```

### 荷兰副机

```bash
cp deploy/env/nl.env.example .env
chmod 600 .env
nano .env
```

> [!WARNING]
> 荷兰 `.env` 中 **绝对不要** 填入 `PORTAL_PASSWORD`、`FLASK_SECRET_KEY`、Bot Token 等美国端凭据。这些字段在荷兰角色中会被 env.sh 主动 unset。

## 二、执行部署

### 美国主机（完整安装）

```bash
# 完整安装（包含 Xray 代理 + Web 面板 + Nginx + TLS）
sudo ./deploy/install.sh us --env .env

# 安装完成后验证
sudo ./deploy/verify.sh us --env .env
```

### 荷兰副机（完整安装）

```bash
sudo ./deploy/install.sh nl --env .env
sudo ./deploy/verify.sh nl --env .env
```

## 三、部署完成后的手动操作

### 3.1 互换 SSH 公钥（用于荷兰→美国订阅推送）

部署摘要会显示荷兰机生成的 `subpush_key.pub` 内容，或者手动查看：

```bash
# 在荷兰机执行
cat /home/subpush/.ssh/subpush_key.pub
```

将公钥内容添加到**美国机**的 subpush 用户 `authorized_keys`：

```bash
# 在美国机执行
sudo -u subpush bash -c 'mkdir -p ~/.ssh && chmod 700 ~/.ssh'
# 粘贴荷兰机的公钥
echo "restrict,...,command=\"rsync ...\" ssh-ed25519 AAAA... subpush@nl" \
    | sudo tee -a /home/subpush/.ssh/authorized_keys
sudo chmod 600 /home/subpush/.ssh/authorized_keys
```

> [!IMPORTANT]
> `authorized_keys` 中必须使用 `command=` 强制命令限制 rsync 路径，部署脚本已在荷兰端的 submirror 用户中自动设置，美国端需手动核验。

### 3.2 首次订阅推送

```bash
# 在荷兰机执行
sudo /usr/local/sbin/push-clash-subscription-nl

# 验证镜像文件是否到位
ls -la /var/www/sub/<SUB_TOKEN>/clash.yaml
```

### 3.3 分发订阅 URL

两台服务器分别提供：
- `https://us.example.com/<SUB_TOKEN>/clash.yaml`（主线路）
- `https://nl.example.com/<SUB_TOKEN>/clash.yaml`（备线路）

## 四、常用部署变体

### 分阶段部署（代理和控制面板分开安装）

```bash
# 第一步：仅安装代理
sudo ./deploy/install.sh us --env .env --proxy-only

# 第二步：仅安装控制面板
sudo ./deploy/install.sh us --env .env --skip-proxy
```

### 跳过 TLS（内网测试或 DNS 未就绪）

```bash
sudo ./deploy/install.sh us --env .env --no-certbot
# HTTP 访问: http://us.example.com/<TOKEN>/clash.yaml
```

### 干跑（验证配置不修改系统）

```bash
sudo ./deploy/install.sh us --env .env --dry-run
```

## 五、Nginx 条件服务开关

`.env` 中有以下开关控制 Nginx 反向代理：

| 变量 | 说明 | 未部署时 |
|------|------|---------|
| `ENABLE_WEB=true` | Flask 面板 (→:8080) | 必须设为 false，否则 502 |
| `ENABLE_API=true` | API 后端 (→:9000) | **默认 false**，未部署时禁止开启 |
| `ENABLE_BOTS=true` | Bot 服务 (→:8082) | **默认 false**，未部署时禁止开启 |

> [!CAUTION]
> 将 `ENABLE_API=true` 或 `ENABLE_BOTS=true` 设置为 true 而对应服务未启动，会导致 Nginx 代理到死端口，所有请求返回 502。安装脚本会在服务未运行时自动强制设置为 false。

## 六、更新与重新部署

```bash
git pull
sudo ./deploy/install.sh us --env .env --skip-proxy   # 仅更新 Web 面板
```

重新部署是幂等的：代理密钥已存在于 `/etc/xray-portal/proxy.env` 时不会重新生成。
