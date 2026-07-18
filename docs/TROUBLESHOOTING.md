# 故障排查手册 (TROUBLESHOOTING.md)

## 快速诊断

```bash
# 一键诊断（需要 .env 文件）
sudo ./deploy/verify.sh primary --env .env
# 或
sudo ./deploy/verify.sh secondary --env .env
```

---

## 一、install.sh 失败

### 1.1 env 文件权限不是 0600

```
[ERROR] .env 权限不足（当前: 644），拒绝加载。请执行: chmod 600 .env
```

**修复：**
```bash
chmod 600 .env
```

### 1.2 必填变量为 replace_me

```
[ERROR] 环境变量 PRIMARY_SERVER_IP 未配置（仍为 replace_me）
```

**修复：** 编辑 `.env`，填写所有 `replace_me` 字段。

### 1.3 Xray SHA256 校验失败

```
[ERROR] SHA256 校验失败！下载包可能已损坏或版本/校验和不匹配。
```

**修复：**
```bash
# 获取正确 SHA256
XRAY_VER=v25.6.3
curl -sL "https://github.com/XTLS/Xray-core/releases/download/${XRAY_VER}/Xray-linux-64.zip.sha256sum"
# 将输出的 SHA256 填入 .env 的 XRAY_SHA256_LINUX_AMD64
```

### 1.4 apt 安装失败（网络问题）

```
E: Unable to connect to deb.debian.org
```

**修复：** 配置代理后重试：
```bash
export http_proxy=http://127.0.0.1:7890
export https_proxy=http://127.0.0.1:7890
sudo ./deploy/install.sh primary --env .env
```

---

## 二、Xray 服务问题

### 2.1 xray.service 启动失败

```bash
systemctl status xray
journalctl -u xray -n 50 --no-pager
```

常见原因：
- **端口占用**：`ss -tulpn | grep 20001` 查看是否有其他进程占用代理端口
- **配置语法错误**：`xray run -test -c /usr/local/etc/xray/config.json`
- **密钥格式错误**：检查 `/etc/xray-portal/proxy.env` 中的密钥是否合法

**重新渲染配置：**
```bash
sudo bash apps/vpn_web/proxy/lib/render-xray-config.sh
sudo systemctl restart xray
```

### 2.2 Xray 安装后证书找不到

VLESS Reality 需要指定 SNI，但这不是必须有证书文件的。如果遇到此错误，检查：
```bash
xray run -test -c /usr/local/etc/xray/config.json 2>&1
```

---

## 三、Clash 订阅问题

### 3.1 订阅文件不存在

```bash
# 手动生成
sudo bash apps/vpn_web/proxy/gen_clash_config.sh

# 重建发布版本
sudo /usr/local/sbin/rebuild-clash-subscription
```

### 3.2 Mihomo 校验失败

```
[ERROR] Mihomo -t 检查失败：配置语法不合法
```

```bash
# 在测试目录中排查
TMPDIR=$(mktemp -d)
cp /opt/clash-sub/published/clash.yaml "$TMPDIR/config.yaml"
mihomo -t -d "$TMPDIR"
```

### 3.3 YAML 语法错误

```bash
python3 -c "import yaml; yaml.safe_load(open('/opt/clash-sub/published/clash.yaml'))"
```

### 3.4 GENERAL-PROXY 类型错误

```
[FAIL] GENERAL-PROXY 代理组类型为 fallback
```

检查 `gen_clash_config.sh` 和 `rebuild-clash-subscription.sh` 的组合逻辑。

---

## 四、Nginx 问题

### 4.1 nginx -t 失败

```bash
nginx -t 2>&1
# 查看具体配置文件
cat /etc/nginx/sites-enabled/
```

常见原因：
- SSL 证书文件不存在（Certbot 未申请成功）
- 域名不匹配

### 4.2 502 Bad Gateway

```bash
# 检查后端服务状态
systemctl status vpn-web    # Flask 面板
curl -v http://127.0.0.1:8080/health

# 如果 ENABLE_API=true 但服务未运行
systemctl status api-service  # 修改 .env 将 ENABLE_API=false
sudo nginx -s reload
```

### 4.3 410 Gone（订阅访问拒绝）

```bash
# Token 路径正确但返回 410
# 检查 Nginx 的 map 规则
grep -A5 'map.*valid_token' /etc/nginx/sites-enabled/*.conf
```

### 4.4 TLS 证书申请失败

```bash
# 手动排查 Certbot
certbot certonly --nginx -d primary.example.com --dry-run

# DNS 未就绪时先跳过 TLS
sudo ./deploy/install.sh primary --env .env --no-certbot
# DNS 就绪后再申请证书
sudo certbot --nginx -d primary.example.com
```

---

## 五、Flask Web 面板问题

### 5.1 vpn-web.service 启动失败

```bash
journalctl -u vpn-web -n 100 --no-pager
```

常见原因：
- Python 依赖缺失：`/usr/local/vpn-web/venv/bin/pip install -r requirements.txt`
- 环境文件不存在：`ls -la /etc/xray-portal/vpn-web.env`
- 端口 8080 被占用：`ss -tulpn | grep 8080`

### 5.2 面板登录失败

检查 `PORTAL_PASSWORD` 是否已正确写入服务环境：
```bash
# 不直接打印密码，检查 hash
sudo systemctl cat vpn-web | grep EnvironmentFile
sudo stat /etc/xray-portal/vpn-web.env
```

---

## 六、SSH 互联问题（Secondary→Primary订阅推送）

### 6.1 推送失败：Permission denied

```bash
# 在Secondary机检查私钥权限
ls -la /opt/clash-sub-mirror/subpush_key  # 必须 0600

# 确认交互式 Shell 被拒绝（应返回 Interactive shell access is disabled）
ssh -i /opt/clash-sub-mirror/subpush_key \
    -o StrictHostKeyChecking=no subpush@<PRIMARY_IP>
```

### 6.2 Primary端 authorized_keys 配置

```bash
# Primary机：检查 subpush 用户 authorized_keys
sudo cat /opt/clash-sub/.ssh/authorized_keys
# 应包含 restrict 和 command="/opt/clash-sub/scripts/subpush-cmd-wrapper"
```

### 6.3 手动推送

```bash
# Secondary机
sudo /usr/local/sbin/push-clash-subscription-secondary

# 等价协议（调试用；正常情况请使用上面的推送脚本）
cat /var/www/clash/clash.yaml | \
    ssh -i /opt/clash-sub-mirror/subpush_key \
    subpush@<PRIMARY_IP> upload-secondary
```

---

## 七、UFW 防火墙问题

### 7.1 SSH 被封锁

> [!CAUTION]
> 如果 UFW 已启用且 SSH 被封锁，需要通过 VNC 或控制台登录修复。

```bash
# 控制台登录后
ufw allow 22/tcp
ufw status numbered
```

### 7.2 代理端口未开放

```bash
ufw allow 20001/tcp
ufw allow 20001/udp
ufw allow 20002/tcp comment 'Xray IPv6'
ufw status
```

---

## 八、部署状态检查

```bash
# 查看部署状态记录
cat /var/lib/xray-portal/deployment-state.json

# 检查所有服务
systemctl status xray vpn-web nginx

# 查看开放端口
ss -tulpn | grep -E ':20001|:20002|:80|:443|:8080'
```
