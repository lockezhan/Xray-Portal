# 💻 代理管理面板与节点安装模块 (`vpn_web`)

## 1. 模块用途
本模块是代理订阅系统的核心控制端，分为两部分：
*   **`proxy/`**：包含底层的 Xray 安装脚本、Shadowsocks 配置自动生成工具、节点部署后的一键服务注册脚本等。
*   **`web/`**：提供基于 Flask 的 Web 管理控制台，允许用户通过网页复制最新的 Clash 客户端合并分流订阅链接，或直接在此下载最新的 Clash/FlClash 客户端安装包。

---

## 2. 核心文件
*   `proxy/install.sh`：自动安装与注册 Xray 网络核心的脚本。
*   `proxy/gen_clash_config.sh`：基于本地已激活的 Shadowsocks 配置自动生成原始本地 Clash 文件的工具。
*   `proxy/serve_clash.sh`：一键全托管 Web 控制台服务（自动将 `web/` 下的前端程序和依赖自动安装部署到系统 `/usr/local/vpn-web` 并注册为守护进程）。
*   `web/app.py`：Flask 控制台的核心启动入口。包含读取统一安全 Token 并向已登录用户提供一键复制 HTTPS 加密 Token 订阅链接的逻辑。
*   `web/utils.py`：后端工具类（爬取 Github 获取客户端最新版本等）。

---

## 3. 运行依赖
*   Python >= 3.8
*   `flask` (核心 Web 框架)
*   `requests`
*   `pyyaml`

---

## 4. 环境变量与安全凭据
*   `PORTAL_PASSWORD`：Web 控制台的管理员登录密码（在 `config.py` 中被读取）。
*   `SUB_TOKEN`：保存在系统统一路径 `/opt/clash-sub/scripts/config.env` 下的高强度安全 Token（用于在首页显示最新的合并订阅地址，杜绝外泄）。

---

## 5. 启动与服务运行
生产环境下由 Systemd 统一看管：
*   **服务名**：`clash-subscribe.service`
*   **启动/重启**：
    ```bash
    sudo systemctl daemon-reload
    sudo systemctl restart clash-subscribe
    ```

---

## 6. 常见故障与排查
*   **面板点击“复制 Clash 订阅”没有拿到最新节点**：
    *   *原因*：美国或荷兰端近期进行了节点更新，但未触发重新构建；或者后台 Python 提取脚本报错。
    *   *排查方式*：检查美国的构建日志 `/opt/clash-sub/logs/rebuild.log` 寻找提取或校验错误。或者手动以 root 执行 `/usr/local/sbin/rebuild-clash-subscription` 强制重新合成。
*   **面板无法启动 (502 / 端口被占用)**：
    *   *排查方式*：查看 Systemd 服务日志 `journalctl -u clash-subscribe -f`。确认 Flask 监听端口（默认 8080）未被其他服务占用。

---

## 7. 与其他模块的关系
*   **订阅合成中心 (`deploy/clash-sub/`)**：Flask 面板通过读取 `config.env` 里的 Token 渲染前台复制按钮，但不参与两端配置的物理提取与合成逻辑。合成工作由系统独立后台定时或钩子触发。
