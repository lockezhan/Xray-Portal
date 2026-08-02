# Xray-Portal

Xray-Portal 是一套自动化部署 Xray 节点工具链，配套有精美的可视化 Web 管理面板的集成解决方案。
它可以为你快速搭建双栈多端口的 `Shadowsocks` (含最新版 SS-2022) 轻量抗墙协议引擎，并提供一个支持密码鉴权、一键配置下发、客户端安装包中转直飞加速的安全落地页。

## 功能特性

- **一键安装**：支持自动安装 Xray 核心、配置 Systemd 服务，并内置国内外流量分流路由。
- **Web 管理面板**：提供基于 Flask 的 Web 界面，支持密码访问限制。
- **订阅管理**：自动生成 `clash.yaml` 订阅文件，支持在面板内直接复制订阅配置。
- **客户端下载**：面板可获取官方客户端安装包（如 Windows 的 `Clash Verge Rev`，Android 的 `FlClash`），通过 VPS 中转，方便直接下载。
- **代理支持**：Web 面板默认使用 80 端口，支持配合 Cloudflare 代理（Proxied 模式）使用以保护服务器真实 IP。

## 🚀 快速启动

本仓库对项目树进行了深度的模块解耦：部署底层代理服务的脚本位于 `proxy/` 目录，管理面板的前端和逻辑存放在 `web/` 目录。
推荐部署环境：**Ubuntu 22.04+ / Debian 11+**

### 1. 部署底层 Xray 代理

```bash
git clone https://github.com/lockezhan/Xray-Portal.git
cd Xray-Portal
cd proxy
sudo chmod +x install.sh gen_clash_config.sh serve_clash.sh manage_xray.sh
sudo ./install.sh
sudo ./gen_clash_config.sh
```
在运行期间，它将交互式引导你输入所需伪装域名。配置生成后系统底层的网络引擎即刻就绪。

### 2. 构建与启动 Web 门户
通过 `serve_clash.sh` 可一键自动创建标准隔离的 Python `venv` 虚拟环境，并注册为开机自启系统服务：

```bash
sudo ./serve_clash.sh
```
执行完成后，终端面板会默认在系统的 **80 端口** 挂起。你可以直接用浏览器通过域名访问体验你的个人私有服务网关。

## 🧹 卸载重装

我们的逻辑内置了彻底卸载方案，不会对服务器造成污染或残留。

```bash
# 卸载 Web 面板防护层服务
sudo ./proxy/serve_clash.sh --uninstall

# 彻底卸载 Xray 原生核心服务
sudo ./proxy/manage_xray.sh
```

## 🌐 Azure IPv6 与网络配置说明

- **Azure VM 私有 IPv6 现象**：Azure VM 内部网卡仅显示私有 IPv6 地址（例如 `fd00:...`），属于 Azure 网络架构设计的正常现象。公网 IPv6 由 Azure 网络层统一管理与 NAT 映射。
- **公网 IPv6 自动探测与手动配置**：
  - `install.sh` 与 `gen_clash_config.sh` 会优先通过 IPv6 出口自动探测公网 IPv6 地址。
  - 若云平台网络映射异常或需固定公网 IPv6，可在 `/etc/xray-meta.conf` 中手动配置：
    ```ini
    PUBLIC_IPV6=<YOUR_PUBLIC_IPV6>
    ```
  - 修改元配置后，运行 `./proxy/gen_clash_config.sh` 或重新运行安装脚本即可自动重构节点订阅。
- **防火墙与安全组要求**：除了在系统内部配置 UFW 规则外，还必须在 **Azure NSG (Network Security Group / 网络安全组)** 中放行相应的 TCP 与 UDP 入站端口。

---
> 纯粹且优美的个人定制化网络体验设施。Xray-Portal
> 个人体验项目，不提供非法服务，请在当地法律允许范围内使用。
