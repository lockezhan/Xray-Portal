# VPN-Shadowsocks-libev

Ubuntu/Debian 上一键部署 Xray 多端口 Shadowsocks（IPv4/IPv6 分流）脚本，支持 **Cloudflare 域名** 隐藏裸 IP，并可生成 **Clash 订阅 URL** 直接导入。

> 注意：请确保你的使用符合当地法律法规与 VPS 提供商政策。

## 功能概览

- 基础环境初始化：`apt update/upgrade`，安装 `curl nano ufw openssl jq`，设置时区为 UTC
- 核心安装：通过官方脚本安装最新 `Xray-core`
- 多入站监听：
  - IPv4 专属 SS-2022：默认端口 `20001`
  - IPv6 专属 SS-2022：默认端口 `20002`
  - 传统兼容（AES-256-GCM）：默认端口 `20003`
- 性能优化：写入并启用内核 BBR（`fq` + `bbr`）
- 防火墙：UFW 放行上述端口（TCP/UDP）并启用
- **新** - Cloudflare 域名支持：用子域名替代裸 IP 填充 Clash 配置
- **新** - 一键生成 `ss://` 快速导入链接（v2rayN / Shadowrocket / Clash 扫码导入）
- **新** - Clash 订阅 URL：`http://your.domain:8899/clash.yaml`，可在 Clash Verge 中直接添加订阅

---

## 新 VPS 使用指南

### 1. 安装

```bash
git clone https://github.com/lockezhan/VPN-Shadowsocks-libev.git
cd VPN-Shadowsocks-libev
sudo chmod +x install.sh gen_clash_config.sh serve_clash.sh
sudo ./install.sh
```

安装过程会依次提示：
1. **域名**（可选）：输入已在 Cloudflare 解析到此 VPS 的子域名（如 `vpn.example.com`），留空则使用 IPv4
2. **端口**：IPv4/IPv6/传统兼容（默认 20001/20002/20003）
3. **密钥**：SS-2022 可自动生成；传统 AES-256-GCM 密码任意字符串

安装完成后会自动打印 `ss://` 快速导入链接。

### 2. 关于 Cloudflare 域名的说明

> **重要**：Shadowsocks 不是 HTTP 流量，**Cloudflare 橙云（CDN代理）无法转发**。
> 请将 DNS 记录设为 **灰云（仅 DNS / Proxied: OFF）**，效果是：
> - 配置文件里显示域名而非裸 IP，减少 IP 暴露风险
> - IP 不变，流量依然直连 VPS（与 X-UI 域名方式相同）

如已配置好灰云 A 记录，安装时输入子域名即可，其余步骤完全相同。

### 3. 生成 Clash 订阅 URL

```bash
# 先生成 YAML（脚本会自动从 /etc/xray-meta.conf 读取域名）
sudo ./gen_clash_config.sh

# 启动订阅服务（安装 systemd 服务，开机自启）
sudo ./serve_clash.sh
```

启动后输出：
```
======================================================
 Clash 订阅 URL（复制到 Clash Verge → 订阅）:
   http://vpn.example.com:8899/clash.yaml
======================================================
```

**Clash Verge 导入步骤**：设置 → 订阅 → 新建 → 粘贴 URL → 更新

其他选项：
```bash
sudo ./serve_clash.sh --port 8080       # 自定义端口
sudo ./serve_clash.sh --foreground      # 前台调试模式
sudo ./serve_clash.sh --uninstall       # 卸载服务
```

> 请确保云服务商安全组也放行了订阅端口（默认 TCP 8899）

### 4. ss:// 快速导入链接（无需订阅 URL）

安装完成或运行 `gen_clash_config.sh` 后，终端会打印三条 `ss://` 链接：

```
[IPv4-SS2022 (域名)]
ss://BASE64@vpn.example.com:20001#MyVPS-IPv4
[IPv6-SS2022 (IP)]
ss://BASE64@[::1]:20002#MyVPS-IPv6
[Legacy-AES256 (域名)]
ss://BASE64@vpn.example.com:20003#MyVPS-Legacy
```

复制后可在 v2rayN / Shadowrocket / Clash Verge 中通过「从剪贴板导入」一键添加节点。

### 5. 验证服务

```bash
systemctl status xray --no-pager
ss -tulpn | grep xray        # 应看到 20001, 20002, 20003
```

### 6. 云厂商安全组

放行 TCP/UDP 的 `20001–20003`，以及 TCP `8899`（订阅服务）。

---

## Xray 配置文件

- 位置：`/usr/local/etc/xray/config.json`
- 元数据（域名/端口/密钥）：`/etc/xray-meta.conf`（权限 600）
- 修改后重启：`sudo systemctl restart xray`

---

## 管理脚本

```bash
sudo chmod +x manage_xray.sh

sudo ./manage_xray.sh           # 交互菜单
sudo ./manage_xray.sh show-ports
sudo ./manage_xray.sh change-ports
sudo ./manage_xray.sh uninstall  # 彻底卸载 Xray
```

---

## 常用调试

```bash
ss -tulpn | grep xray
cat /var/log/xray/error.log
sudo systemctl restart xray
lsmod | grep bbr
```

---

## 安全建议

- 使用强随机密钥并定期更换（`manage_xray.sh change-ports` 可同步更换）
- 订阅服务（8899）仅用于下发配置，不承载代理流量，生产环境建议加 HTTPS 或 IP 白名单
- 保持系统与 Xray-core 最新

## 免责声明

本项目仅用于学习与科研目的。使用时请遵循所在地区法律与服务商政策。
