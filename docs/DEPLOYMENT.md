[返回项目首页](../README.md) ·
[系统架构](ARCHITECTURE.md) ·
[部署指南](DEPLOYMENT.md) ·
[日常运维](OPERATIONS.md) ·
[安全规范](SECURITY.md) ·
[故障排查](TROUBLESHOOTING.md)

# 🚀 系统部署指南 (`docs/DEPLOYMENT.md`)

本文详细说明如何在两台空白的 Linux VPS 服务器上完成“一主一副”合并订阅分发系统的安装、配置及打通。

---

## 1. 前置软硬件要求

### 1.1 系统与核心环境
*   **支持的发行版**：Ubuntu 20.04 / 22.04 / 24.04 LTS。
*   **Python 版本**：Python >= 3.8 (包含 pip 和 venv 支持)。
*   **必需系统组件**：Nginx, rsync, OpenSSH-Server, systemd, tar, gunzip, wget。

### 1.2 域名与网络
*   **域名 DNS 解析**：
    *   `us-sub.example.com` ➡️ 指向美国服务器公网 IP。
    *   `nl-sub.example.com` ➡️ 指向荷兰服务器公网 IP。
*   **防火墙端口放行**：两台服务器的 80 和 443 端口必须开放以供 Nginx 提供订阅并让 Let's Encrypt 证书验证通过。

---

## 2. 基于角色与环境变量的一键部署系统 (推荐)

系统提供基于角色 (`us` 美国主服务器 / `nl` 荷兰副机) 和隔离环境变量 (`.env`) 的规范化一键自动化部署流程，无需手动逐条敲击多条系统命令。

### 2.1 美国主服务器 (`us` 角色) 部署步骤
1.  根据模板准备美国专属环境变量：
    ```bash
    cp deploy/env/us.env.example .env
    chmod 600 .env
    nano .env  # 填入 IP、公网域名、高强度随机 SUB_TOKEN 及 Flask 密码等
    ```
2.  执行一键部署与验证命令：
    ```bash
    # 可选预览部署命令动作
    sudo ./deploy/install.sh us --env .env --dry-run

    # 执行正式原子化部署
    sudo ./deploy/install.sh us --env .env
    ./deploy/verify.sh us --env .env
    ```

### 2.2 荷兰副服务器 (`nl` 角色) 部署步骤
1.  根据模板准备荷兰精简环境变量（**切勿填入 Flask/Bot 密码或 Token**）：
    ```bash
    cp deploy/env/nl.env.example .env
    chmod 600 .env
    nano .env  # 仅填入目标 IP、域名和对应的 SUB_TOKEN
    ```
2.  执行一键部署与自检：
    ```bash
    sudo ./deploy/install.sh nl --env .env
    ./deploy/verify.sh nl --env .env
    ```

### 2.3 双机互联 SSH 公钥注入与自动化远程推送
*   **公钥注入**：部署完成后，通过工具注入对方机器 SSH 公钥到受限账户：
    ```bash
    # 在美国端运行 (注入荷兰的 subpush_key.pub 且强绑定 subpush-cmd-wrapper)
    sudo ./deploy/install-peer-key.sh us --pubkey /path/to/subpush_key.pub
    ```
*   **自动化远程推送 (`remote-deploy.sh`)**：支持自本地直接自动化分发执行：
    ```bash
    ./deploy/remote-deploy.sh us --host ubuntu@us.example.com --env deploy/env/us.env
    ```

### 2.4 升级、回滚与维护说明
*   **平滑升级**：更新代码仓库后，重复执行 `sudo ./deploy/install.sh <角色> --env .env` 即可基于 `safe_install` 完成原子无中断升级。
*   **应急回滚**：如遇订阅异常，可在美国机器执行 `/usr/local/sbin/rollback-clash-subscription` 快速回退到上一个已验证发布的快照版本。

---

## 3. 美国主服务器手动部署参考步骤

在美国端以 `root` 用户身份依次执行下述配置：

### 2.1 目录初始化与权限设定
创建主订阅合成目录结构，并配置专用受限账户 `subpush`：
```bash
# 1. 建立目录
mkdir -p /opt/clash-sub/{incoming,sources,template,generated,published,backups,scripts,logs}

# 2. 注册受限 shell 账户 subpush (允许 bash 以便 scp/rsync 使用，但限制其密钥)
useradd --system --shell /bin/bash --home-dir /opt/clash-sub --no-create-home subpush

# 3. 设置目录归属与权限
chown -R root:subpush /opt/clash-sub
find /opt/clash-sub -type d -exec chmod 770 {} \;
find /opt/clash-sub -type f -exec chmod 660 {} \;
```

### 2.2 部署 Python 依赖与自动化脚本
1.  将 `extract_merge.py` 拷贝至 `/opt/clash-sub/scripts/extract_merge.py` (设置所有者 `root:subpush`，权限 `750`)。
2.  将 `rebuild-clash-subscription.sh` 拷贝至 `/usr/local/sbin/rebuild-clash-subscription` 并赋予可执行权限 `755`。
3.  将 `rollback-clash-subscription` 拷贝至 `/usr/local/sbin/rollback-clash-subscription` 并赋予可执行权限 `755`。
4.  安装 `PyYAML` 依赖：
    ```bash
    pip3 install pyyaml --upgrade
    ```

### 2.3 生成专用互信密钥对

在美国端以 root 运行，创建仅用于此订阅链的空密码 SSH 密钥。

> [!WARNING]
> **私钥文件（如 `subpush_key` 和 `submirror_key`）是最高等级的系统访问凭证，绝对不能提交至任何公开或私有的 Git 代码仓库中！本项目的 `.gitignore` 已配置了自动过滤，请在开发时保持警惕！**

在部署时使用 `ssh-keygen` 本地生成：
```bash
# (1) 生成供荷兰向美国推送的密钥
ssh-keygen -t ed25519 -f /opt/clash-sub/scripts/subpush_key -N "" -C "subpush@clash-sub"
# (2) 生成供美国向荷兰同步订阅的密钥
ssh-keygen -t ed25519 -f /opt/clash-sub/scripts/submirror_key -N "" -C "submirror@clash-sub"

# 修正私钥权限至最严的 600，且归属于 subpush (供其运行 SSH 同步)
chown -R subpush:subpush /opt/clash-sub/scripts/
chmod 600 /opt/clash-sub/scripts/*_key
chmod 644 /opt/clash-sub/scripts/*.pub
```

### 2.4 配置 SSH 强制指令过滤器
将 `subpush_key.pub` 写入美国的 `subpush` authorized_keys，并用 wrapper 脚本强行重定向：
```bash
mkdir -p /opt/clash-sub/.ssh
SUBPUSH_PUB=$(cat /opt/clash-sub/scripts/subpush_key.pub)
echo "restrict,no-agent-forwarding,no-port-forwarding,no-X11-forwarding,no-pty,command=\"/opt/clash-sub/scripts/subpush-cmd-wrapper\" $SUBPUSH_PUB" > /opt/clash-sub/.ssh/authorized_keys

# 写入 subpush-cmd-wrapper 脚本到 /opt/clash-sub/scripts/ 下，并 chmod 750
# 修正 SSH 目录所有权与权限
chown -R subpush:subpush /opt/clash-sub/.ssh
chmod 700 /opt/clash-sub/.ssh
chmod 600 /opt/clash-sub/.ssh/authorized_keys
chown root:root /opt/clash-sub
chmod 755 /opt/clash-sub
```

### 2.5 配置 Web 页面与 Nginx 发布
1.  部署 Flask 管理面板到 `/usr/local/vpn-web` 并注册 `clash-subscribe` systemd 服务运行。
2.  生成随机 32 字节 Token 填入 `/opt/clash-sub/scripts/config.env`。
3.  编辑 Nginx 配置文件 `/etc/nginx/sites-enabled/default`，加入 Token 隐藏路径的只读映射。
4.  将 Nginx 的运行组 `www-data` 加入 `subpush` 用户组：
    ```bash
    usermod -aG subpush www-data
    systemctl restart nginx
    ```

---

## 4. 荷兰副服务器手动部署参考步骤

在荷兰端以 `root` 用户身份执行配置：

### 4.1 运行依赖与 Nginx 设置
1.  正常通过脚本运行 Xray，生成 `/var/www/clash/clash.yaml` 节点配置。
2.  安装 Nginx 并在防火墙放行端口：
    ```bash
    apt-get update && apt-get install -y nginx certbot python3-certbot-nginx rsync
    ufw allow "Nginx Full"
    ufw reload
    ```
3.  申请 SSL 证书开启 HTTPS：
    ```bash
    certbot --nginx -d nl-sub.example.com --non-interactive --agree-tos -m admin@nl-sub.example.com
    ```

### 4.2 接收订阅镜像的 submirror 账户配置
1.  创建系统受限用户 `submirror`：
    ```bash
    useradd --system --shell /bin/bash --home-dir /home/submirror --create-home submirror
    ```
2.  将美国主控端生成的 `/opt/clash-sub/scripts/submirror_key.pub`（公钥）写入荷兰副机的 `/home/submirror/.ssh/authorized_keys` 中：
    ```bash
    mkdir -p /home/submirror/.ssh
    echo "restrict,no-agent-forwarding,no-port-forwarding,no-X11-forwarding,no-pty 公钥字符..." > /home/submirror/.ssh/authorized_keys
    chmod 700 /home/submirror/.ssh
    chmod 600 /home/submirror/.ssh/authorized_keys
    chown -R submirror:submirror /home/submirror
    ```

### 4.3 本地只读发布与推送脚本
1.  建立荷兰备用镜像物理目录并赋予 submirror 写入权限：
    ```bash
    mkdir -p /var/www/sub/您的SUB_TOKEN
    chown root:submirror /var/www/sub/您的SUB_TOKEN
    chmod 775 /var/www/sub/您的SUB_TOKEN
    ```
2.  在荷兰 Nginx 中为该 Token 路径配置映射，并重启 Nginx。
3.  从美国拷贝 `/opt/clash-sub/scripts/subpush_key` 私钥到荷兰的 `/opt/clash-sub-mirror/subpush_key`，权限严格为 `600`。
4.  部署荷兰推送上传脚本 `/usr/local/sbin/push-clash-subscription-nl`，执行完成第一次推送合成与回传闭环测试。

---

## 5. Clash Verge / FlClash 导入使用

*   **日常更新**：直接在客户端中使用美国主站连接进行拉取：
    `https://us-sub.example.com/您的SUB_TOKEN/clash.yaml`
*   **手动故障应急**：当美国发生阻断时，在客户端中新增或切换为荷兰的备用链接：
    `https://nl-sub.example.com/您的SUB_TOKEN/clash.yaml`
    *(两份配置完全相同，请注意无需同时启用合并它们，否则会产生同名节点冲突)*。

---

[返回 README](../README.md)
