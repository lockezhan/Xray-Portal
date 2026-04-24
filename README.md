# Xray-Portal

Xray-Portal 是一套自动化部署 Xray 节点工具链，配套有精美的可视化 Web 管理面板的集成解决方案。
它可以为你快速搭建 `VLESS-XTLS-Reality` 高抗墙协议引擎，并提供一个支持密码鉴权、一键配置下发、客户端安装包中转直飞加速的安全落地页。

## ✨ 核心特性

- **一键自动化安装**：自动装配最新的 Xray 核心与 Systemd 服务，内置科学的智能路由分流（直连 CN 大陆数据流量）。
- **极客风 Web 管理面板**：附带基于 Flask 构建的轻量化鉴权系统及自动刷新壁纸、时间等组件。
- **配置与订阅分发**：自动生成并在面板中加密挂载 `clash.yaml` 订阅文件，面板内部一键安全复制，不怕泄漏。
- **纯净版客户端资源直连**：面板会自动拉取并筛选指定平台的官方安装包（如 Windows 的 `Clash Verge Rev`，Android 的 `FlClash`），通过 VPS 自动中转直接下载，免翻墙。
- **自适应部署架构**：底层面板默认自动绑定 80 端口，可隐蔽无缝联动 Cloudflare 橙云代理（Proxied）进行访问保护。

## 🚀 快速启动

本仓库对项目树进行了深度的模块解耦：部署底层代理服务的脚本位于 `proxy/` 目录，管理面板的前端和逻辑存放在 `web/` 目录。
推荐部署环境：**Ubuntu 22.04+ / Debian 11+**

### 1. 部署底层 Xray 代理


```bash

git clone https://github.com/lockezhan/Xray-Portal.git
cd proxy
sudo chmod +x install.sh gen_clash_config.sh serve_clash.sh manage_xray.sh
sudo ./install.sh
# 接着运行配置生成脚本
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

---
> 纯粹且优美的个人定制化网络体验设施。Xray-Portal
