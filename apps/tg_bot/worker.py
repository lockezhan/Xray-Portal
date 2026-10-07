"""
Telegram 媒体转推轻量异步 Worker (运行于 HK-VPS)
解决小磁盘空间约束与公网流量瓶颈:
1. 流量分流: 所有媒体的下载与转推均在 HK-VPS 上执行，主控节点仅发送轻量 HTTP 控制信令。
2. 实时动态进度通知 (Live Progress): 支持每 2.5 秒通过 Telegram Bot API 原位编辑消息，实时刷新下载/转码/上传进度条与速率。
3. 磁盘安全水位检测 (Pre-flight Disk Check): 下载前计算媒体大小与磁盘剩余空间，严格保留至少 500MB 安全红线。
4. 即下即清机制 (Ephemeral Storage): 单任务串行执行，转推成功立即删除本地临时文件，finally 块强制彻底清理残留。
"""

from __future__ import annotations
import os
import sys
import re
import time
import json
import uuid
import math
import shutil
import asyncio
import logging
from typing import Union, Optional, Tuple
import aiohttp
from aiohttp import web
from telethon import TelegramClient
from telethon.extensions import html
from telethon.tl.types import (
    MessageMediaDocument,
    DocumentAttributeFilename,
    DocumentAttributeVideo,
    InputDocumentFileLocation,
    InputPhotoFileLocation,
    InputPeerChannel,
)
from telethon.tl.functions.upload import GetFileRequest
from telethon.tl.functions.channels import GetFullChannelRequest
from telethon.errors import FileMigrateError

# 配置日志输出 (强制中文注释与日志)
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    datefmt="%Y-%m-%d %H:%M:%S",
)
logger = logging.getLogger("tg_worker")

def load_env():
    """向上逐级查找并加载 .env 文件"""
    cur_dir = os.path.dirname(os.path.abspath(__file__))
    for _ in range(3):
        env_path = os.path.join(cur_dir, ".env")
        if os.path.exists(env_path):
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

load_env()

# 基础环境与凭证配置
API_ID = int(os.environ.get("TELEGRAM_USER_API_ID", 123456))
API_HASH = os.environ.get("TELEGRAM_USER_API_HASH", "xxxxxxxx")
CHANNEL_BOT_TOKEN = os.environ.get("CHANNEL_BOT_TOKEN") or os.environ.get("BOT_TOKEN")
WORKER_PORT = int(os.environ.get("WORKER_PORT", 20004))
WORKER_HOST = os.environ.get("WORKER_HOST", "0.0.0.0")
WORKER_SECRET_TOKEN = os.environ.get("WORKER_SECRET_TOKEN", "tg-worker-secret-key-default")
CACHE_DIR = os.environ.get("WORKER_CACHE_DIR", "/var/lib/tg-bridge-cache")
SESSION_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "telegram_session")
DISK_SAFETY_MARGIN_MB = int(os.environ.get("DISK_SAFETY_MARGIN_MB", 500))
TG_DOWNLOAD_WORKERS = int(os.environ.get("TG_DOWNLOAD_WORKERS", 16))

# 确保存储目录存在
try:
    os.makedirs(CACHE_DIR, exist_ok=True)
except Exception:
    CACHE_DIR = "/tmp/tg-bridge-cache"
    os.makedirs(CACHE_DIR, exist_ok=True)

# 全局任务异步缓冲队列：在 aiohttp 当前事件循环内初始化
TASK_QUEUE: Optional[asyncio.Queue] = None
CURRENT_RUNNING_TASK: Optional[dict] = None

class DiskSpaceError(Exception):
    """磁盘剩余空间不足异常"""
    pass

class ProgressReporter:
    """
    Telegram 实时进度通知器：
    内置节流机制 (默认 2.5 秒)，防止触发 Telegram Bot API 429 请求限流
    """
    def __init__(self, bot_token: Optional[str], chat_id: Optional[int], message_id: Optional[int], throttle_seconds: float = 2.5):
        self.bot_token = bot_token
        self.chat_id = chat_id
        self.message_id = message_id
        self.throttle_seconds = throttle_seconds
        self.last_update_time = 0.0
        self.last_text = ""
        self._session: Optional[aiohttp.ClientSession] = None

    def make_progress_bar(self, percent: float, length: int = 10) -> str:
        """生成字符进度条 [████░░░░░░]"""
        filled = max(0, min(length, int(length * percent / 100)))
        return "█" * filled + "░" * (length - filled)

    async def update(self, text: str, force: bool = False):
        if not self.bot_token or not self.chat_id or not self.message_id:
            return
        now = time.time()
        if not force and ((now - self.last_update_time < self.throttle_seconds) or text == self.last_text):
            return
        self.last_update_time = now
        self.last_text = text
        try:
            if not self._session or self._session.closed:
                self._session = aiohttp.ClientSession(timeout=aiohttp.ClientTimeout(total=5))
            url = f"https://api.telegram.org/bot{self.bot_token}/editMessageText"
            payload = {
                "chat_id": self.chat_id,
                "message_id": self.message_id,
                "text": text,
                "parse_mode": "HTML",
            }
            async with self._session.post(url, json=payload) as resp:
                await resp.read()
        except Exception as e:
            logger.debug(f"[-] 进度通知编辑失败 (可忽略): {e}")

    async def close(self):
        if self._session and not self._session.closed:
            try:
                await self._session.close()
            except Exception:
                pass

def clean_stale_cache():
    """清理历史遗留的临时残留文件"""
    try:
        count = 0
        for entry in os.scandir(CACHE_DIR):
            if entry.name.startswith("userbot_") or entry.name.endswith(".downloading") or ".faststart." in entry.name:
                try:
                    if entry.is_file():
                        os.remove(entry.path)
                        count += 1
                    elif entry.is_dir():
                        shutil.rmtree(entry.path, ignore_errors=True)
                        count += 1
                except Exception:
                    pass
        if count > 0:
            logger.info(f"[*] 启动巡检完成，已自动清理历史残留临时文件/目录共 {count} 个")
    except Exception as e:
        logger.warning(f"[-] 巡检清理缓存目录异常: {e}")

def check_disk_space(required_bytes: int, safety_margin_mb: int = DISK_SAFETY_MARGIN_MB):
    """
    检查磁盘剩余可用空间是否满足: free - required_bytes >= safety_margin
    若不满足则抛出 DiskSpaceError，杜绝撑爆根分区
    """
    usage = shutil.disk_usage(CACHE_DIR)
    safety_margin_bytes = safety_margin_mb * 1024 * 1024
    available_usable_bytes = usage.free - safety_margin_bytes
    if required_bytes > available_usable_bytes:
        available_mb = max(0, usage.free // (1024 * 1024))
        usable_mb = max(0, available_usable_bytes // (1024 * 1024))
        required_mb = math.ceil(required_bytes / (1024 * 1024))
        raise DiskSpaceError(
            f"磁盘剩余空间不足！当前可用: {available_mb}MB (扣除 {safety_margin_mb}MB 红线后净可用: {usable_mb}MB)，待下载媒体需: {required_mb}MB"
        )

def has_media_to_download(message):
    """判断消息是否包含可下载的媒体"""
    if message.video or message.photo:
        return True
    if message.document:
        return True
    if message.media and isinstance(message.media, MessageMediaDocument):
        return bool(message.media.document)
    return False

def is_video(message):
    """判断消息媒体是否为视频"""
    if message.video:
        return True
    if message.media and isinstance(message.media, MessageMediaDocument):
        doc = message.media.document
        if doc and doc.mime_type and doc.mime_type.startswith("video/"):
            return True
    return False

def get_original_filename(message):
    """提取原始文件名"""
    if message.document:
        for attr in message.document.attributes:
            if isinstance(attr, DocumentAttributeFilename):
                return attr.file_name
    return None

def get_input_file_location(message):
    """提取 Telegram 媒体的位置句柄及文件总大小"""
    if message.document:
        doc = message.document
        return InputDocumentFileLocation(
            id=doc.id,
            access_hash=doc.access_hash,
            file_reference=doc.file_reference,
            thumb_size="",
        ), (doc.size or 0)
    elif message.photo:
        photo = message.photo
        largest = max(photo.sizes, key=lambda s: s.size if hasattr(s, "size") else 0)
        return InputPhotoFileLocation(
            id=photo.id,
            access_hash=photo.access_hash,
            file_reference=photo.file_reference,
            thumb_size=largest.type,
        ), (largest.size if hasattr(largest, "size") else 0)
    return None, 0

async def fast_download_file(client, location, file_size, out_file, workers=TG_DOWNLOAD_WORKERS, progress_callback=None):
    """多并发分块高速下载器，支持实时进度汇报"""
    chunk_size = 512 * 1024
    chunks = math.ceil(file_size / chunk_size)
    queue = asyncio.Queue()
    sender = client._sender
    exported = False
    try:
        await client(GetFileRequest(location, offset=0, limit=4096))
    except FileMigrateError as e:
        sender = await client._borrow_exported_sender(e.new_dc)
        exported = True
    except Exception:
        pass

    for i in range(chunks):
        queue.put_nowait((i, i * chunk_size))

    with open(out_file, "wb") as f:
        if file_size > 0:
            f.seek(file_size - 1)
            f.write(b"\0")

    lock = asyncio.Lock()
    downloaded_bytes = 0

    async def worker():
        nonlocal downloaded_bytes
        while not queue.empty():
            try:
                i, offset = queue.get_nowait()
            except asyncio.QueueEmpty:
                break
            for attempt in range(3):
                try:
                    req = GetFileRequest(location=location, offset=offset, limit=chunk_size)
                    result = await client._call(sender, req)
                    chunk_len = len(result.bytes)
                    async with lock:
                        with open(out_file, "rb+") as f:
                            f.seek(offset)
                            f.write(result.bytes)
                        downloaded_bytes += chunk_len
                    if progress_callback:
                        try:
                            await progress_callback(downloaded_bytes, file_size)
                        except Exception:
                            pass
                    break
                except Exception as e:
                    if attempt == 2:
                        raise e
                    await asyncio.sleep(0.5)
            queue.task_done()

    worker_tasks = [asyncio.create_task(worker()) for _ in range(workers)]
    try:
        await asyncio.gather(*worker_tasks)
    finally:
        if exported and sender:
            await client._return_exported_sender(sender)

async def get_entity_safe(client_obj, peer_id):
    """安全解析频道/用户 Peer 实体"""
    try:
        res_entity = await client_obj.get_entity(peer_id)
    except ValueError:
        target_str = str(peer_id).lstrip("-")
        target_channel_id = (
            int(target_str[3:])
            if (target_str.startswith("100") and len(target_str) > 10)
            else (int(target_str) if target_str.isdigit() else None)
        )
        found_entity = None
        try:
            async for d in client_obj.iter_dialogs():
                d_ent_id = getattr(d.entity, "id", 0)
                if target_channel_id and (abs(d.id) == abs(int(peer_id)) or d_ent_id == target_channel_id):
                    found_entity = d.entity
                    break
                elif not target_channel_id and (getattr(d.entity, "username", "") == peer_id or d.name == peer_id):
                    found_entity = d.entity
                    break
        except Exception:
            pass
        if found_entity:
            res_entity = found_entity
        else:
            res_entity = await client_obj.get_entity(peer_id)
    if isinstance(res_entity, list):
        res_entity = res_entity[0]
    return res_entity

def format_forward_caption(
    orig_raw_text: str,
    orig_entities: list,
    source_url: str,
    user_input_caption: str = ""
) -> Tuple[str, str]:
    """
    格式化转发至频道的 Caption：
    1. 完整保留原消息的正文、描述词与所有 Tag 标签（保留富文本样式与可点击性）
    2. 追加原链接来源，防止原帖被删除后死无对证
    3. 保留用户发送时附带的个性化备注（若有）
    4. 严格遵守 Telegram 媒体 Caption 1024 字符限制，超长智能截断并保底
    返回: (final_caption_html, final_caption_plain)
    """
    # 提取用户私聊附带的个性化说明（扣除匹配到的 url 后剩余的有效字符）
    user_note = re.sub(r"https?://t\.me/\S+", "", user_input_caption or "").strip()

    content_blocks = []
    plain_blocks = []

    if user_note:
        safe_note = html.unparse(user_note, [])
        content_blocks.append(f"💬 <b>附言:</b> {safe_note}")
        plain_blocks.append(f"💬 附言: {user_note}")

    if orig_raw_text:
        try:
            orig_html = html.unparse(orig_raw_text, orig_entities or [])
        except Exception:
            orig_html = html.unparse(orig_raw_text, [])
        content_blocks.append(orig_html)
        plain_blocks.append(orig_raw_text)

    # 如果原消息或用户附言中尚未包含此原链接，则在末尾附带来源链接
    if source_url and source_url not in (orig_raw_text or "") and source_url not in user_note:
        content_blocks.append(f"🔗 <b>来源:</b> <a href=\"{source_url}\">{source_url}</a>")
        plain_blocks.append(f"🔗 来源: {source_url}")

    final_html = "\n\n".join(content_blocks).strip()
    final_plain = "\n\n".join(plain_blocks).strip()

    # 若没有任何文本，直接返回来源链接
    if not final_html:
        if source_url:
            final_html = f"🔗 <b>来源:</b> <a href=\"{source_url}\">{source_url}</a>"
            final_plain = f"🔗 来源: {source_url}"
        else:
            return "", ""

    # 检查纯文本字符数限制 (Telegram Caption 上限为 1024 字符)
    try:
        parsed_text, _ = html.parse(final_html)
    except Exception:
        parsed_text = final_plain

    if len(parsed_text) > 1024:
        source_suffix_plain = f"\n\n🔗 来源: {source_url}" if source_url else ""
        source_suffix_html = f"\n\n🔗 <b>来源:</b> <a href=\"{source_url}\">{source_url}</a>" if source_url else ""

        max_body_len = 1024 - len(source_suffix_plain) - 5
        if max_body_len > 0 and orig_raw_text:
            truncated_raw = orig_raw_text[:max_body_len] + "..."
            truncated_html = html.unparse(truncated_raw, [])
            final_html = f"{truncated_html}{source_suffix_html}"
            final_plain = f"{truncated_raw}{source_suffix_plain}"
        else:
            final_html = final_html[:1020] + "..."
            final_plain = final_plain[:1020] + "..."

    return final_html, final_plain

async def execute_fetch_and_forward(
    url: str,
    target_chat_id: Union[int, str],
    caption: str = "",
    progress_chat_id: Optional[int] = None,
    progress_msg_id: Optional[int] = None
):
    """
    核心执行器：
    1. 动态进度汇报器初始化
    2. 解析目标消息媒体与大小
    3. 前置磁盘水位安全检查
    4. 分块下载与 faststart 优化（带实时进度刷新）
    5. 直传目标频道（带上传实时进度刷新）
    6. 即下即清与 finally 强制清理
    """
    reporter = ProgressReporter(CHANNEL_BOT_TOKEN, progress_chat_id, progress_msg_id)

    match = re.search(r"t\.me/(?:c/)?([^/]+)/(\d+)", url)
    if not match:
        raise ValueError("无效的 Telegram 消息链接格式")

    channel_identifier = match.group(1)
    msg_id = int(match.group(2))
    if channel_identifier.isdigit():
        channel_id = int(f"-100{channel_identifier}")
    else:
        channel_id = channel_identifier if channel_identifier.startswith("@") else f"@{channel_identifier}"

    # 本次任务生命周期内所有临时文件追踪集合（用于 finally 强制兜底清理）
    task_temp_files = set()
    task_temp_dirs = set()

    unique_id = uuid.uuid4().hex
    temp_session = f"{SESSION_PATH}_{unique_id}"
    session_file = f"{SESSION_PATH}.session"
    temp_session_file = f"{temp_session}.session"

    # 注册临时 session 追踪
    for ext in ["", "-journal", "-wal", "-shm"]:
        task_temp_files.add(temp_session_file + ext)

    if os.path.exists(session_file):
        for ext in ["", "-journal", "-wal", "-shm"]:
            if os.path.exists(session_file + ext):
                try:
                    shutil.copy2(session_file + ext, temp_session_file + ext)
                except Exception:
                    pass

    client = TelegramClient(temp_session, API_ID, API_HASH)

    try:
        await reporter.update("🔍 <b>[1/3 调度与解析]</b>\n正在连接 Telegram 数据中心并检索媒体信息...", force=True)
        await client.connect()
        if not await client.is_user_authorized():
            raise RuntimeError("HK-VPS 上 Userbot 未授权登录，请先同步有效的 telegram_session.session")

        entity = await get_entity_safe(client, channel_id)

        # 处理附带评论链接的情况 (?comment=xxxx)
        comment_match = re.search(r"[?&]comment=(\d+)", url)
        if comment_match:
            full_channel = await client(GetFullChannelRequest(channel=entity))
            if full_channel.full_chat.linked_chat_id:
                entity = await get_entity_safe(client, full_channel.full_chat.linked_chat_id)
                msg_id = int(comment_match.group(1))

        message = await client.get_messages(entity, ids=msg_id)
        if not message:
            raise ValueError(f"未能获取到目标消息 (ID: {msg_id})，可能消息已被删除或所在私密群组无权限访问")

        if not has_media_to_download(message):
            raise ValueError("目标消息中未检测到可下载的媒体文件")

        messages_to_download = []
        if message.grouped_id:
            async for m in client.iter_messages(entity, min_id=msg_id - 10, max_id=msg_id + 10, limit=20):
                if m.grouped_id == message.grouped_id and has_media_to_download(m):
                    messages_to_download.append(m)
            messages_to_download.sort(key=lambda x: x.id)
        else:
            messages_to_download.append(message)

        # ----------------------------------------------------
        # 核心功能: 完整提取原消息的文字描述与 Tag 标签 (支持单消息与相册)
        # 解决原贴被删除后丢失主播名、tag 检索标签和说明的核心痛点
        # ----------------------------------------------------
        original_raw_text = ""
        original_entities = []
        candidate_msgs = [message] + [m for m in messages_to_download if m.id != message.id]
        for m in candidate_msgs:
            if m.raw_text and m.raw_text.strip():
                original_raw_text = m.raw_text.strip()
                original_entities = m.entities or []
                break

        final_caption_html, final_caption_plain = format_forward_caption(
            orig_raw_text=original_raw_text,
            orig_entities=original_entities,
            source_url=url,
            user_input_caption=caption
        )
        logger.info(f"[*] 已成功提取并格式化原消息描述 (原描述字数: {len(original_raw_text)}, 最终Caption字数: {len(final_caption_plain)})")

        # ----------------------------------------------------
        # 核心防爆盘安全机制 1: 前置磁盘水位安全检测
        # ----------------------------------------------------
        total_media_size = 0
        locations_and_sizes = []
        for m in messages_to_download:
            loc, s = get_input_file_location(m)
            locations_and_sizes.append((loc, s))
            total_media_size += s

        total_mb = total_media_size / (1024 * 1024)
        logger.info(f"[*] 准备下载媒体: 共 {len(messages_to_download)} 个文件，总大小: {total_mb:.2f}MB")
        # 检查总大小是否超过剩余可用空间 - 500MB
        check_disk_space(total_media_size, safety_margin_mb=DISK_SAFETY_MARGIN_MB)

        # ----------------------------------------------------
        # 开始逐个下载媒体 (附带实时进度刷新)
        # ----------------------------------------------------
        downloaded_items = []
        dl_start_time = time.time()

        for idx, m in enumerate(messages_to_download):
            is_pic = m.photo and not m.document
            is_vid = is_video(m) or m.video
            original_name = get_original_filename(m)
            if original_name:
                ext = os.path.splitext(original_name)[1] or ".bin"
                safe_original = re.sub(r"[^\w.\-]", "_", original_name)
                media_id = getattr(m.document, "id", None) or getattr(m.photo, "id", None) or m.id
                file_name = f"{media_id}_{safe_original}"
            else:
                ext = ".jpg" if is_pic else ".mp4" if is_vid else ".bin"
                media_id = getattr(m.document, "id", None) or getattr(m.photo, "id", None) or m.id
                file_name = f"userbot_{abs(getattr(entity, 'id', 0))}_{media_id}{ext}"

            file_path = os.path.join(CACHE_DIR, file_name)
            tmp_file = f"{file_path}.{uuid.uuid4().hex}.downloading"
            faststart_path = tmp_file + ".faststart.mp4"

            task_temp_files.add(tmp_file)
            task_temp_files.add(faststart_path)
            task_temp_files.add(file_path)

            loc, s = locations_and_sizes[idx]

            async def on_download_progress(current, total):
                percent = (current / max(1, total)) * 100
                elapsed = max(0.1, time.time() - dl_start_time)
                speed = current / elapsed
                bar = reporter.make_progress_bar(percent)
                msg_text = (
                    f"📥 <b>[1/3 正在极速下载媒体]</b>\n"
                    f"<code>{bar}</code> {percent:.1f}%\n"
                    f"📊 进度: {current / (1024*1024):.1f} MB / {total / (1024*1024):.1f} MB\n"
                    f"⚡ 速率: {speed / (1024*1024):.2f} MB/s (多线程加速)\n"
                    f"🌐 节点: HK-VPS (0 Korea流量消耗)"
                )
                await reporter.update(msg_text)

            if loc and s > 0:
                await fast_download_file(client, loc, s, tmp_file, workers=TG_DOWNLOAD_WORKERS, progress_callback=on_download_progress)
            else:
                await client.download_media(m, file=tmp_file)

            # ----------------------------------------------------
            # Faststart 优化 (秒开处理)
            # ----------------------------------------------------
            if ext == ".mp4" and shutil.which("ffmpeg"):
                await reporter.update("🔄 <b>[2/3 视频优化]</b>\n正在注入 Faststart 秒开流式元数据...", force=True)
                curr_usage = shutil.disk_usage(CACHE_DIR)
                if curr_usage.free > (s + DISK_SAFETY_MARGIN_MB * 1024 * 1024):
                    try:
                        proc = await asyncio.create_subprocess_exec(
                            "ffmpeg", "-y", "-i", tmp_file, "-c", "copy", "-map", "0", "-movflags", "+faststart", faststart_path,
                            stdout=asyncio.subprocess.DEVNULL, stderr=asyncio.subprocess.DEVNULL
                        )
                        await proc.communicate()
                        if proc.returncode == 0 and os.path.exists(faststart_path):
                            os.replace(faststart_path, file_path)
                            if os.path.exists(tmp_file):
                                os.remove(tmp_file)
                                task_temp_files.discard(tmp_file)
                        else:
                            os.replace(tmp_file, file_path)
                    except Exception as ff_err:
                        logger.warning(f"[-] Faststart 优化异常，回退原文件: {ff_err}")
                        os.replace(tmp_file, file_path)
                else:
                    logger.info(f"[*] 磁盘空间紧凑，安全跳过 faststart 副本转码，直接使用原始视频")
                    os.replace(tmp_file, file_path)
            else:
                os.replace(tmp_file, file_path)

            # 提取原视频属性与缩略图，确保上传后客户端能够在线流式秒开播放
            video_attrs = []
            thumb_path = None
            if is_vid:
                if m.document and m.document.attributes:
                    for attr in m.document.attributes:
                        if isinstance(attr, DocumentAttributeVideo):
                            video_attrs.append(DocumentAttributeVideo(
                                duration=int(attr.duration) if attr.duration else 0,
                                w=attr.w or 0,
                                h=attr.h or 0,
                                round_message=attr.round_message or False,
                                supports_streaming=True
                            ))
                        elif not isinstance(attr, DocumentAttributeFilename):
                            video_attrs.append(attr)
                
                # 如果没有从原消息中找到 VideoAttribute，补充默认流式属性
                if not any(isinstance(a, DocumentAttributeVideo) for a in video_attrs):
                    video_attrs.append(DocumentAttributeVideo(
                        duration=0,
                        w=720,
                        h=1280,
                        supports_streaming=True
                    ))

                # 尝试下载原始封面缩略图，让在线播放器有原生封面
                if m.photo or (m.document and getattr(m.document, 'thumbs', None)):
                    thumb_file = f"{file_path}.thumb.jpg"
                    task_temp_files.add(thumb_file)
                    try:
                        dl_thumb = await client.download_media(m, file=thumb_file, thumb=-1)
                        if dl_thumb and os.path.exists(dl_thumb):
                            thumb_path = dl_thumb
                    except Exception as thumb_err:
                        logger.debug(f"[-] 下载缩略图失败: {thumb_err}")

            task_temp_files.discard(tmp_file)
            task_temp_files.discard(faststart_path)

            downloaded_items.append({
                "path": file_path,
                "name": file_name,
                "size": os.path.getsize(file_path) if os.path.exists(file_path) else s,
                "is_video": is_vid,
                "is_photo": is_pic,
                "attributes": video_attrs if is_vid else None,
                "thumb_path": thumb_path,
            })

        # ----------------------------------------------------
        # 转发至目标频道 (MTProto 直传支持最高 2GB 文件)
        # 核心修复: 确保用谁上传就用谁解析频道实体，彻底杜绝 ChannelInvalidError
        # ----------------------------------------------------
        await reporter.update("📤 <b>[3/3 准备推流]</b>\n正在连接目标频道并初始化 MTProto 直传通道...", force=True)
        bot_client = None
        upload_client = client
        target_entity = None

        if CHANNEL_BOT_TOKEN:
            try:
                bot_session_path = f"{SESSION_PATH}_bot_{unique_id}"
                for ext in ["", "-journal", "-wal", "-shm"]:
                    task_temp_files.add(f"{bot_session_path}.session" + ext)
                bot_client = TelegramClient(bot_session_path, API_ID, API_HASH)
                await bot_client.start(bot_token=CHANNEL_BOT_TOKEN)
                # 关键修复: 必须用 bot_client 自身去解析目标频道
                target_entity = await get_entity_safe(bot_client, target_chat_id)
                upload_client = bot_client
                logger.info(f"[*] 已成功启用 Bot 身份解析并推送目标频道: {getattr(target_entity, 'title', target_chat_id)}")
            except Exception as bot_init_err:
                logger.warning(f"[-] Bot 身份解析频道失败，自动回退使用 Userbot 身份: {bot_init_err}")
                if bot_client:
                    try: await bot_client.disconnect()
                    except Exception: pass
                    bot_client = None
                upload_client = client
                target_entity = await get_entity_safe(client, target_chat_id)
        else:
            target_entity = await get_entity_safe(client, target_chat_id)

        upload_start_time = time.time()

        async def on_upload_progress(current, total):
            percent = (current / max(1, total)) * 100
            elapsed = max(0.1, time.time() - upload_start_time)
            speed = current / elapsed
            bar = reporter.make_progress_bar(percent)
            msg_text = (
                f"📤 <b>[3/3 正在推送目标频道]</b>\n"
                f"<code>{bar}</code> {percent:.1f}%\n"
                f"📊 进度: {current / (1024*1024):.1f} MB / {total / (1024*1024):.1f} MB\n"
                f"⚡ 速率: {speed / (1024*1024):.2f} MB/s (MTProto 直传通道)\n"
                f"🚀 目标: 目标频道"
            )
            await reporter.update(msg_text)

        try:
            if len(downloaded_items) == 1:
                item = downloaded_items[0]
                is_v = item["is_video"]
                logger.info(f"[*] 正在推送单文件至频道: {item['name']} (视频在线播放模式: {is_v})")
                try:
                    await upload_client.send_file(
                        target_entity,
                        file=item["path"],
                        caption=final_caption_html,
                        parse_mode="html",
                        attributes=item.get("attributes"),
                        supports_streaming=True if is_v else False,
                        thumb=item.get("thumb_path"),
                        force_document=False if is_v else not (item["is_photo"]),
                        progress_callback=on_upload_progress,
                    )
                except Exception as send_html_err:
                    logger.warning(f"[-] HTML 格式推送失败 ({send_html_err})，自动降级回退纯文本 Caption 推送")
                    await upload_client.send_file(
                        target_entity,
                        file=item["path"],
                        caption=final_caption_plain,
                        parse_mode=None,
                        attributes=item.get("attributes"),
                        supports_streaming=True if is_v else False,
                        thumb=item.get("thumb_path"),
                        force_document=False if is_v else not (item["is_photo"]),
                        progress_callback=on_upload_progress,
                    )
            else:
                file_paths = [it["path"] for it in downloaded_items]
                logger.info(f"[*] 正在以相册形式推送 {len(file_paths)} 个文件至目标频道")
                try:
                    await upload_client.send_file(
                        target_entity,
                        file=file_paths,
                        caption=final_caption_html,
                        parse_mode="html",
                        supports_streaming=True,
                        progress_callback=on_upload_progress,
                    )
                except Exception as send_album_html_err:
                    logger.warning(f"[-] 相册 HTML 格式推送失败 ({send_album_html_err})，自动降级回退纯文本 Caption 推送")
                    await upload_client.send_file(
                        target_entity,
                        file=file_paths,
                        caption=final_caption_plain,
                        parse_mode=None,
                        supports_streaming=True,
                        progress_callback=on_upload_progress,
                    )
        finally:
            if bot_client:
                try:
                    await bot_client.disconnect()
                except Exception:
                    pass

        # ----------------------------------------------------
        # 核心即下即清机制 2: 成功转推后，立即删除本地媒体文件！
        # ----------------------------------------------------
        for item in downloaded_items:
            fpath = item["path"]
            if os.path.exists(fpath):
                try:
                    os.remove(fpath)
                    task_temp_files.discard(fpath)
                    logger.info(f"[+] [即下即清] 已成功删除本地临时媒体: {item['name']}")
                except Exception as del_err:
                    logger.error(f"[-] 删除临时文件失败: {fpath}, {del_err}")

        # 最终完成通知
        total_time_str = f"{int(time.time() - dl_start_time)} 秒"
        await reporter.update(
            f"✅ <b>[HK-VPS 分流转推成功]</b>\n"
            f"📦 文件数量: {len(downloaded_items)} 个\n"
            f"📊 媒体总计: {total_mb:.2f} MB\n"
            f"⏱️ 总计耗时: {total_time_str}\n"
            f"⚡ <b>即下即清完成</b>，HK-VPS 磁盘 0 残留\n"
            f"🛡️ Korea-VPS 流量消耗: <b>0 MB</b>",
            force=True
        )

        return {
            "success": True,
            "files_count": len(downloaded_items),
            "total_size": total_media_size,
            "details": [{"name": it["name"], "size": it["size"]} for it in downloaded_items],
        }

    except Exception as e:
        err_msg = str(e)
        logger.error(f"[-] 转推异常: {err_msg}", exc_info=True)
        await reporter.update(f"❌ <b>[HK-VPS 处理失败]</b>: {err_msg}", force=True)
        raise e

    finally:
        await reporter.close()
        # 断开并关闭 Telethon 客户端连接
        try:
            await client.disconnect()
        except Exception:
            pass

        # ----------------------------------------------------
        # 核心防爆盘安全机制 3: finally 块强制彻底清理所有追踪临时文件
        # ----------------------------------------------------
        for f in list(task_temp_files):
            if os.path.exists(f):
                try:
                    if os.path.isdir(f):
                        shutil.rmtree(f, ignore_errors=True)
                    else:
                        os.remove(f)
                except Exception:
                    pass

        for d in list(task_temp_dirs):
            if os.path.exists(d):
                shutil.rmtree(d, ignore_errors=True)

# ------------------------------------------------------------
# aiohttp Web 服务与路由
# ------------------------------------------------------------
routes = web.RouteTableDef()

def check_auth(request: web.Request):
    """Token 鉴权"""
    if not WORKER_SECRET_TOKEN:
        return True
    auth_header = request.headers.get("Authorization", "")
    if not auth_header.startswith("Bearer "):
        return False
    token = auth_header.split(" ", 1)[1].strip()
    return token == WORKER_SECRET_TOKEN

@routes.get("/health")
async def handle_health(request: web.Request):
    """健康检查与磁盘水位查询接口"""
    usage = shutil.disk_usage(CACHE_DIR)
    free_mb = usage.free // (1024 * 1024)
    total_mb = usage.total // (1024 * 1024)
    return web.json_response({
        "status": "ok",
        "service": "tg-hk-worker",
        "disk": {
            "total_mb": total_mb,
            "free_mb": free_mb,
            "safety_margin_mb": DISK_SAFETY_MARGIN_MB,
            "usable_mb": max(0, free_mb - DISK_SAFETY_MARGIN_MB),
        }
    })

async def queue_consumer():
    """
    后台任务单并发消费循环：
    严格串行出队执行任务，单任务执行完毕并释放磁盘后才处理下一个，保障小磁盘安全
    """
    global CURRENT_RUNNING_TASK
    logger.info("[*] 异步任务消费队列监听循环已启动就绪...")
    while True:
        if TASK_QUEUE is None:
            await asyncio.sleep(0.1)
            continue
        try:
            task = await TASK_QUEUE.get()
            CURRENT_RUNNING_TASK = task
            task_id = task["task_id"]
            url = task["url"]
            target_chat_id = task["target_chat_id"]
            caption = task["caption"]
            progress_chat_id = task.get("progress_chat_id")
            progress_msg_id = task.get("progress_msg_id")

            logger.info(f"[*] [队列开始执行] 任务ID={task_id}, URL={url}, 当前剩余排队={TASK_QUEUE.qsize()}")

            try:
                await execute_fetch_and_forward(
                    url, target_chat_id, caption,
                    progress_chat_id=progress_chat_id,
                    progress_msg_id=progress_msg_id
                )
            except DiskSpaceError as dse:
                logger.warning(f"[-] 任务 [{task_id}] 磁盘空间超限拦截: {dse}")
            except Exception as ex:
                logger.error(f"[-] 任务 [{task_id}] 执行失败: {ex}", exc_info=True)
            finally:
                CURRENT_RUNNING_TASK = None
                TASK_QUEUE.task_done()
                logger.info(f"[+] [队列任务完毕] 任务ID={task_id}, 当前剩余排队={TASK_QUEUE.qsize()}")
        except asyncio.CancelledError:
            logger.info("[*] 消费队列已收到取消信号，安全退出")
            break
        except Exception as queue_err:
            logger.error(f"[-] 队列调度未知异常: {queue_err}", exc_info=True)
            await asyncio.sleep(1)

@routes.get("/api/queue")
async def handle_get_queue(request: web.Request):
    """查询当前队列排队状态接口"""
    return web.json_response({
        "status": "ok",
        "is_busy": (CURRENT_RUNNING_TASK is not None),
        "current_task": CURRENT_RUNNING_TASK.get("task_id") if CURRENT_RUNNING_TASK else None,
        "queue_length": TASK_QUEUE.qsize(),
    })

@routes.post("/api/forward")
async def handle_forward(request: web.Request):
    """
    任务接入核心接口 (异步快速入队模型):
    0.05秒极速响应入队成功，彻底杜绝长连接阻塞与 500 超时，任务由后台队列按序消费
    """
    if not check_auth(request):
        return web.json_response({"success": False, "error": "Unauthorized: 无效的鉴权令牌"}, status=401)

    try:
        data = await request.json()
    except Exception:
        return web.json_response({"success": False, "error": "请求体必须为合法 JSON"}, status=400)

    url = data.get("url", "").strip()
    target_chat_id = data.get("target_chat_id")
    caption = data.get("caption", "")
    progress_chat_id = data.get("progress_chat_id")
    progress_msg_id = data.get("progress_msg_id")

    if not url or not target_chat_id:
        return web.json_response({"success": False, "error": "缺少必要参数: url 或 target_chat_id"}, status=400)

    global TASK_QUEUE
    if TASK_QUEUE is None:
        TASK_QUEUE = asyncio.Queue()

    task_id = uuid.uuid4().hex[:8]
    current_q_size = TASK_QUEUE.qsize()
    is_busy = (CURRENT_RUNNING_TASK is not None)
    # 排队位次
    queue_pos = (current_q_size + 1) if is_busy else 1

    task_item = {
        "task_id": task_id,
        "url": url,
        "target_chat_id": target_chat_id,
        "caption": caption,
        "progress_chat_id": progress_chat_id,
        "progress_msg_id": progress_msg_id,
        "enqueue_time": time.time(),
    }

    # 若当前有任务正在执行，立即向 Telegram 回复一条排队提示，告知用户已锁定，无需重复发送
    if is_busy and progress_chat_id and progress_msg_id:
        reporter = ProgressReporter(CHANNEL_BOT_TOKEN, progress_chat_id, progress_msg_id)
        waiting_count = current_q_size + 1
        asyncio.create_task(reporter.update(
            f"⏳ <b>[已加入任务缓冲队列]</b>\n"
            f"📋 当前排队位次: <b>#{waiting_count}</b> (前方有 {waiting_count} 个任务正在处理)\n"
            f"⚡ 系统将在前序任务完成并释放磁盘后<b>自动按序下载转推</b>，无需重复发送！",
            force=True
        ))

    # 压入任务队列
    await TASK_QUEUE.put(task_item)
    logger.info(f"[+] 任务成功入队 [{task_id}]: URL={url}, 位次=#{queue_pos}, 队列总长={TASK_QUEUE.qsize()}")

    # 毫秒级返回入队成功，彻底解决 HTTP 500 Server got itself in trouble
    return web.json_response({
        "success": True,
        "queued": True,
        "task_id": task_id,
        "queue_position": queue_pos,
        "is_busy": is_busy,
        "message": f"任务已安全加入队列 (位次 #{queue_pos})"
    })

async def init_background_tasks(app):
    """管理后台消费协程与事件循环生命周期"""
    global TASK_QUEUE
    TASK_QUEUE = asyncio.Queue()
    consumer = asyncio.create_task(queue_consumer())
    app["consumer_task"] = consumer
    yield
    consumer.cancel()
    await asyncio.gather(consumer, return_exceptions=True)

def main():
    clean_stale_cache()
    app = web.Application()
    app.cleanup_ctx.append(init_background_tasks)
    app.add_routes(routes)
    logger.info(f"[*] TG HK-Worker 正在启动 (异步消息队列模式)，监听 {WORKER_HOST}:{WORKER_PORT}...")
    web.run_app(app, host=WORKER_HOST, port=WORKER_PORT)

if __name__ == "__main__":
    main()
