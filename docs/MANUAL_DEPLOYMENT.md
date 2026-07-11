# 手动排障部署指南 (MANUAL_DEPLOYMENT.md)

> [!WARNING]
> 本文档仅用于排障场景。正常情况下请使用 `./deploy/install.sh` 一键部署。
> 手动操作存在出错风险，必须逐步验证每个步骤后再继续。

---

## 前言：何时需要手动部署

以下场景需要手动执行部分步骤：

- `install.sh` 某阶段失败，需要单步重试
- 需要调试特定组件（如只验证 Nginx 配置）
- 服务器已有部分环境，不想全量重装
- 网络问题导致自动下载失败，需要手动传包

---

## 一、安全加载 .env 变量

> [!IMPORTANT]
> **绝对不要** 执行 `source .env` 或 `export $(cat .env)`。正确方式如下：

```bash
# 安全逐行读取（本手册其余步骤的 ENV 变量均通过此方式获取）
_load_env() {
    local file="$1"
    local perm
    perm=$(stat -c "%a" "${file}" 2>/dev/null)
    if [[ "${perm}" != "600" ]]; then
        echo "[ERROR] ${file} 权限 ${perm} 不安全，必须是 600"
        return 1
    fi
    while IFS= read -r line || [[ -n "${line}" ]]; do
        [[ "${line}" =~ ^[[:space:]]*# ]] && continue
        [[ -z "${line// }" ]] && continue
        if [[ "${line}" =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]]; then
            declare -g "${BASH_REMATCH[1]}"="${BASH_REMATCH[2]}"
        fi
    done < "${file}"
}
_load_env .env
```

---

## 二、手动安装 Xray

### 2.1 下载并校验

```bash
XRAY_VERSION="v25.6.3"
XRAY_SHA256="<从 us.env.example 注释中的 SHA256>"
ARCH="linux-64"  # 或 linux-arm64-v8a

TMPDIR=$(mktemp -d)
cd "${TMPDIR}"

# 下载
curl -fL --retry 3 --retry-delay 5 \
    "https://github.com/XTLS/Xray-core/releases/download/${XRAY_VERSION}/Xray-${ARCH}.zip" \
    -o xray.zip

# 校验 SHA256（重要！不通过则停止）
echo "${XRAY_SHA256}  xray.zip" | sha256sum -c -
# 输出应为: xray.zip: OK

unzip xray.zip
sudo install -m 755 xray /usr/local/bin/xray
cd /; rm -rf "${TMPDIR}"
```

### 2.2 生成密钥（幂等）

```bash
PROXY_ENV="/etc/xray-portal/proxy.env"

if [[ ! -f "${PROXY_ENV}" ]]; then
    sudo mkdir -p /etc/xray-portal
    # 生成 AES-128-GCM 密钥（16 字节 base64）
    KEY_V4=$(openssl rand -base64 16)
    KEY_V6=$(openssl rand -base64 16)
    sudo bash -c "cat > '${PROXY_ENV}'" <<EOF
_PROXY_KEY_V4=${KEY_V4}
_PROXY_KEY_V6=${KEY_V6}
EOF
    sudo chmod 600 "${PROXY_ENV}"
    echo "[OK] 密钥已生成并写入 ${PROXY_ENV}（不打印到终端）"
else
    echo "[OK] 密钥文件已存在，复用旧密钥（幂等）"
fi
```

### 2.3 渲染 Xray 配置

```bash
sudo bash apps/vpn_web/proxy/lib/render-xray-config.sh
# 验证
xray run -test -c /usr/local/etc/xray/config.json && echo "配置验证通过"
```

### 2.4 安装 systemd 服务并启动

```bash
# Xray 官方安装脚本已创建 xray.service，若需手动安装：
sudo systemctl daemon-reload
sudo systemctl enable xray
sudo systemctl start xray
systemctl is-active xray && echo "xray running"
```

---

## 三、手动安装 Mihomo

```bash
MIHOMO_VERSION="v1.18.10"
MIHOMO_SHA256="<从 nl.env.example 注释中的 SHA256>"

TMPDIR=$(mktemp -d)
curl -fL --retry 3 \
    "https://github.com/MetaCubeX/mihomo/releases/download/${MIHOMO_VERSION}/mihomo-linux-amd64-${MIHOMO_VERSION}.gz" \
    -o "${TMPDIR}/mihomo.gz"

echo "${MIHOMO_SHA256}  ${TMPDIR}/mihomo.gz" | sha256sum -c -

gunzip "${TMPDIR}/mihomo.gz"
sudo install -m 755 "${TMPDIR}/mihomo" /usr/local/bin/mihomo
rm -rf "${TMPDIR}"

mihomo -v && echo "Mihomo 安装成功"
```

---

## 四、手动配置 UFW 防火墙

> [!CAUTION]
> 必须先放行 SSH（22/tcp），再 enable UFW，否则会锁死连接！

```bash
# 步骤 1：先放行 SSH（不能跳过！）
sudo ufw allow 22/tcp comment 'SSH access'

# 步骤 2：放行代理端口
sudo ufw allow 20001/tcp comment 'Xray SS IPv4'
sudo ufw allow 20001/udp
sudo ufw allow 20002/tcp comment 'Xray SS IPv6'
sudo ufw allow 20002/udp
sudo ufw allow 80/tcp comment 'Nginx HTTP'
sudo ufw allow 443/tcp comment 'Nginx HTTPS'

# 步骤 3：启用（SSH 已放行后才安全）
sudo ufw --force enable
sudo ufw status numbered
```

---

## 五、手动部署 vpn-web Flask 面板

### 5.1 创建服务账户

```bash
sudo useradd -r -s /sbin/nologin -d /usr/local/vpn-web vpn-web 2>/dev/null || true
sudo mkdir -p /usr/local/vpn-web
sudo chown vpn-web:vpn-web /usr/local/vpn-web
```

### 5.2 安装依赖

```bash
sudo python3 -m venv /usr/local/vpn-web/venv
sudo /usr/local/vpn-web/venv/bin/pip install --upgrade pip
sudo /usr/local/vpn-web/venv/bin/pip install -r apps/vpn_web/requirements.txt
# 失败时 exit 1（不允许忽略）
```

### 5.3 复制应用文件

```bash
sudo rsync -a apps/vpn_web/web/ /usr/local/vpn-web/
sudo chown -R vpn-web:vpn-web /usr/local/vpn-web/
```

### 5.4 创建 vpn-web.env

```bash
# 从 .env 中提取面板相关变量（不直接 source）
sudo bash -c "cat > /etc/xray-portal/vpn-web.env" <<EOF
FLASK_SECRET_KEY=${FLASK_SECRET_KEY}
PORTAL_PASSWORD=${PORTAL_PASSWORD}
SUB_TOKEN=${SUB_TOKEN}
FINAL_SUB_URL=http://127.0.0.1/${SUB_TOKEN}/clash.yaml
EOF
sudo chmod 600 /etc/xray-portal/vpn-web.env
sudo chown root:vpn-web /etc/xray-portal/vpn-web.env
```

### 5.5 安装并启动 systemd 服务

```bash
# 从模板渲染服务文件
sudo cp deploy/systemd/vpn-web.service.template \
    /etc/systemd/system/vpn-web.service

sudo systemctl daemon-reload
sudo systemctl enable vpn-web
sudo systemctl start vpn-web

# 验证健康检查
sleep 2
curl -fsS http://127.0.0.1:8080/health && echo "健康检查通过"
```

---

## 六、手动配置 Nginx

### 6.1 安装 Nginx

```bash
sudo apt-get install -y nginx
sudo systemctl enable nginx
```

### 6.2 生成 HTTP（无 TLS）配置

```bash
# 先删除默认站点
sudo rm -f /etc/nginx/sites-enabled/default

# 写入临时 HTTP 配置（TLS 申请前）
sudo tee /etc/nginx/sites-available/xray-portal.conf > /dev/null <<NGINX
server {
    listen 80;
    server_name ${US_SUB_DOMAIN};

    # 订阅路由
    location ~ ^/${SUB_TOKEN}/clash\.yaml$ {
        alias /opt/clash-sub/published/clash.yaml;
        add_header Content-Type "text/plain; charset=utf-8";
        add_header X-Robots-Tag "noindex, nofollow";
    }

    # 无 Token 访问 → 410 Gone
    location /clash.yaml {
        return 410;
    }

    # Web 面板
    location / {
        proxy_pass http://127.0.0.1:8080;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
    }
}
NGINX

sudo ln -sf /etc/nginx/sites-available/xray-portal.conf \
    /etc/nginx/sites-enabled/
sudo nginx -t && sudo nginx -s reload
```

### 6.3 申请 TLS 证书

```bash
# 先验证 HTTP 可达性
curl -fsSL "http://${US_SUB_DOMAIN}/${SUB_TOKEN}/clash.yaml" | head -5

# 申请证书
sudo certbot --nginx -d "${US_SUB_DOMAIN}" \
    --non-interactive --agree-tos \
    -m admin@${US_SUB_DOMAIN}

# 验证 HTTPS
curl -IfsS "https://${US_SUB_DOMAIN}/${SUB_TOKEN}/clash.yaml"
```

### 6.4 重新加载

```bash
sudo nginx -t && sudo nginx -s reload
```

---

## 七、手动生成订阅文件

```bash
# 步骤 1：生成 Clash 源文件
sudo bash apps/vpn_web/proxy/gen_clash_config.sh

# 步骤 2：验证 YAML
python3 -c "import yaml; yaml.safe_load(open('/var/www/clash/clash.yaml'))" && echo "YAML OK"

# 步骤 3：发布（rebuild-clash-subscription 合成最终版本）
sudo /usr/local/sbin/rebuild-clash-subscription

# 步骤 4：Mihomo 内核校验
TESTDIR=$(mktemp -d)
cp /opt/clash-sub/published/clash.yaml "${TESTDIR}/config.yaml"
mihomo -t -d "${TESTDIR}" && echo "Mihomo 校验通过"
rm -rf "${TESTDIR}"
```

---

## 八、单步验证检查清单

每个手动步骤执行后按以下顺序验证：

```
□ xray.service 处于 active (running)
□ ss -tulpn | grep :20001 有输出
□ vpn-web.service 处于 active (running)
□ curl http://127.0.0.1:8080/health 返回 {"status":"ok"}
□ nginx -t 无错误
□ /opt/clash-sub/published/clash.yaml 存在且 YAML 合法
□ curl http://127.0.0.1/<SUB_TOKEN>/clash.yaml 返回 200
□ 无 Token 访问 curl http://127.0.0.1/clash.yaml 返回 410
```

完成所有步骤后运行完整验证：
```bash
sudo ./deploy/verify.sh us --env .env
```
