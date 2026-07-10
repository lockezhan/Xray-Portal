# 🤖 Telegram & QQ 桥接机器人模块 (`tg_bot`)

## 1. 模块用途
本模块主要负责提供 Telegram 机器人的核心服务。主要包括：
*   **TG 消息静默转发机器人 (`tg_bot.py`)**：负责无痕将源群组的消息自动转发到目标频道中。
*   **QQ-TG 桥接网页分享机器人 (`bridge_bot.py`)**：接收来自 QQ 群的分享指令，通过本地 Telegram 接口绕过审查下载多媒体文件，并缓存生成高速 Web 在线播放链接。

---

## 2. 核心文件
*   `tg_bot.py`：消息转发 Bot 的入口逻辑。
*   `bridge_bot.py`：QQ-TG 桥接分享 Bot 的入口逻辑。
*   `fetch_link.py`：负责处理多线程高并发下载 Telegram 防转发限制群组的媒体资源引擎。

---

## 3. 运行依赖
*   Python >= 3.8
*   `telethon` (用于 Userbot 接口)
*   `cryptg` (用于加快媒体解密与下载速度)
*   `requests`
*   `python-dotenv`

安装命令：
```bash
pip install -r requirements.txt
```

---

## 4. 环境变量
本模块直接读取项目根目录下的 `.env`（在生产环境对应 `/usr/local/tg_bot/.env`）配置。主要参数包括：
*   `BRIDGE_BOT_TOKEN`：桥接 Bot 的 Telegram API 凭证。
*   `BRIDGE_TARGET_QQ_GROUP`：需要桥接互通的目标 QQ 群号。
*   `BRIDGE_SERVER_PUBLIC_IP`：美国服务器的公网域名或 IP。
*   `BRIDGE_NAPCAT_API_URL`：本地 NapCat (OneBot) 接口地址。
*   `CHANNEL_BOT_TOKEN`：转发 Bot 的 Telegram API 凭证。
*   `CHANNEL_ADMIN_ID`：Bot 管理员的 Telegram 账户 ID。
*   `CHANNEL_GROUP_ID`：目标 Telegram 频道的 ID。

---

## 5. 启动与服务运行 (Systemd)
本模块在生产环境下托管于 Systemd 服务，由以下两个服务维护：
1.  **`tgbot.service`** (对应消息转发服务)
2.  **`tg-qq-bridge.service`** (对应桥接与分享服务)

启动命令：
```bash
sudo systemctl daemon-reload
sudo systemctl enable --now tgbot tg-qq-bridge
```

---

## 6. 日志监控
通过 journalctl 实时查看服务控制台输出：
```bash
journalctl -u tgbot -f
journalctl -u tg-qq-bridge -f
```

---

## 7. 常见故障与排查
*   **无法下载限制群组中的媒体**：
    *   *现象*：桥接服务报错说没有 `session` 或者是会话已过期。
    *   *排查方式*：在服务运行路径 `/usr/local/tg_bot/` 下，手动使用虚拟环境 Python 运行一次 `fetch_link.py` 或 `login.py` 脚本，重新输入验证码生成并刷新 `telegram_session.session` 文件。
*   **无法将消息发给 QQ 群**：
    *   *现象*：Telegram 收到链接，但 QQ 群没有响应。
    *   *排查方式*：检查 `napcat` Docker 容器是否正常登录，并检查 `BRIDGE_NAPCAT_API_URL` 接口是否畅通（可通过 `curl` 测试 `3000` 端口）。

---

## 8. 与其他模块的关系
*   **Nginx 服务**：桥接 Bot 将媒体资源下载并缓存到 `/var/lib/tg-bridge-cache/` 中。用户点击分享链接时，Nginx 通过 `X-Accel-Redirect` (内部重定向) 直接以零拷贝高速下发这些流媒体文件，不占用 Bot 进程的 CPU/I/O。
