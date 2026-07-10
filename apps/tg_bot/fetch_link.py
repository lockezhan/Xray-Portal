import sys
import re
import asyncio
import json
import os
from telethon import TelegramClient
from telethon.tl.types import MessageMediaDocument

def load_env():
    cur_dir = os.path.dirname(os.path.abspath(__file__))
    for _ in range(3):
        env_path = os.path.join(cur_dir, ".env")
        if os.path.exists(env_path):
            with open(env_path, "r", encoding="utf-8") as f:
                for line in f:
                    line = line.strip()
                    if not line or line.startswith("#"): continue
                    if "=" in line:
                        key, val = line.split("=", 1)
                        os.environ[key.strip()] = val.strip()
            break
        cur_dir = os.path.dirname(cur_dir)
load_env()

# 请确保您的 .env 文件中包含了这两个变量（与您登录时用的保持一致）
API_ID = int(os.environ.get("TELEGRAM_USER_API_ID", 123456))
API_HASH = os.environ.get("TELEGRAM_USER_API_HASH", "xxxxxxxx")

CACHE_DIR = "/var/lib/tg-bridge-cache"
SESSION_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "telegram_session")
os.makedirs(CACHE_DIR, exist_ok=True)

def has_media_to_download(message):
    if message.video or message.photo: return True
    if message.media and isinstance(message.media, MessageMediaDocument):
        doc = message.media.document
        if doc and doc.mime_type and doc.mime_type.startswith('video/'): return True
    return False

def is_video(message):
    if message.video: return True
    if message.media and isinstance(message.media, MessageMediaDocument):
        doc = message.media.document
        if doc and doc.mime_type and doc.mime_type.startswith('video/'): return True
    return False

async def main():
    if len(sys.argv) < 2:
        print(json.dumps({"error": "No URL provided"}))
        return
    url = sys.argv[1]
    
    match = re.search(r't\.me/(?:c/)?([^/]+)/(\d+)', url)
    if not match:
        print(json.dumps({"error": "Invalid URL format"}))
        return

    channel_identifier = match.group(1)
    msg_id = int(match.group(2))
    
    if channel_identifier.isdigit():
        channel_id = int(f"-100{channel_identifier}")
    else:
        channel_id = channel_identifier if channel_identifier.startswith('@') else f"@{channel_identifier}"

    import uuid
    import shutil
    unique_id = uuid.uuid4().hex
    temp_session = f"{SESSION_PATH}_{unique_id}"
    session_file = f"{SESSION_PATH}.session"
    temp_session_file = f"{temp_session}.session"
    if os.path.exists(session_file):
        try:
            shutil.copy2(session_file, temp_session_file)
        except Exception:
            pass

    client = TelegramClient(temp_session, API_ID, API_HASH)
    
    try:
        await client.connect()
        if not await client.is_user_authorized():
            print(json.dumps({"error": "Userbot not authorized. Run login_userbot.py first."}))
            return
            
        entity = await client.get_entity(channel_id)
        
        # 处理附带评论链接的情况 (?comment=xxxx)
        comment_match = re.search(r'[?&]comment=(\d+)', url)
        if comment_match:
            from telethon.tl.functions.channels import GetFullChannelRequest
            full_channel = await client(GetFullChannelRequest(channel=entity))
            if full_channel.full_chat.linked_chat_id:
                entity = await client.get_entity(full_channel.full_chat.linked_chat_id)
                msg_id = int(comment_match.group(1))

        message = await client.get_messages(entity, ids=msg_id)
        if not message:
            print(json.dumps({"error": "Target message not found."}))
            return
            
        if not has_media_to_download(message):
            print(json.dumps({"error": "No downloadable media found in this message."}))
            return
            
        messages_to_download = []
        if message.grouped_id:
            async for m in client.iter_messages(entity, min_id=msg_id - 10, max_id=msg_id + 10, limit=20):
                if m.grouped_id == message.grouped_id and has_media_to_download(m):
                    messages_to_download.append(m)
            messages_to_download.sort(key=lambda x: x.id)
        else:
            messages_to_download.append(message)
            
        downloaded_files = []
        
        from telethon.tl.functions.upload import GetFileRequest
        from telethon.errors import FileMigrateError
        import math
        from telethon.tl.types import InputDocumentFileLocation, InputPhotoFileLocation

        def get_input_file_location(message):
            if message.document:
                doc = message.document
                return InputDocumentFileLocation(
                    id=doc.id, access_hash=doc.access_hash,
                    file_reference=doc.file_reference, thumb_size=''
                ), doc.size
            elif message.photo:
                photo = message.photo
                largest = max(photo.sizes, key=lambda s: s.size if hasattr(s, 'size') else 0)
                return InputPhotoFileLocation(
                    id=photo.id, access_hash=photo.access_hash,
                    file_reference=photo.file_reference, thumb_size=largest.type
                ), largest.size if hasattr(largest, 'size') else 0
            return None, 0

        async def fast_download_file(client, location, file_size, out_file, workers=4):
            chunk_size = 1024 * 1024
            chunks = math.ceil(file_size / chunk_size)
            queue = asyncio.Queue()
            sender = client._sender
            exported = False
            try:
                await client(GetFileRequest(location, offset=0, limit=4096))
            except FileMigrateError as e:
                sender = await client._borrow_exported_sender(e.new_dc)
                exported = True
            except Exception: pass

            for i in range(chunks):
                queue.put_nowait((i, i * chunk_size))

            with open(out_file, 'wb') as f:
                if file_size > 0:
                    f.seek(file_size - 1)
                    f.write(b'\0')

            lock = asyncio.Lock()
            
            async def worker():
                while not queue.empty():
                    try: i, offset = queue.get_nowait()
                    except asyncio.QueueEmpty: break
                    for attempt in range(3):
                        try:
                            req = GetFileRequest(location=location, offset=offset, limit=chunk_size)
                            result = await client._call(sender, req)
                            async with lock:
                                with open(out_file, 'rb+') as f:
                                    f.seek(offset)
                                    f.write(result.bytes)
                            break
                        except Exception as e:
                            if attempt == 2: raise e
                            await asyncio.sleep(1)
                    queue.task_done()

            worker_tasks = [asyncio.create_task(worker()) for _ in range(workers)]
            try: await asyncio.gather(*worker_tasks)
            finally:
                if exported and sender:
                    await client._return_exported_sender(sender)

        for m in messages_to_download:
            is_pic = m.photo
            is_vid = is_video(m) or m.video
            ext = ".jpg" if is_pic else ".mp4" if is_vid else ".bin"
            
            # 1. 核心修复：基于媒体唯一 ID 进行缓存，彻底解决转发后链接改变但文件相同的问题
            media_id = None
            if m.document:
                media_id = m.document.id
            elif m.photo:
                media_id = m.photo.id
                
            if media_id:
                file_name = f"userbot_media_{media_id}{ext}"
            else:
                file_name = f"userbot_{abs(getattr(entity, 'id', 0))}_{m.id}{ext}"
                
            file_path = os.path.join(CACHE_DIR, file_name)
            
            if not os.path.exists(file_path):
                tmp_file = f"{file_path}.{uuid.uuid4().hex}.downloading"
                location, size = get_input_file_location(m)
                if location and size > 0:
                    await fast_download_file(client, location, size, tmp_file, workers=16)
                else:
                    await client.download_media(m, file=tmp_file)
                
                # 2. 核心修复：解决在线播放卡顿/需要缓冲完整视频的问题
                # 如果是视频，使用 ffmpeg 将 moov atom 移动到文件头部，实现边下边播 (秒开)
                if ext == ".mp4":
                    import subprocess
                    faststart_path = tmp_file + ".faststart.mp4"
                    try:
                        # 使用 -c copy 和 -movflags faststart，纯拷贝无重新编码，速度极快
                        subprocess.run(["ffmpeg", "-y", "-i", tmp_file, "-c", "copy", "-map", "0", "-movflags", "+faststart", faststart_path], 
                                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=True)
                        os.replace(faststart_path, file_path)
                        if os.path.exists(tmp_file):
                            os.remove(tmp_file)
                    except Exception:
                        if os.path.exists(faststart_path):
                            os.remove(faststart_path)
                        os.replace(tmp_file, file_path)
                else:
                    os.replace(tmp_file, file_path)
            
            # 统一设置文件权限为 644，确保 Nginx 可读，实现顺利播放/下载
            try:
                os.chmod(file_path, 0o644)
            except Exception as chmod_err:
                print(f"[-] 修改 Userbot 下载文件权限失败: {chmod_err}", file=sys.stderr)

            downloaded_files.append({
                "path": file_path,
                "type": "video/mp4" if is_vid else "image/jpeg" if is_pic else "application/octet-stream",
                "name": file_name
            })
            
        print(json.dumps({"success": True, "files": downloaded_files}))
        
    except Exception as e:
        print(json.dumps({"error": str(e)}))
    finally:
        try:
            await client.disconnect()
        except Exception:
            pass
            
        try:
            if os.path.exists(temp_session_file):
                os.remove(temp_session_file)
            if os.path.exists(f"{temp_session_file}-journal"):
                os.remove(f"{temp_session_file}-journal")
        except Exception:
            pass

if __name__ == '__main__':
    asyncio.run(main())
