# VPN-Shadowsocks-libev

Ubuntu/Debian 上一键部署 Xray 多端口 Shadowsocks（IPv4/IPv6 分流）脚本与说明，并可生成 Clash Verge 配置。

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
- 一键导出 Clash Verge 配置（`/root/clash-verge.yaml`）

## 新 VPS 使用指南

1. SSH 登录你的 VPS（Debian 11/12 或 Ubuntu 20.04/22.04+），拉取仓库：
   ```bash
   git clone https://github.com/lockezhan/VPN-Shadowsocks-libev.git
   cd VPN-Shadowsocks-libev
   ```

2. 赋予脚本执行权限并运行安装：
   ```bash
   sudo chmod +x install.sh gen_clash_config.sh
   sudo ./install.sh
   ```
   安装过程会提示你：
   - 端口：IPv4/IPv6/传统兼容（默认 20001/20002/20003，可自定义）
   - 密钥：
     - SS-2022：可自动生成 16 字节 base64（推荐），也可手动输入
     - 传统 AES-256-GCM：任意字符串（默认 `TraditionalPassword123`）

3. 安装完成后，检查服务与端口：
   ```bash
   systemctl status xray --no-pager
   ss -tulpn | grep xray
   ```
   你应该能看到 TCP/UDP 监听在 20001、20002、20003。

4. 如需生成 Clash Verge 配置：
   - 在安装脚本尾部选择立即生成，或手动执行：
     ```bash
     sudo ./gen_clash_config.sh
     ```
   - 输出文件位于：
     ```
     /root/clash-verge.yaml
     ```

5. 云厂商安全组
   - 如果你的 VPS 在阿里云 / 腾讯云 / AWS / GCP，请到安全组/防火墙放行 TCP/UDP 的 `20001–20003`。

## Xray 配置文件位置与说明

- 位置：`/usr/local/etc/xray/config.json`
- 结构（安装脚本自动写入，无注释 JSON）：
  - `inbounds`: 分别是 `ss-ipv4`、`ss-ipv6`、`ss-legacy`
  - `outbounds`: `freedom`，`domainStrategy` 为 `UseIP`（根据系统网络选择出站）
- 修改配置后重启：
  ```bash
  sudo systemctl restart xray
  sudo systemctl status xray --no-pager
  ```

## 客户端连接示例

- Windows: v2rayN（6.x+ 支持 SS-2022）
- Android: v2rayNG
- iOS: Shadowrocket

示例（请用你的 VPS 实际 IP/端口/密码替换）：

- 场景 A：IPv4（SS-2022）
  - 服务器：你的 IPv4 地址
  - 端口：20001
  - 加密：`2022-blake3-aes-128-gcm`
  - 密码：安装时生成的 Base64 密钥

- 场景 B：IPv6（SS-2022）
  - 服务器：你的 IPv6 地址
  - 端口：20002
  - 加密：`2022-blake3-aes-128-gcm`
  - 密码：安装时生成的 Base64 密钥

- 场景 C：传统兼容（AES-256-GCM）
  - 服务器：你的 IPv4 地址
  - 端口：20003
  - 加密：`aes-256-gcm`
  - 密码：安装时设置的字符串

## Clash Verge 配置示例（脚本自动生成）

执行 `./gen_clash_config.sh` 后，生成 `/root/clash-verge.yaml`，包含：
- 三个节点：IPv4（SS-2022）、IPv6（SS-2022）、传统 AES-256-GCM
- `Auto-Select` 延迟测试分组、`Proxy` 手动选择分组
- 规则：`edu.cn` 直连、私网直连、其余全代理

可根据需要自行编辑 YAML 内容。

## 安装完成后，如果端口被封或者想完全清理本脚本安装的服务，可以使用管理脚本：

```bash
sudo chmod +x manage_xray.sh

# 交互菜单
sudo ./manage_xray.sh

# 查看当前端口
sudo ./manage_xray.sh show-ports

# 一键更换端口
sudo ./manage_xray.sh change-ports

# 一键彻底卸载（停止 xray 服务、删除配置/日志、清理 UFW 规则、尝试卸载 Xray）
sudo ./manage_xray.sh uninstall
```
##  常用调试

- 查看监听情况：
  ```bash
  ss -tulpn | grep xray
  ```
- 查看日志：
  ```
  /var/log/xray/access.log
  /var/log/xray/error.log
  ```
- 重启服务：
  ```bash
  sudo systemctl restart xray
  ```
- 验证 BBR：
  ```bash
  lsmod | grep bbr
  ```

## 安全建议

- 使用强随机密钥并定期更换。
- 仅开放必要端口，结合云安全组限制来源 IP。
- 保持系统与 Xray-core 最新，及时更新。

## 免责声明

本项目仅用于学习与科研目的。使用时请遵循所在地区法律与服务商政策。
