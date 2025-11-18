# VPN-Shadowsocks-libev

Ubuntu / Debian 上安装和管理 Shadowsocks-libev 的现代化脚本与说明。

## 简介

本仓库包含一个用于 Debian/Ubuntu 系统的一键安装脚本 `install.sh`，用于通过 apt 安装 shadowsocks-libev、生成默认配置、配置 systemd 服务并在有 ufw 时打开相应端口。脚本也支持一键卸载并清理配置。

> 注意：请确保你的使用符合当地法律法规与 VPS 提供商政策。

## 脚本概览

文件：`install.sh`

主要功能：
- 交互式设置：密码、端口（默认随机 9000–19999）与加密方式（优先推荐 AEAD 算法）
- 生成 `/etc/shadowsocks-libev/config.json`
- 使用 apt 安装 `shadowsocks-libev`（以及 `ufw`，如果未安装会跳过防火墙配置）
- 启用并启动 systemd 服务 `shadowsocks-libev`
- 使用 ufw 打开 Shadowsocks 的 TCP/UDP 端口（如果 ufw 可用）
- 提供卸载选项，清理包与配置并尝试移除 ufw 规则

前提条件：
- 以 root 用户运行（脚本会检测并退出非 root）
- Debian/Ubuntu 系列（依赖 apt）
- 推荐系统：Ubuntu 20.04+ / Debian 10+

## 快速使用

1. 下载或克隆仓库并进入目录：
```bash
git clone https://github.com/lockezhan/VPN-Shadowsocks-libev.git
cd VPN-Shadowsocks-libev
```

2. 审阅 `install.sh`，确认安全后运行（示例）：
```bash
sudo bash install.sh           # 交互式安装（默认动作）
sudo bash install.sh install   # 同上
sudo bash install.sh uninstall # 卸载
```

脚本会提示你输入密码（默认 teddysun.com），随机建议一个端口（可修改），并让你选择加密方法（默认第一个）。

## 生成的配置

脚本会在 `/etc/shadowsocks-libev/config.json` 生成像下面这样的配置：

```json
{
    "server":"0.0.0.0",
    "server_port":8388,
    "password":"your_password_here",
    "timeout":300,
    "method":"chacha20-ietf-poly1305",
    "fast_open":false,
    "mode": "tcp_and_udp"
}
```

修改配置后请重启服务：
```bash
sudo systemctl restart shadowsocks-libev
sudo systemctl status shadowsocks-libev
```

## 防火墙（ufw）

脚本会尝试：
- `ufw allow ssh`
- `ufw allow <port>/tcp`
- `ufw allow <port>/udp`
- 然后自动启用 ufw（回答 "y"）

如果你的服务器使用其他防火墙或管理方式，建议先关闭或调整脚本中的防火墙相关逻辑以避免不必要的访问中断。

## 卸载

运行：
```bash
sudo bash install.sh uninstall
```
脚本会：
- 停止并禁用 systemd 服务
- 用 apt purge 移除 `shadowsocks-libev`
- 删除 `/etc/shadowsocks-libev` 配置目录
- 如果能从配置文件读取到端口，会尝试删除对应的 ufw 规则

## 安全建议

- 使用强随机密码并定期更换。
- 优先选择 AEAD 加密方法（推荐：`chacha20-ietf-poly1305`, `aes-*-gcm`）。
- 仅在需要的情况下开放端口，结合防火墙限制来源 IP。
- 保持系统与 shadowsocks-libev 包更新。

## 常见问题（FAQ）

Q: 脚本提示 “This script must be run as root”？
A: 请以 root 或使用 sudo 运行脚本：`sudo bash install.sh`。

Q: 服务启动失败怎么办？
A: 查看 systemd 日志：`journalctl -u shadowsocks-libev -e`，并检查 `/etc/shadowsocks-libev/config.json` 是否为有效 JSON。

Q: 我想自定义配置（例如改监听地址或启用 fast_open）？
A: 直接编辑 `/etc/shadowsocks-libev/config.json`，然后重启服务：`sudo systemctl restart shadowsocks-libev`。
