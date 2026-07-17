import os
import uuid
import zipfile
import asyncio
import aiohttp
import mimetypes
import re
import time
from aiohttp import web
import telebot
from telebot.async_telebot import AsyncTeleBot

def load_env():
    # 自动向上查找并加载根目录的 .env 文件
    global ENV_FILE_PATH
    ENV_FILE_PATH = None
    cur_dir = os.path.dirname(os.path.abspath(__file__))
    for _ in range(3):
        env_path = os.path.join(cur_dir, ".env")
        if os.path.exists(env_path):
            ENV_FILE_PATH = env_path
            with open(env_path, "r", encoding="utf-8") as f:
                for line in f:
                    line = line.strip()
                    if not line or line.startswith("#"):
                        continue
                    if "=" in line:
                        key, val = line.split("=", 1)
                        os.environ[key.strip()] = val.strip()
            break
        cur_dir = os.path.dirname(cur_dir)

# 加载环境变量
load_env()

# ================= 配置区域 =================
# Telegram API 配置
BOT_TOKEN = os.environ.get("BRIDGE_BOT_TOKEN")
TARGET_QQ_GROUP_STR = os.environ.get("BRIDGE_TARGET_QQ_GROUP")

if not BOT_TOKEN or BOT_TOKEN == "replace_me" or not TARGET_QQ_GROUP_STR or TARGET_QQ_GROUP_STR == "replace_me":
    print("警告: 桥接机器人配置 (BOT_TOKEN, TARGET_QQ_GROUP_STR) 未配置或为 replace_me 占位符！")
    print("Bridge Bot 暂不激活，将进入待机挂起状态。补齐配置后重启服务即可启用。")
    import time
    while True:
        time.sleep(3600)

# NapCatQQ (OneBot v11) 配置
NAPCAT_API_URL = os.environ.get("BRIDGE_NAPCAT_API_URL", "http://127.0.0.1:3000/send_msg")
NAPCAT_API_BASE = NAPCAT_API_URL.rsplit("/", 1)[0]
NAPCAT_TIMEOUT = float(os.environ.get("BRIDGE_NAPCAT_TIMEOUT", 300))
NAPCAT_MAX_CONCURRENCY = max(1, int(os.environ.get("BRIDGE_NAPCAT_MAX_CONCURRENCY", 1)))
# NTQQ 的普通富媒体上传在大文件/私聊场景下容易返回 rich media transfer failed。
# NapCat v4.8.115+ 提供 WebSocket Stream API；超过阈值的文件先分块上传，再交给 QQ 发送。
NAPCAT_WS_URL = os.environ.get("BRIDGE_NAPCAT_WS_URL", "ws://127.0.0.1:3001")
NAPCAT_WS_TOKEN = os.environ.get("BRIDGE_NAPCAT_WS_TOKEN", "")
NAPCAT_STREAM_THRESHOLD = max(0, int(os.environ.get("BRIDGE_NAPCAT_STREAM_THRESHOLD", str(50 * 1024 * 1024))))
NAPCAT_STREAM_CHUNK_SIZE = max(64 * 1024, int(os.environ.get("BRIDGE_NAPCAT_STREAM_CHUNK_SIZE", str(1024 * 1024))))
MEDIA_GROUP_SETTLE_DELAY = float(os.environ.get("BRIDGE_MEDIA_GROUP_SETTLE_DELAY", 8))
TARGET_QQ_TYPE = os.environ.get("BRIDGE_TARGET_QQ_TYPE", "group").lower()
if TARGET_QQ_TYPE not in {"group", "user"}:
    print(f"警告: BRIDGE_TARGET_QQ_TYPE={TARGET_QQ_TYPE!r} 无效，已回退为 group")
    TARGET_QQ_TYPE = "group"
try:
    TARGET_QQ_GROUP = int(TARGET_QQ_GROUP_STR)
except ValueError:
    raise ValueError("错误: BRIDGE_TARGET_QQ_GROUP 必须为有效的 QQ 群数字！")

# 可选：允许管理员在私聊中运行 /setgroup <群号>，无需重启服务
BRIDGE_ADMIN_USER_ID = os.environ.get("BRIDGE_ADMIN_USER_ID") or os.environ.get("CHANNEL_ADMIN_ID")
try:
    BRIDGE_ADMIN_USER_ID = int(BRIDGE_ADMIN_USER_ID) if BRIDGE_ADMIN_USER_ID else None
except ValueError:
    BRIDGE_ADMIN_USER_ID = None
_legacy_forward_files = os.environ.get("BRIDGE_FORWARD_FILES", "1").lower() not in {"0", "false", "no", "off"}
FORWARD_MODE = os.environ.get("BRIDGE_FORWARD_MODE", "both" if _legacy_forward_files else "link").lower()
if FORWARD_MODE not in {"link", "file", "both"}:
    print(f"警告: BRIDGE_FORWARD_MODE={FORWARD_MODE!r} 无效，已回退为 both")
    FORWARD_MODE = "both"

# 网页服务配置
WEB_HOST = os.environ.get("BRIDGE_WEB_HOST", "127.0.0.1")  # 限制为本地监听，通过 Nginx 8083 端口 HTTPS 代理访问
WEB_PORT = int(os.environ.get("BRIDGE_WEB_PORT", 8082))

# 域名配置 (由于要物理隔离，使用独立端口，不干扰 Nginx 443 主服务)
SERVER_PUBLIC_IP = os.environ.get("BRIDGE_SERVER_PUBLIC_IP")
if not SERVER_PUBLIC_IP:
    raise ValueError("错误: BRIDGE_SERVER_PUBLIC_IP 环境变量未配置！")

def format_view_url(token):
    host = SERVER_PUBLIC_IP.strip().rstrip("/")
    if not host.startswith("http://") and not host.startswith("https://"):
        return f"https://{host}:8083/view?token={token}"
    return f"{host}:8083/view?token={token}"
# ============================================

# 路径配置
CACHE_DIR = "/var/lib/tg-bridge-cache"  # 磁盘缓存目录（/dev/shm 仅 984MB，大文件会撑爆）
NAPCAT_STAGE_DIR = "/opt/napcat/qq/bridge-cache"
NAPCAT_CONTAINER_STAGE_DIR = "/app/.config/QQ/bridge-cache"
try:
    os.makedirs(CACHE_DIR, exist_ok=True)
    os.makedirs(NAPCAT_STAGE_DIR, exist_ok=True)
except PermissionError:
    # 回退到本地开发/测试环境的临时目录，防范非 root 下运行报错
    CACHE_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), ".cache")
    NAPCAT_STAGE_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), ".napcat-stage")
    os.makedirs(CACHE_DIR, exist_ok=True)
    os.makedirs(NAPCAT_STAGE_DIR, exist_ok=True)
COVER_IMAGE_PATH = "/root/wallhaven-gw7wld_2560x1440.png"  # 伪装用的表层图片
# ============================================

# 让 AsyncTeleBot 使用本地的 Telegram Bot API 服务，突破 20MB 下载硬限制到 2000MB (2GB)
# 💡 AsyncTeleBot 走的是 telebot.asyncio_helper 模块（而非 apihelper），
#    其中 API_URL / download_file / get_file_url 全部硬编码了 api.telegram.org。
#    必须对 asyncio_helper 模块进行猴子补丁才能生效。
import socket

def is_port_open(host, port, timeout=1):
    try:
        with socket.create_connection((host, port), timeout=timeout):
            return True
    except OSError:
        return False

# 检查本地的 Telegram Bot API 服务器是否在 8081 端口运行
if is_port_open("127.0.0.1", 8081):
    LOCAL_API_BASE = "http://127.0.0.1:8081"
    USE_LOCAL_API = True
    print("[*] 检测到本地 Telegram Bot API 服务器已启动（8081），使用本地 API 模式。")
else:
    LOCAL_API_BASE = "https://api.telegram.org"
    USE_LOCAL_API = False
    print("[!] 未检测到本地 Telegram Bot API 服务器，已回退使用官方 API 端点。")

from telebot import asyncio_helper

if USE_LOCAL_API:
    # 1. 覆写异步模块的 API_URL，让 getFile 等所有 API 调用走本地
    asyncio_helper.API_URL = f"{LOCAL_API_BASE}/bot{{0}}/{{1}}"

    # 2. 猴子补丁 download_file：支持 --local 模式的本地磁盘直读和本地 HTTP 下载
    _original_async_download = asyncio_helper.download_file

    async def _patched_async_download_file(token, file_path):
        # --local 模式下，file_path 可能是 VPS 本地绝对路径（如 /var/lib/telegram-bot-api/...）
        if os.path.isfile(file_path):
            with open(file_path, 'rb') as f:
                return f.read()
        # 否则走本地 API HTTP 下载
        url = f"{LOCAL_API_BASE}/file/bot{token}/{file_path}"
        async with aiohttp.ClientSession() as session:
            async with session.get(url) as resp:
                if resp.status != 200:
                    raise Exception(f"本地 API 文件下载失败: HTTP {resp.status}")
                return await resp.read()

    asyncio_helper.download_file = _patched_async_download_file

# 初始化 Telebot 客户端 (使用 HTTP 协议，完美避开 MTProto 在 VPS 环境下卡死的问题)
bot = AsyncTeleBot(BOT_TOKEN)
active_tasks = {}
napcat_send_semaphore = asyncio.Semaphore(NAPCAT_MAX_CONCURRENCY)
media_group_states = {}



# --- 1. 纯前端异步渲染的 HTML 模板 (极具科技感与设计美学) ---
HTML_TEMPLATE = """
<!DOCTYPE html>
<html lang="zh-CN">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>安全媒体共享服务</title>
    <link href="https://fonts.googleapis.com/css2?family=Outfit:wght@300;400;600;800&display=swap" rel="stylesheet">
    <style>
        :root {
            --bg-start: #0a0b10;
            --bg-end: #12131e;
            --primary: #6366f1;
            --secondary: #a855f7;
            --text-main: #f3f4f6;
            --text-muted: #9ca3af;
            --glass-bg: rgba(255, 255, 255, 0.03);
            --glass-border: rgba(255, 255, 255, 0.08);
        }

        * { box-sizing: border-box; margin: 0; padding: 0; }

        body {
            background: linear-gradient(135deg, var(--bg-start), var(--bg-end));
            color: var(--text-main);
            font-family: 'Outfit', -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
            display: flex; justify-content: center; align-items: center;
            min-height: 100vh; overflow-x: hidden; position: relative; padding: 20px 0;
        }

        body::before, body::after {
            content: ''; position: fixed; width: 300px; height: 300px;
            border-radius: 50%; filter: blur(150px); z-index: 0; opacity: 0.15; pointer-events: none;
        }
        body::before { background: var(--primary); top: 15%; left: 15%; animation: pulse-slow 10s infinite alternate; }
        body::after { background: var(--secondary); bottom: 15%; right: 15%; animation: pulse-slow 10s infinite alternate-reverse; }
        @keyframes pulse-slow {
            0% { transform: scale(1) translate(0, 0); }
            100% { transform: scale(1.2) translate(30px, -30px); }
        }

        .card {
            background: var(--glass-bg); backdrop-filter: blur(20px); -webkit-backdrop-filter: blur(20px);
            border: 1px solid var(--glass-border); border-radius: 24px; padding: 40px;
            width: 90%; max-width: 600px; text-align: center; box-shadow: 0 20px 50px rgba(0, 0, 0, 0.3); z-index: 1;
        }

        .title { font-size: 24px; font-weight: 800; margin-bottom: 8px; background: linear-gradient(135deg, #fff, var(--text-muted)); -webkit-background-clip: text; -webkit-text-fill-color: transparent; }
        .subtitle { font-size: 14px; color: var(--text-muted); margin-bottom: 30px; }

        .media-container { margin-bottom: 30px; display: flex; flex-direction: column; gap: 20px; align-items: center; min-height: 200px; }
        
        .media-item {
            width: 100%; position: relative; background: rgba(0, 0, 0, 0.2); border: 1px solid rgba(255, 255, 255, 0.05);
            border-radius: 16px; overflow: hidden; display: flex; flex-direction: column; align-items: center; justify-content: center; padding: 10px;
        }

        img, video { max-width: 100%; max-height: 60vh; object-fit: contain; display: block; border-radius: 12px; transition: transform 0.3s ease; }

        .btn {
            display: inline-flex; align-items: center; justify-content: center; padding: 14px 32px;
            font-size: 15px; font-weight: 600; color: #fff; background: linear-gradient(135deg, var(--primary), var(--secondary));
            border: none; border-radius: 14px; cursor: pointer; text-decoration: none; transition: all 0.3s cubic-bezier(0.4, 0, 0.2, 1);
            box-shadow: 0 4px 15px rgba(99, 102, 241, 0.3); width: 100%; margin-top: 10px;
        }
        .btn:hover { transform: translateY(-2px); box-shadow: 0 8px 25px rgba(168, 85, 247, 0.4); filter: brightness(1.1); }
        .btn-icon { margin-right: 8px; font-size: 18px; }

        .loader { border: 3px solid rgba(255, 255, 255, 0.1); border-top: 3px solid var(--primary); border-radius: 50%; width: 40px; height: 40px; animation: spin 1s linear infinite; margin: 50px 0; }
        @keyframes spin { 0% { transform: rotate(0deg); } 100% { transform: rotate(360deg); } }

        .info-badge { display: inline-block; padding: 6px 16px; border-radius: 20px; background: rgba(239, 68, 68, 0.1); border: 1px solid rgba(239, 68, 68, 0.2); color: #ef4444; font-size: 12px; font-weight: 600; margin-top: 20px; }
        .file-icon-wrapper { padding: 40px 20px; text-align: center; }
        .file-icon { font-size: 64px; margin-bottom: 20px; }
        .file-name { font-size: 16px; color: #fff; margin-bottom: 8px; word-break: break-all; }
    </style>
</head>
<body>
    <div class="card">
        <h1 class="title">安全共享媒体</h1>
        <p class="subtitle" id="time-left">剩余保留时间: 计算中...</p>
        
        <div class="media-container" id="media-box">
            <div class="loader" id="loader"></div>
            <p style="color:var(--text-muted)">正在组装多媒体内容...</p>
        </div>
        
        <div id="action-box" style="display: none; margin-top: 20px;">
            <a href="" class="btn" id="download-btn">
                <span class="btn-icon">⬇️</span>打包下载全部到本地
            </a>
        </div>

        <span class="info-badge">🔒 阅后即焚 · 3小时自动销毁</span>
    </div>

    <script>
        const params = new URLSearchParams(window.location.search);
        const token = params.get('token');
        if (!token) {
            document.getElementById('media-box').innerHTML = '<p style="color: #ef4444; font-weight: 600;">❌ 无效的安全凭证 (Token Missing)</p>';
        } else {
            fetch(`/stream?token=${token}&meta=1`)
                .then(res => { if (res.status === 404) throw new Error("文件已销毁或尚未就绪"); return res.json(); })
                .then(data => {
                    const mediaBox = document.getElementById('media-box');
                    const actionBox = document.getElementById('action-box');
                    const downloadBtn = document.getElementById('download-btn');
                    
                    if (data.items && data.items.length > 0) {
                        let html = '';
                        data.items.forEach((item, idx) => {
                            html += '<div class="media-item">';
                            if (item.type.startsWith('video/')) {
                                html += `<video id="media-${idx}" src="/stream?token=${token}&idx=${idx}" controls preload="metadata" playsinline></video>`;
                            } else if (item.type.startsWith('image/')) {
                                html += `<img id="media-${idx}" src="/stream?token=${token}&idx=${idx}" alt="Shared Image">`;
                            } else {
                                html += `<div class="file-icon-wrapper"><span class="file-icon">📁</span><p class="file-name">${item.filename || '未知文件'}</p></div>`;
                            }
                            // 如果是单个文件，显示单独的下载按钮
                            if (data.items.length === 1) {
                                downloadBtn.href = `/download?token=${token}&idx=${idx}`;
                                downloadBtn.innerHTML = '<span class="btn-icon">⬇️</span>立即下载到本地';
                            } else {
                                downloadBtn.href = `/download?token=${token}`; // 后台支持zip打包
                            }
                            html += '</div>';
                        });
                        mediaBox.innerHTML = html;
                        actionBox.style.display = 'block';

                        // 倒计时
                        const firstItem = data.items[0];
                        if (firstItem.expires_at) {
                            const target = firstItem.expires_at * 1000;
                            const timer = setInterval(() => {
                                const remain = target - Date.now();
                                if (remain <= 0) {
                                    clearInterval(timer);
                                    document.getElementById('time-left').innerHTML = '❌ 链接已过期物理销毁';
                                    mediaBox.innerHTML = '<p style="color: #ef4444; font-weight: 600;">❌ 文件已过期物理销毁</p>';
                                    actionBox.style.display = 'none';
                                } else {
                                    const m = Math.floor(remain / 60000);
                                    const s = Math.floor((remain % 60000) / 1000);
                                    document.getElementById('time-left').innerHTML = `⏱️ 剩余保留时间: ${m} 分 ${s} 秒`;
                                }
                            }, 1000);
                        }
                    } else {
                        mediaBox.innerHTML = '<div class="loader"></div><p style="color:var(--text-muted)">正在安全提取处理多媒体文件，请稍后刷新...</p>';
                    }
                })
                .catch(err => {
                    document.getElementById('media-box').innerHTML = `<p style="color: #ef4444; font-weight: 600;">❌ ${err.message}</p>`;
                    document.getElementById('time-left').innerHTML = '❌ 链接已过期或尚未就绪';
                });
        }
    </script>
</body>
</html>
"""

# --- 2. 网页服务端路由处理函数 ---

async def handle_view_page(request):
    return web.Response(text=HTML_TEMPLATE, content_type='text/html')

async def handle_stream(request):
    token = request.query.get("token")
    if not token or token not in active_tasks:
        return web.HTTPNotFound()
        
    items = active_tasks[token]
    
    if request.query.get("meta") == "1":
        res_items = []
        for item in items:
            try:
                expires_at = os.path.getctime(item["path"]) + 10800
            except Exception:
                expires_at = 0
            res_items.append({
                "type": item["type"],
                "filename": item["name"],
                "expires_at": expires_at
            })
        return web.json_response({"items": res_items})

    idx = int(request.query.get("idx", 0))
    if idx < 0 or idx >= len(items):
        return web.HTTPNotFound()
        
    item = items[idx]
    if not os.path.exists(item["path"]):
        return web.HTTPNotFound()
        
    return web.FileResponse(
        item["path"],
        headers={"Content-Type": item["type"]}
    )

async def handle_download(request):
    token = request.query.get("token")
    if not token or token not in active_tasks:
        return web.HTTPNotFound()
    
    items = active_tasks[token]
    if "idx" in request.query:
        idx = int(request.query.get("idx", 0))
        if idx >= 0 and idx < len(items) and os.path.exists(items[idx]["path"]):
            item = items[idx]
            return web.FileResponse(
                item["path"], 
                headers={"Content-Type": item["type"], "Content-Disposition": f'attachment; filename="{item["name"]}"'}
            )
            
    if len(items) > 1:
        zip_path = os.path.join(CACHE_DIR, f"{token}.zip")
        if not os.path.exists(zip_path):
            with zipfile.ZipFile(zip_path, 'w', zipfile.ZIP_DEFLATED) as zipf:
                for item in items:
                    if os.path.exists(item["path"]):
                        zipf.write(item["path"], arcname=item["name"])
        return web.FileResponse(
            zip_path,
            headers={"Content-Type": "application/zip", "Content-Disposition": f'attachment; filename="media_group_{token[:8]}.zip"'}
        )
        
    if len(items) == 1 and os.path.exists(items[0]["path"]):
        item = items[0]
        return web.FileResponse(
            item["path"], 
            headers={"Content-Type": item["type"], "Content-Disposition": f'attachment; filename="{item["name"]}"'}
        )
        
    return web.HTTPNotFound()

# --- 3. 自动物理清理机制 ---

def enforce_cache_size_limit(max_bytes=20 * 1024 * 1024 * 1024):
    """检查缓存目录总大小，超过则按时间顺序删除最旧文件"""
    try:
        files = []
        total_size = 0
        for f in os.listdir(CACHE_DIR):
            fpath = os.path.join(CACHE_DIR, f)
            if os.path.isfile(fpath):
                size = os.path.getsize(fpath)
                mtime = os.path.getmtime(fpath)
                files.append((fpath, size, mtime))
                total_size += size
                
        if total_size > max_bytes:
            print(f"[*] 缓存目录已达到 {total_size / (1024**3):.2f} GB, 超过 20GB, 准备清理最旧文件...")
            # 按修改时间从旧到新排序
            files.sort(key=lambda x: x[2])
            
            for fpath, size, mtime in files:
                try:
                    os.remove(fpath)
                    total_size -= size
                    print(f"[x] 已清理最旧文件释放空间: {fpath} ({size / (1024**2):.2f} MB)")
                    if total_size <= max_bytes * 0.9: # 预留10%的安全余量
                        break
                except Exception as e:
                    print(f"[-] 空间清理失败 {fpath}: {e}")
    except Exception as e:
        print(f"[-] 检查缓存容量失败: {e}")

async def auto_delete_cache(token, delay=10800):
    await asyncio.sleep(delay)
    if token in active_tasks:
        items = active_tasks.pop(token)
        for item in items:
            if os.path.exists(item["path"]):
                try: os.remove(item["path"]); print(f"[x] 已自动清理: {item['path']}")
                except: pass
        zip_path = os.path.join(CACHE_DIR, f"{token}.zip")
        if os.path.exists(zip_path):
            try: os.remove(zip_path)
            except: pass

async def send_to_qq(session, payload, api_url=None):
    try:
        timeout = aiohttp.ClientTimeout(
            total=NAPCAT_TIMEOUT,
            connect=10,
            sock_connect=10,
            sock_read=NAPCAT_TIMEOUT,
        )
        # NapCat/QQ 上传媒体时会一直占用请求；限制并发避免相册把上传队列压满。
        async with napcat_send_semaphore:
            async with session.post(api_url or NAPCAT_API_URL, json=payload, timeout=timeout) as res:
                if res.status != 200:
                    err = f"NapCat HTTP {res.status}"
                    print(f"[-] QQ 转发失败: {err}")
                    return False, err
                try:
                    resp_json = await res.json()
                    status = resp_json.get("status")
                    if status == "ok":
                        return True, None
                    msg = resp_json.get("wording") or resp_json.get("msg") or "未知错误"
                    # NapCat 偶尔在 QQ 已返回成功(result=0)时等不到监听器事件而包装成 Timeout。
                    # 这类响应不能重试，否则会在 QQ 产生重复消息。
                    if ("Timeout:" in msg
                            and re.search(r'"result"\s*:\s*0', msg)
                            and re.search(r'"errMsg"\s*:\s*""', msg)):
                        print("[!] NapCat 返回事件监听假超时，但 QQ result=0，按成功处理。")
                        return True, None
                    print(f"[-] QQ 转发失败: {msg}")
                    return False, f"{msg}"
                except Exception:
                    text = await res.text()
                    err = f"无法解析 NapCat 响应: {text[:100]}"
                    print(f"[-] QQ 转发失败: {err}")
                    return False, err
    except asyncio.TimeoutError:
        err = f"NapCat 处理超过 {NAPCAT_TIMEOUT:g} 秒，消息可能仍在发送，请勿立即重试"
        print(f"[-] QQ 转发超时: {err}")
        return False, err
    except aiohttp.ClientError as e:
        err = f"NapCat 本地接口异常: {type(e).__name__}: {e}"
        print(f"[-] QQ 转发失败: {err}")
        return False, err
    except Exception as e:
        err = f"NapCat 调用异常: {type(e).__name__}: {e}"
        print(f"[-] QQ 转发失败: {err}")
        return False, err


async def upload_file_stream_to_napcat(host_path, filename):
    """通过 NapCat Stream API 分块上传文件，返回 NapCat 可见的文件路径。"""
    try:
        import websockets
    except ImportError as e:
        raise RuntimeError("缺少 websockets 依赖，无法启用 NapCat 大文件流式上传") from e

    file_size = os.path.getsize(host_path)
    if file_size <= 0:
        raise ValueError("待上传文件为空")
    chunk_size = NAPCAT_STREAM_CHUNK_SIZE
    total_chunks = (file_size + chunk_size - 1) // chunk_size
    sha256 = __import__("hashlib").sha256()
    with open(host_path, "rb") as source:
        while True:
            chunk = source.read(chunk_size)
            if not chunk:
                break
            sha256.update(chunk)
    expected_sha256 = sha256.hexdigest()
    stream_id = uuid.uuid4().hex

    connect_kwargs = {}
    if NAPCAT_WS_TOKEN:
        connect_kwargs["additional_headers"] = {"Authorization": f"Bearer {NAPCAT_WS_TOKEN}"}
    try:
        websocket = await websockets.connect(NAPCAT_WS_URL, **connect_kwargs)
    except TypeError:
        # websockets 10/11 使用 extra_headers，兼容旧版运行环境。
        if NAPCAT_WS_TOKEN:
            connect_kwargs = {"extra_headers": {"Authorization": f"Bearer {NAPCAT_WS_TOKEN}"}}
        websocket = await websockets.connect(NAPCAT_WS_URL, **connect_kwargs)

    async with websocket:
        async def action(params):
            echo = uuid.uuid4().hex
            await websocket.send(__import__("json").dumps({
                "action": "upload_file_stream", "params": params, "echo": echo
            }))
            while True:
                response = __import__("json").loads(await websocket.recv())
                if response.get("echo") == echo:
                    if response.get("status") != "ok":
                        raise RuntimeError(response.get("wording") or response.get("message") or str(response))
                    return response

        with open(host_path, "rb") as source:
            for chunk_index in range(total_chunks):
                chunk = source.read(chunk_size)
                params = {
                    "stream_id": stream_id,
                    "chunk_data": __import__("base64").b64encode(chunk).decode("ascii"),
                    "chunk_index": chunk_index,
                    "total_chunks": total_chunks,
                    "file_size": file_size,
                    "expected_sha256": expected_sha256,
                    "filename": os.path.basename(filename) or "file",
                    "file_retention": 60 * 60 * 1000,
                }
                await action(params)
        response = await action({"stream_id": stream_id, "is_complete": True})
        data = response.get("data") or {}
        if data.get("status") != "file_complete" or not data.get("file_path"):
            raise RuntimeError(f"NapCat 流式上传完成响应异常: {response}")
        return data["file_path"]


def qq_target_payload():
    """返回与当前目标类型对应的 OneBot 目标字段。"""
    key = "user_id" if TARGET_QQ_TYPE == "user" else "group_id"
    return {key: str(TARGET_QQ_GROUP)}


def stage_file_for_napcat(source_path, token, idx, filename):
    """将文件硬链接/复制到 NapCat 容器可见目录，避免 HTTP 临时资源失效。"""
    import shutil
    safe_name = os.path.basename(filename) or f"file_{idx}"
    staged_name = f"{token}_{idx}_{safe_name}"
    host_path = os.path.join(NAPCAT_STAGE_DIR, staged_name)
    container_path = os.path.join(NAPCAT_CONTAINER_STAGE_DIR, staged_name)
    if not os.path.isfile(source_path) or os.path.getsize(source_path) <= 0:
        raise FileNotFoundError(f"待转发源文件不存在或为空: {source_path}")
    try:
        if os.path.exists(host_path):
            os.remove(host_path)
        os.link(source_path, host_path)
    except OSError:
        shutil.copyfile(source_path, host_path)
    os.chmod(host_path, 0o644)
    return host_path, container_path


async def delayed_remove(path, delay=3600):
    await asyncio.sleep(delay)
    try:
        if os.path.exists(path):
            os.remove(path)
    except Exception as e:
        print(f"[-] 清理 NapCat 暂存文件失败 {path}: {e}")


async def send_file_to_qq(session, token, idx, source_path, content_type, filename):
    """通过 NapCat 文件 API 或 CQ 码发送原文件及音视频图像；大文件先走 Stream API 分块上传。"""
    if FORWARD_MODE not in {"file", "both"}:
        return True, None
    try:
        staged_host_path, staged_container_path = stage_file_for_napcat(
            source_path, token, idx, filename
        )
    except Exception as e:
        return False, str(e)

    action = "upload_private_file" if TARGET_QQ_TYPE == "user" else "upload_group_file"
    msg_action = "send_private_msg" if TARGET_QQ_TYPE == "user" else "send_group_msg"
    safe_filename = os.path.basename(filename) or f"file_{idx}"
    file_size = os.path.getsize(staged_host_path)

    is_video = safe_filename.lower().endswith(('.mp4', '.mov', '.avi', '.mkv', '.webm')) or (content_type and content_type.startswith('video/'))
    is_image = safe_filename.lower().endswith(('.jpg', '.jpeg', '.png', '.gif', '.webp', '.bmp')) or (content_type and content_type.startswith('image/'))
    is_audio = safe_filename.lower().endswith(('.mp3', '.ogg', '.wav', '.flac', '.m4a', '.aac')) or (content_type and content_type.startswith('audio/'))

    async def send_path(file_path):
        file_url = file_path if file_path.startswith("file://") else f"file://{file_path}"

        # 1. 视频优先使用 [CQ:video] 直接发送
        # NTQQ 在 Linux Docker 下调用 upload_group_file 上传视频(.mp4)会稳定触发 rich media transfer failed，
        # 因此对视频资源优先由 CQ 码视频通道直发。
        if is_video:
            msg_payload = {
                **qq_target_payload(),
                "message": f"[CQ:video,file={file_url}]"
            }
            res = await send_to_qq(session, msg_payload, f"{NAPCAT_API_BASE}/{msg_action}")
            if res[0]:
                return res
            # 若 CQ:video 异常，极速回退到普通 CQ:file 与 upload_group_file
            msg_payload["message"] = f"[CQ:file,file={file_url}]"
            res = await send_to_qq(session, msg_payload, f"{NAPCAT_API_BASE}/{msg_action}")
            if res[0]:
                return res
            payload = {
                **qq_target_payload(),
                "file": file_path,
                "name": safe_filename,
                "upload_file": True,
            }
            return await send_to_qq(session, payload, f"{NAPCAT_API_BASE}/{action}")

        # 2. 图片优先使用 [CQ:image] 发送
        if is_image:
            msg_payload = {
                **qq_target_payload(),
                "message": f"[CQ:image,file={file_url}]"
            }
            res = await send_to_qq(session, msg_payload, f"{NAPCAT_API_BASE}/{msg_action}")
            if res[0]:
                return res

        # 3. 语音优先使用 [CQ:record] 发送
        if is_audio:
            msg_payload = {
                **qq_target_payload(),
                "message": f"[CQ:record,file={file_url}]"
            }
            res = await send_to_qq(session, msg_payload, f"{NAPCAT_API_BASE}/{msg_action}")
            if res[0]:
                return res

        # 4. 普通文件或图音回退：使用 upload_group_file / upload_private_file
        payload = {
            **qq_target_payload(),
            "file": file_path,
            "name": safe_filename,
            "upload_file": True,
        }
        res = await send_to_qq(session, payload, f"{NAPCAT_API_BASE}/{action}")
        if not res[0] and "rich media transfer failed" in (res[1] or "").lower():
            print(f"[!] /upload_group_file 返回 rich media transfer failed，改用 CQ 码 ({msg_action}) 极速回退发送: {safe_filename}")
            msg_payload = {
                **qq_target_payload(),
                "message": f"[CQ:file,file={file_url}]"
            }
            res = await send_to_qq(session, msg_payload, f"{NAPCAT_API_BASE}/{msg_action}")
        return res

    try:
        # 由于宿主机 /opt/napcat/qq 已挂载为容器内 /app/.config/QQ 目录，staged_container_path 在容器中原生可用且带完整扩展名。
        # 优先对 staged_container_path 进行直接发送，实现零拷贝并保留准确扩展名。
        result = await send_path(staged_container_path)
        if result[0]:
            return result

        # 只有直发失败且满足分块阈值或报 rich media transfer failed 时，才改用 Stream API 重试
        if (NAPCAT_STREAM_THRESHOLD and file_size >= NAPCAT_STREAM_THRESHOLD) or ("rich media transfer failed" in (result[1] or "").lower()):
            print(f"[*] 准备使用 NapCat Stream API 分块后重试: {safe_filename}")
            streamed_path = await upload_file_stream_to_napcat(staged_host_path, safe_filename)
            return await send_path(streamed_path)

        return result
    except Exception as e:
        err = f"NapCat 发送或流式处理失败: {type(e).__name__}: {e}"
        print(f"[-] {err}")
        return False, err
    finally:
        # NapCat/NTQQ 某些版本返回后仍异步读取，保留一小时避免文件被清理导致读取失败。
        asyncio.create_task(delayed_remove(staged_host_path, delay=3600))


async def send_link_to_qq(session, text):
    """按当前模式发送网页链接。"""
    if FORWARD_MODE not in {"link", "both"}:
        return True, None
    return await send_to_qq(session, {**qq_target_payload(), "message": text})


def persist_env_value(key, value):
    """更新当前 .env 中的一个配置项。"""
    env_path = ENV_FILE_PATH or os.path.join(os.path.dirname(os.path.abspath(__file__)), ".env")
    lines = []
    if os.path.exists(env_path):
        with open(env_path, "r", encoding="utf-8") as f:
            lines = f.readlines()
    prefix = f"{key}="
    for i, line in enumerate(lines):
        if line.lstrip().startswith(prefix):
            lines[i] = f"{key}={value}\n"
            break
    else:
        lines.append(f"{key}={value}\n")
    with open(env_path, "w", encoding="utf-8") as f:
        f.writelines(lines)


def persist_qq_target(target_type, target_id):
    """切换 QQ 群/私聊目标并写回 .env。BRIDGE_TARGET_QQ_GROUP 保留作兼容 ID。"""
    global TARGET_QQ_GROUP, TARGET_QQ_GROUP_STR, TARGET_QQ_TYPE
    TARGET_QQ_GROUP = int(target_id)
    TARGET_QQ_GROUP_STR = str(target_id)
    TARGET_QQ_TYPE = target_type
    persist_env_value("BRIDGE_TARGET_QQ_GROUP", target_id)
    persist_env_value("BRIDGE_TARGET_QQ_TYPE", target_type)


def persist_forward_mode(mode):
    """立即切换转发模式并持久化。"""
    global FORWARD_MODE
    FORWARD_MODE = mode
    persist_env_value("BRIDGE_FORWARD_MODE", mode)


def forward_success_text():
    return {
        "link": "✅ 网页链接已转发至 QQ。",
        "file": "✅ 源文件已转发至 QQ。",
        "both": "✅ 源文件和网页链接已转发至 QQ。",
    }[FORWARD_MODE]


async def finalize_media_group(token, state):
    """媒体组最后一个成员完成后，再统一发送链接和最终状态。"""
    await asyncio.sleep(MEDIA_GROUP_SETTLE_DELAY)
    if state["pending"] > 0:
        # 仍有成员在下载/上传，等它们在 finally 中重新安排收尾。
        return
    items = active_tasks.get(token, [])
    if not items:
        if state.get("status_msg"):
            try:
                await bot.edit_message_text("❌ 媒体组没有成功下载任何文件。", chat_id=state["chat_id"], message_id=state["status_msg"].message_id)
            except Exception:
                pass
        return

    qq_ok, qq_err = True, None
    if FORWARD_MODE in {"link", "both"}:
        async with aiohttp.ClientSession() as session:
            qq_ok, qq_err = await send_link_to_qq(
                session,
                f"🔑 收到加密媒体组（共 {len(items)} 个文件，3小时内复制打开）：\n{format_view_url(token)}",
            )
    errors = [*state.get("errors", [])]
    if qq_err:
        errors.append(qq_err)
    if state.get("status_msg"):
        try:
            if errors or not qq_ok:
                text = f"⚠️ 媒体组转发完成但有失败项: {'; '.join(errors)}"
            else:
                text = forward_success_text()
                text = f"{text}（共 {len(items)} 个文件）"
            await bot.edit_message_text(text, chat_id=state["chat_id"], message_id=state["status_msg"].message_id)
        except Exception:
            pass


def schedule_media_group_finalize(token, state):
    previous = state.get("finalize_task")
    if previous and not previous.done():
        previous.cancel()
    state["finalize_task"] = asyncio.create_task(finalize_media_group(token, state))


# --- 4. TG 消息回调函数 ---

@bot.message_handler(func=lambda message: message.chat.type == 'private', 
                     content_types=['photo', 'video', 'document', 'audio', 'voice', 'animation'])
async def handle_media_message(message):
    group_id = message.media_group_id
    token = f"g{group_id}" if group_id else uuid.uuid4().hex
    
    file_id = None
    ext = ""
    content_type = "application/octet-stream"
    filename = f"media_{message.message_id}"
    
    if message.photo:
        file_id = message.photo[-1].file_id; ext = ".jpg"; content_type = "image/jpeg"; filename = f"photo_{message.message_id}.jpg"
    elif message.video:
        file_id = message.video.file_id; ext = ".mp4"; content_type = "video/mp4"; filename = message.video.file_name or f"video_{message.message_id}.mp4"
    elif message.document:
        file_id = message.document.file_id; filename = message.document.file_name or f"file_{message.message_id}"; ext = os.path.splitext(filename)[1]; content_type = message.document.mime_type or "application/octet-stream"
    elif message.audio:
        file_id = message.audio.file_id; filename = message.audio.file_name or f"audio_{message.message_id}.mp3"; ext = os.path.splitext(filename)[1] or ".mp3"; content_type = message.audio.mime_type or "audio/mpeg"
    elif message.voice:
        file_id = message.voice.file_id; ext = ".ogg"; content_type = "audio/ogg"; filename = f"voice_{message.message_id}.ogg"
    elif message.animation:
        file_id = message.animation.file_id; ext = ".mp4"; content_type = "video/mp4"; filename = message.animation.file_name or f"animation_{message.message_id}.mp4"

    if not file_id: return
        
    local_file_path = os.path.join(CACHE_DIR, f"{token}_{message.message_id}{ext}")
    
    is_media_group = bool(group_id)
    group_state = None
    is_first = False
    status_msg = None
    if is_media_group:
        if token not in active_tasks:
            active_tasks[token] = []
            asyncio.create_task(auto_delete_cache(token, delay=10800))
            media_group_states[token] = {
                "pending": 0,
                "errors": [],
                "status_msg": None,
                "status_requested": False,
                "chat_id": message.chat.id,
                "finalize_task": None,
            }
        group_state = media_group_states[token]
        group_state["pending"] += 1
        is_first = not group_state["status_requested"]
        if is_first:
            group_state["status_requested"] = True
            status_msg = await bot.reply_to(message, "⏳ 正在提取媒体组，请稍候...")
            group_state["status_msg"] = status_msg
            enforce_cache_size_limit()
    else:
        if token not in active_tasks:
            active_tasks[token] = []
            is_first = True
            asyncio.create_task(auto_delete_cache(token, delay=10800))
        if is_first:
            status_msg = await bot.reply_to(message, "⏳ 正在提取多媒体流，请稍候...")
            enforce_cache_size_limit()
    
    try:
        file_info = await bot.get_file(file_id)
        file_path_on_disk = file_info.file_path
        
        # 判断是否为本地绝对路径，若是且存在，则直接用 link 或 copyfile 提速并避免内存占用过高
        if os.path.isabs(file_path_on_disk) and os.path.exists(file_path_on_disk):
            try:
                # 尝试硬链接（零拷贝，且不占双倍磁盘空间）
                if os.path.exists(local_file_path):
                    os.remove(local_file_path)
                os.link(file_path_on_disk, local_file_path)
                print(f"[*] 本地文件硬链接成功: {file_path_on_disk} -> {local_file_path}")
            except Exception as link_err:
                # 若跨分区则进行文件复制
                import shutil
                print(f"[*] 本地文件硬链接失败 ({link_err})，尝试流式复制...")
                await asyncio.to_thread(shutil.copyfile, file_path_on_disk, local_file_path)
                print(f"[*] 本地文件流式复制成功: {file_path_on_disk} -> {local_file_path}")
        else:
            # 否则，走本地 API HTTP 流式下载，防止一次性读入大文件导致 OOM
            url = f"{LOCAL_API_BASE}/file/bot{BOT_TOKEN}/{file_path_on_disk}"
            print(f"[*] 准备从本地 API HTTP 下载: {url} -> {local_file_path}")
            async with aiohttp.ClientSession() as session:
                async with session.get(url) as resp:
                    if resp.status != 200:
                        raise Exception(f"本地 API 文件下载失败: HTTP {resp.status}")
                    with open(local_file_path, "wb") as f:
                        while True:
                            chunk = await resp.content.read(1024 * 1024)  # 1MB
                            if not chunk:
                                break
                            f.write(chunk)
            print(f"[*] 本地 API HTTP 流式下载完成: {local_file_path}")
            
        # 统一设置文件权限为 644，确保 Nginx 可读，实现顺利播放/下载
        try:
            os.chmod(local_file_path, 0o644)
            print(f"[*] 成功修改文件权限为 644: {local_file_path}")
        except Exception as chmod_err:
            print(f"[-] 修改文件权限失败: {chmod_err}")

        # 记录当前文件自己的固定索引；媒体组处理并发时不能事后取列表末尾。
        item_idx = len(active_tasks[token])
        active_tasks[token].append({"path": local_file_path, "type": content_type, "name": filename})
        
        if is_media_group:
            async with aiohttp.ClientSession() as session:
                file_ok, file_err = await send_file_to_qq(
                    session, token, item_idx, local_file_path, content_type, filename
                )
            if not file_ok and file_err:
                group_state["errors"].append(f"{filename}: {file_err}")
        elif is_first:
            view_url = format_view_url(token)
            async with aiohttp.ClientSession() as session:
                file_ok, file_err = await send_file_to_qq(
                    session, token, item_idx, local_file_path, content_type, filename
                )
                qq_ok, qq_err = await send_link_to_qq(session, f"🔑 收到加密媒体(支持多图/视频组)（3小时内复制打开）：\n{view_url}")
                
            await asyncio.sleep(2.5)
            if qq_ok and file_ok:
                await bot.edit_message_text(forward_success_text(), chat_id=message.chat.id, message_id=status_msg.message_id)
            else:
                errors = "; ".join(x for x in (qq_err, file_err) if x)
                await bot.edit_message_text(f"⚠️ 转发 QQ 失败: {errors}", chat_id=message.chat.id, message_id=status_msg.message_id)
        else:
            async with aiohttp.ClientSession() as session:
                await send_file_to_qq(
                    session, token, item_idx, local_file_path, content_type, filename
                )
        
        try: await bot.delete_message(message.chat.id, message.message_id)
        except: pass
            
    except Exception as e:
        print(f"[-] 提取媒体失败: {e}")
        if os.path.exists(local_file_path): os.remove(local_file_path)
        if group_state is not None:
            group_state["errors"].append(f"{filename}: {e}")
        if not is_media_group and is_first and status_msg:
            await bot.edit_message_text(f"❌ 提取失败: {e}", chat_id=message.chat.id, message_id=status_msg.message_id)
    finally:
        if group_state is not None:
            group_state["pending"] = max(0, group_state["pending"] - 1)
            schedule_media_group_finalize(token, group_state)

@bot.message_handler(func=lambda message: message.chat.type == 'private', content_types=['text'])
async def handle_text_message(message):
    text = message.text or ""
    command = text.strip().split()
    if command and command[0].lower() in {"/setgroup", "/set_group"}:
        if BRIDGE_ADMIN_USER_ID is None or message.from_user.id != BRIDGE_ADMIN_USER_ID:
            await bot.reply_to(message, "❌ 未授权。请配置 BRIDGE_ADMIN_USER_ID 后使用此命令。")
            return
        if len(command) != 2 or not command[1].isdigit():
            await bot.reply_to(message, "用法：/setgroup 群号")
            return
        try:
            persist_qq_target("group", int(command[1]))
            await bot.reply_to(message, f"✅ 转发目标群已切换为 {TARGET_QQ_GROUP}（已写入 .env，无需重启）。")
        except Exception as e:
            await bot.reply_to(message, f"❌ 保存目标群失败: {e}")
        return
    if command and command[0].lower() in {"/setuser", "/set_user"}:
        if BRIDGE_ADMIN_USER_ID is None or message.from_user.id != BRIDGE_ADMIN_USER_ID:
            await bot.reply_to(message, "❌ 未授权。请配置 BRIDGE_ADMIN_USER_ID 后使用此命令。")
            return
        if len(command) != 2 or not command[1].isdigit():
            await bot.reply_to(message, "用法：/setuser 对方QQ号")
            return
        try:
            persist_qq_target("user", int(command[1]))
            await bot.reply_to(message, f"✅ 转发目标已切换为 QQ 私聊 {TARGET_QQ_GROUP}（已写入 .env，无需重启）。")
        except Exception as e:
            await bot.reply_to(message, f"❌ 保存私聊目标失败: {e}")
        return
    if command and command[0].lower() in {"/setmode", "/set_mode"}:
        if BRIDGE_ADMIN_USER_ID is None or message.from_user.id != BRIDGE_ADMIN_USER_ID:
            await bot.reply_to(message, "❌ 未授权。请配置 BRIDGE_ADMIN_USER_ID 后使用此命令。")
            return
        aliases = {
            "link": "link", "链接": "link",
            "file": "file", "source": "file", "源文件": "file", "文件": "file",
            "both": "both", "all": "both", "全部": "both", "两者": "both",
        }
        mode = aliases.get(command[1].lower()) if len(command) == 2 else None
        if not mode:
            await bot.reply_to(message, "用法：/setmode link|file|both（链接 / 源文件 / 两者）")
            return
        try:
            persist_forward_mode(mode)
            labels = {"link": "仅链接", "file": "仅源文件", "both": "链接 + 源文件"}
            await bot.reply_to(message, f"✅ 转发模式已切换为：{labels[mode]}（已写入 .env，无需重启）。")
        except Exception as e:
            await bot.reply_to(message, f"❌ 保存转发模式失败: {e}")
        return
    import re
    import json
    urls = re.findall(r'(https?://\S+)', text)
    if not urls: return
        
    url = urls[0]
    status_msg = await bot.reply_to(message, "⏳ 正在安全下载链接指向的文件，请稍候...")
    token = uuid.uuid4().hex
    
    # 提取前先检查缓存目录大小限制
    enforce_cache_size_limit()
    
    if "t.me/" in url:
        # 使用 Userbot 下载
        try:
            import subprocess
            import sys
            fetch_script = os.path.join(os.path.dirname(os.path.abspath(__file__)), "fetch_link.py")
            process = await asyncio.create_subprocess_exec(
                sys.executable, fetch_script, url,
                stdout=subprocess.PIPE, stderr=subprocess.PIPE
            )
            stdout, stderr = await process.communicate()
            if process.returncode != 0:
                await bot.edit_message_text(f"❌ 下载脚本执行失败: {stderr.decode('utf-8')[:100]}", chat_id=message.chat.id, message_id=status_msg.message_id)
                return
            
            try:
                result = json.loads(stdout.decode('utf-8'))
            except Exception as e:
                await bot.edit_message_text(f"❌ 解析下载结果失败: {stdout.decode('utf-8')[:100]}", chat_id=message.chat.id, message_id=status_msg.message_id)
                return
                
            if "error" in result:
                await bot.edit_message_text(f"❌ 链接解析/下载失败: {result['error']}", chat_id=message.chat.id, message_id=status_msg.message_id)
                return
            
            files = result.get("files", [])
            if not files:
                await bot.edit_message_text(f"❌ 未找到可下载的文件", chat_id=message.chat.id, message_id=status_msg.message_id)
                return
                
            active_tasks[token] = files

            view_url = format_view_url(token)
            async with aiohttp.ClientSession() as session:
                file_results = [
                    await send_file_to_qq(
                        session, token, idx, item["path"],
                        item.get("type", "application/octet-stream"), item.get("name", "file")
                    )
                    for idx, item in enumerate(files)
                ]
                qq_ok, qq_err = await send_link_to_qq(session, f"🔑 收到加密网页下载链接（3小时内复制打开）：\n{view_url}")
                
            await asyncio.sleep(2.5)
            file_errors = [err for ok, err in file_results if not ok and err]
            if qq_ok and not file_errors:
                await bot.edit_message_text(forward_success_text(), chat_id=message.chat.id, message_id=status_msg.message_id)
            else:
                errors = "; ".join(([qq_err] if qq_err else []) + file_errors)
                await bot.edit_message_text(f"⚠️ 转发 QQ 失败: {errors}", chat_id=message.chat.id, message_id=status_msg.message_id)
                
            asyncio.create_task(auto_delete_cache(token, delay=10800))
            
        except Exception as e:
            print(f"[-] 下载 Telegram 链接失败: {e}")
            await bot.edit_message_text(f"❌ 下载 Telegram 链接失败: {e}", chat_id=message.chat.id, message_id=status_msg.message_id)
    else:
        # 普通 HTTP 下载
        try:
            async with aiohttp.ClientSession() as session:
                async with session.get(url, allow_redirects=True, timeout=300) as resp:
                    if resp.status != 200:
                        await bot.edit_message_text(f"❌ 下载失败，服务器响应状态码: {resp.status}", chat_id=message.chat.id, message_id=status_msg.message_id)
                        return
                    content_type = resp.headers.get("Content-Type", "application/octet-stream")
                    filename = None
                    content_disposition = resp.headers.get("Content-Disposition", "")
                    if "filename=" in content_disposition:
                        parts = content_disposition.split("filename=")
                        if len(parts) > 1: filename = parts[1].strip("\"'")
                    if not filename:
                        from urllib.parse import urlparse
                        filename = os.path.basename(urlparse(url).path)
                    if not filename: filename = f"download_{token[:8]}"
                    filename = os.path.basename(filename.strip())
                    ext = os.path.splitext(filename)[1]
                    if not ext:
                        ext = mimetypes.guess_extension(content_type) or ""
                        if ext: filename += ext
                            
                    local_file_path = os.path.join(CACHE_DIR, f"{token}{ext}")
                    with open(local_file_path, "wb") as f:
                        while True:
                            chunk = await resp.content.read(1024 * 1024)
                            if not chunk: break
                            f.write(chunk)
                            
            # 统一设置文件权限为 644，确保 Nginx 可读，实现顺利播放/下载
            try:
                os.chmod(local_file_path, 0o644)
                print(f"[*] 成功修改普通 HTTP 下载文件权限为 644: {local_file_path}")
            except Exception as chmod_err:
                print(f"[-] 修改普通 HTTP 下载文件权限失败: {chmod_err}")

            active_tasks[token] = [{"path": local_file_path, "type": content_type, "name": filename}]
            asyncio.create_task(auto_delete_cache(token, delay=10800))
            
            view_url = format_view_url(token)
            async with aiohttp.ClientSession() as session:
                file_ok, file_err = await send_file_to_qq(
                    session, token, 0, local_file_path, content_type, filename
                )
                qq_ok, qq_err = await send_link_to_qq(session, f"🔑 收到加密网页下载链接（3小时内复制打开）：\n{view_url}")
            
            await asyncio.sleep(2.5)
            if qq_ok and file_ok:
                await bot.edit_message_text(forward_success_text(), chat_id=message.chat.id, message_id=status_msg.message_id)
            else:
                errors = "; ".join(x for x in (qq_err, file_err) if x)
                await bot.edit_message_text(f"⚠️ 转发 QQ 失败: {errors}", chat_id=message.chat.id, message_id=status_msg.message_id)
                
        except Exception as e:
            await bot.edit_message_text(f"❌ 下载失败，发生异常: {e}", chat_id=message.chat.id, message_id=status_msg.message_id)


# --- 5. 主程序：并行启动 TG Bot (telebot) 和 Web Server ---
@bot.message_handler(func=lambda message: message.chat.type == 'private', content_types=['sticker'])
async def handle_sticker_message(message):
    sticker = message.sticker
    if not sticker: return
    
    file_id = sticker.file_id
    status_msg = await bot.reply_to(message, "⏳ 正在处理并转发贴纸，请稍候...")
    token = uuid.uuid4().hex
    
    # 提取前先检查缓存目录大小限制
    enforce_cache_size_limit()
    
    try:
        file_info = await bot.get_file(file_id)
        file_path_on_disk = file_info.file_path
        
        # 下载源贴纸文件
        orig_ext = ".webp"
        if sticker.is_animated:
            orig_ext = ".tgs"
        elif sticker.is_video:
            orig_ext = ".webm"
            
        local_orig_path = os.path.join(CACHE_DIR, f"sticker_{token}{orig_ext}")
        local_converted_path = None
        
        # 直接使用本地 HTTP 代理下载文件（或硬链接）
        if os.path.isabs(file_path_on_disk) and os.path.exists(file_path_on_disk):
            import shutil
            try:
                os.link(file_path_on_disk, local_orig_path)
            except Exception:
                await asyncio.to_thread(shutil.copyfile, file_path_on_disk, local_orig_path)
        else:
            url = f"{LOCAL_API_BASE}/file/bot{BOT_TOKEN}/{file_path_on_disk}"
            async with aiohttp.ClientSession() as session:
                async with session.get(url) as resp:
                    if resp.status != 200:
                        raise Exception(f"贴纸下载失败: HTTP {resp.status}")
                    with open(local_orig_path, "wb") as f:
                        f.write(await resp.content.read())
                        
        # 根据格式转换
        import subprocess, sys
        if sticker.is_animated: # .tgs -> .gif
            local_converted_path = os.path.join(CACHE_DIR, f"sticker_{token}.gif")
            # 调用 lottie_convert.py
            lottie_bin = os.path.join(os.path.dirname(sys.executable), "lottie_convert.py")
            if not os.path.exists(lottie_bin):
                lottie_bin = "lottie_convert.py"
                
            process = await asyncio.create_subprocess_exec(
                lottie_bin, local_orig_path, local_converted_path,
                stdout=subprocess.PIPE, stderr=subprocess.PIPE
            )
            _, stderr = await process.communicate()
            if process.returncode != 0:
                raise Exception(f"TGS转GIF失败: {stderr.decode('utf-8')[:100]}")
                
        elif sticker.is_video: # .webm -> .gif
            local_converted_path = os.path.join(CACHE_DIR, f"sticker_{token}.gif")
            try:
                # 采用高质量 gif 转换方案
                process = await asyncio.create_subprocess_exec(
                    "ffmpeg", "-y", "-i", local_orig_path, 
                    "-vf", "split[s0][s1];[s0]palettegen[p];[s1][p]paletteuse",
                    local_converted_path,
                    stdout=subprocess.PIPE, stderr=subprocess.PIPE
                )
                await process.communicate()
                if process.returncode != 0:
                    process = await asyncio.create_subprocess_exec(
                        "ffmpeg", "-y", "-i", local_orig_path, local_converted_path,
                        stdout=subprocess.PIPE, stderr=subprocess.PIPE
                    )
                    await process.communicate()
            except Exception as ffmpeg_err:
                print(f"[-] ffmpeg 转换动态贴纸失败 (可能未安装 ffmpeg)，回退发送源文件: {ffmpeg_err}")
                local_converted_path = local_orig_path
                
        else: # .webp -> .png (避免QQ兼容性问题)
            local_converted_path = os.path.join(CACHE_DIR, f"sticker_{token}.png")
            try:
                process = await asyncio.create_subprocess_exec(
                    "ffmpeg", "-y", "-i", local_orig_path, local_converted_path,
                    stdout=subprocess.PIPE, stderr=subprocess.PIPE
                )
                await process.communicate()
                if process.returncode != 0:
                    local_converted_path = local_orig_path
            except Exception as ffmpeg_err:
                print(f"[-] ffmpeg 转换静态贴纸失败，回退发送源文件: {ffmpeg_err}")
                local_converted_path = local_orig_path

        if not local_converted_path or not os.path.exists(local_converted_path):
            local_converted_path = local_orig_path # 回退到源文件
            
        # 设置权限以防无权读取
        try: os.chmod(local_converted_path, 0o644)
        except: pass
        
        # 将文件移动/复制到 NapCat 的 docker 挂载目录中
        import shutil
        napcat_sticker_dir = "/opt/napcat/qq/stickers"
        try: os.makedirs(napcat_sticker_dir, exist_ok=True)
        except: pass
        
        filename = os.path.basename(local_converted_path)
        napcat_file_path = os.path.join(napcat_sticker_dir, filename)
        docker_file_path = f"/app/.config/QQ/stickers/{filename}"
        
        try:
            os.link(local_converted_path, napcat_file_path)
        except Exception:
            try: shutil.copyfile(local_converted_path, napcat_file_path)
            except: pass

        # 准备 NapCat CQ 码或者 json payload
        msg_type = "image"
        if local_converted_path.endswith(".mp4"):
            msg_type = "video"
            
        payload = {
            **qq_target_payload(),
            "message": [
                {
                    "type": msg_type,
                    "data": {
                        "file": f"file://{docker_file_path}"
                    }
                }
            ]
        }
        
        async with aiohttp.ClientSession() as session:
            qq_ok, qq_err = await send_to_qq(session, payload)
            
        if qq_ok:
            await bot.edit_message_text("✅ 贴纸已成功转发至 QQ", chat_id=message.chat.id, message_id=status_msg.message_id)
        else:
            await bot.edit_message_text(f"⚠️ 贴纸转发 QQ 失败: {qq_err}", chat_id=message.chat.id, message_id=status_msg.message_id)
            
        # 清理文件
        try: os.remove(local_orig_path)
        except: pass
        
        async def delayed_cleanup(path, napcat_path):
            await asyncio.sleep(60)
            try: os.remove(path)
            except: pass
            try: os.remove(napcat_path)
            except: pass
        asyncio.create_task(delayed_cleanup(local_converted_path, napcat_file_path))
        
        try: await bot.delete_message(message.chat.id, message.message_id)
        except: pass
        
    except Exception as e:
        print(f"[-] 贴纸处理失败: {e}")
        if status_msg:
            await bot.edit_message_text(f"❌ 贴纸处理失败: {e}", chat_id=message.chat.id, message_id=status_msg.message_id)


async def main():
    # 启动时自动清理上一次服务崩溃/重启后可能残留的孤儿缓存文件
    orphan_count = 0
    for f in os.listdir(CACHE_DIR):
        fpath = os.path.join(CACHE_DIR, f)
        if os.path.isfile(fpath):
            os.remove(fpath)
            orphan_count += 1
    if orphan_count:
        print(f"[*] 启动清理：已删除 {orphan_count} 个上次残留的孤儿缓存文件")

    # delayed_remove 任务会随进程重启消失，仅清理一小时前的 NapCat 暂存文件。
    staged_orphan_count = 0
    cutoff = time.time() - 3600
    for f in os.listdir(NAPCAT_STAGE_DIR):
        fpath = os.path.join(NAPCAT_STAGE_DIR, f)
        if os.path.isfile(fpath) and os.path.getmtime(fpath) < cutoff:
            os.remove(fpath)
            staged_orphan_count += 1
    if staged_orphan_count:
        print(f"[*] 启动清理：已删除 {staged_orphan_count} 个过期 NapCat 暂存文件")

    # 初始化 Web 服务
    server = web.Application()
    server.add_routes([
        web.get('/view', handle_view_page),
        web.get('/stream', handle_stream),
        web.get('/download', handle_download)
    ])
    runner = web.AppRunner(server)
    await runner.setup()
    site = web.TCPSite(runner, WEB_HOST, WEB_PORT)
    
    print(f"[*] 内部加密网页服务器已在端口 {WEB_PORT} 挂载...")
    await site.start()
    
    print("[*] Telegram Bot (HTTP AsyncTeleBot) 正在启动...")
    # 启动 telebot 异步轮询 (完美连通，支持异步并发)
    await bot.polling(non_stop=True)

if __name__ == "__main__":
    asyncio.run(main())
