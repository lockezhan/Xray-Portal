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
*   `BRIDGE_TARGET_QQ_TYPE`：目标类型，`group` 表示 QQ 群，`user` 表示个人私聊；默认 `group`。
*   `BRIDGE_SERVER_PUBLIC_IP`：美国服务器的公网域名或 IP。
*   `BRIDGE_NAPCAT_API_URL`：本地 NapCat (OneBot) 接口地址。
*   `BRIDGE_NAPCAT_TIMEOUT`：等待 NapCat 完成媒体上传的秒数，默认 `300`。
*   `BRIDGE_NAPCAT_MAX_CONCURRENCY`：同时提交给 NapCat 的媒体数，默认 `1`，避免相册并发挤满上传队列。
*   `BRIDGE_NAPCAT_WS_URL`：NapCat 正向 WebSocket 地址，默认 `ws://127.0.0.1:3001`，用于大文件 Stream API。
*   `BRIDGE_NAPCAT_STREAM_THRESHOLD`：启用分块上传的文件大小阈值（字节），默认 `52428800`（50 MiB）。普通上传出现 `rich media transfer failed` 时，小文件也会自动改走 Stream API 重试。
*   `BRIDGE_NAPCAT_STREAM_CHUNK_SIZE`：Stream API 分块大小（字节），默认 `1048576`（1 MiB）。
*   `BRIDGE_MEDIA_GROUP_SETTLE_DELAY`：媒体组最后一个文件完成后，等待多少秒再发送链接和完成提示，默认 `8`。
*   `BRIDGE_FORWARD_MODE`：转发模式，支持 `link`（仅链接）、`file`（仅源文件）、`both`（两者，默认）。旧的 `BRIDGE_FORWARD_FILES=0` 仍兼容为仅链接模式。
*   `BRIDGE_ADMIN_USER_ID`：允许执行运行时切群命令的 Telegram 数字用户 ID；未设置时复用 `CHANNEL_ADMIN_ID`。
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

### 运行时切换 QQ 目标群

配置一次 `BRIDGE_ADMIN_USER_ID` 后，无需修改源代码或重启服务，在桥接 Bot 私聊中发送：

```text
/setgroup 123456789
```

命令会立即切换当前进程的目标群，并同步写回 `.env`，后续重启仍然生效。机器人收到图片、视频或其他文件时，会先直接发送文件，再保留原有的 3 小时网页链接。

切换为个人 QQ 私聊时必须使用 `/setuser`，不能把个人 QQ 号传给 `/setgroup`：

```text
/setuser 123456789
```

`file`/`both` 模式使用 NapCat 的 `upload_group_file` 或 `upload_private_file` 接口发送原文件，不再使用容易出现资源损坏的图片/视频富媒体上传通道。

### 运行时切换转发模式

```text
/setmode link
/setmode file
/setmode both
```

分别表示只发网页链接、只发源文件，以及源文件和网页链接都发送。也支持中文参数 `链接`、`源文件`、`两者`。命令会写回 `.env`，无需重启服务。

---

## 7. 常见故障与排查
*   **无法下载限制群组中的媒体**：
    *   *现象*：桥接服务报错说没有 `session` 或者是会话已过期。
    *   *排查方式*：在服务运行路径 `/usr/local/tg_bot/` 下，手动使用虚拟环境 Python 运行一次 `fetch_link.py` 或 `login.py` 脚本，重新输入验证码生成并刷新 `telegram_session.session` 文件。
*   **Telegram 返回 `file is too big`**：
    *   *原因*：Bridge 回退到了官方 Bot API，受官方文件下载限制影响。
    *   *排查方式*：确认本地 Telegram Bot API 正在 `127.0.0.1:8081` 监听并使用 `--local` 模式；Bridge 启动时会自动检测并切换。本地模式支持无大小限制下载，缓存目录为 `/var/lib/telegram-bot-api/`。
*   **无法将消息发给 QQ 群**：
    *   *现象*：Telegram 收到链接，但 QQ 群没有响应。
    *   *排查方式*：检查 `napcat` Docker 容器是否正常登录，并检查 `BRIDGE_NAPCAT_API_URL` 接口是否畅通（可通过 `curl` 测试 `3000` 端口）。
    *   *大媒体/相册*：50 MiB 以上文件会先经 NapCat WebSocket Stream API 分块上传；更小文件若返回 `rich media transfer failed` 也会自动流式重试。默认最多等待 NapCat 300 秒并串行提交，可通过 `BRIDGE_NAPCAT_*` 参数调整。

---

## 8. 与其他模块的关系
*   **Nginx 服务**：桥接 Bot 将媒体资源下载并缓存到 `/var/lib/tg-bridge-cache/` 中。用户点击分享链接时，Nginx 通过 `X-Accel-Redirect` (内部重定向) 直接以零拷贝高速下发这些流媒体文件，不占用 Bot 进程的 CPU/I/O。
*   **缓存路径**：Bridge 源文件缓存为 `/var/lib/tg-bridge-cache/`；NapCat 容器可见的上传暂存为 `/opt/napcat/qq/bridge-cache/`（容器内对应 `/app/.config/QQ/bridge-cache/`）；本地 Telegram Bot API 数据为 `/var/lib/telegram-bot-api/`。
