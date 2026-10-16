import os
import telebot
from telebot.types import InputMediaPhoto, InputMediaVideo, InputMediaDocument, InputMediaAudio
from threading import Timer
import sys

def load_env():
    # 自动向上查找并加载根目录的 .env 文件
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

# 加载环境变量
load_env()

# 安全获取环境变量，防止硬编码泄漏
TOKEN = os.environ.get('CHANNEL_BOT_TOKEN')
ADMIN_ID_STR = os.environ.get('CHANNEL_ADMIN_ID')
GROUP_ID_STR = os.environ.get('CHANNEL_GROUP_ID')

# HK-VPS 异步转推 Worker 配置 (流量分流与小磁盘安全方案)
HK_WORKER_URL = os.environ.get('HK_WORKER_URL', '').rstrip('/')
HK_WORKER_SECRET_TOKEN = os.environ.get('HK_WORKER_SECRET_TOKEN', '')

if not TOKEN or TOKEN == 'replace_me' or not ADMIN_ID_STR or ADMIN_ID_STR == 'replace_me' or not GROUP_ID_STR or GROUP_ID_STR == 'replace_me':
    print("警告: 机器人配置 (TOKEN, ADMIN_ID, GROUP_ID) 未配置或为 replace_me 占位符！", file=sys.stderr)
    print("Channel Bot 暂不激活，将进入待机挂起状态。补齐配置后重启服务即可启用。", file=sys.stderr)
    import time
    while True:
        time.sleep(3600)

try:
    ADMIN_ID = int(ADMIN_ID_STR)
    GROUP_ID = int(GROUP_ID_STR)
except ValueError as ve:
    print(f"错误: 环境变量类型转换失败: {ve}", file=sys.stderr)
    sys.exit(1)

import socket

def is_port_open(host, port, timeout=1):
    try:
        with socket.create_connection((host, port), timeout=timeout):
            return True
    except OSError:
        return False

# 检查本地的 Telegram Bot API 服务器是否在 8081 端口运行
if is_port_open("127.0.0.1", 8081):
    from telebot import apihelper
    apihelper.API_URL = "http://127.0.0.1:8081/bot{0}/{1}"
    apihelper.FILE_URL = "http://127.0.0.1:8081/file/bot{0}/{1}"
    print("检测到本地 Telegram Bot API 服务器已启动（8081），使用本地 API 模式。")
else:
    print("未检测到本地 Telegram Bot API 服务器，已自动回退使用 Telegram 官方 API (https://api.telegram.org)。")

# 将请求超时设置拉长到 10 分钟，以防止发送几个 GB 大小的视频时 bot 抛出超时断开
bot = telebot.TeleBot(TOKEN, threaded=True)
media_groups = {}


def send_grouped_media(media_group_id, chat_id, admin_chat_id):
    """延时器触发：将带有完整描述的相册合并发送"""
    group_data = media_groups.pop(media_group_id, None)
    if not group_data or not group_data['media']:
        return
    media_list = group_data['media']

    # 💡 核心修复：把拦截到的描述词和 Tag，强制绑定到合并后的第一张图/视频上
    if group_data['caption']:
        media_list[0].caption = group_data['caption']
        media_list[0].caption_entities = group_data['caption_entities']

    try:
        bot.send_media_group(chat_id=chat_id, media=media_list, timeout=600)
        bot.send_message(admin_chat_id, "✅ 相册（已保留原描述和Tag）已成功合并无痕转发。")
    except Exception as e:
        bot.send_message(admin_chat_id, f"❌ 转发相册失败: {e}")

@bot.message_handler(func=lambda message: message.chat.type == 'private' and message.from_user.id == ADMIN_ID,
                     content_types=['sticker'])
def handle_sticker_to_gif(message):
    """
    处理管理员发送的 Sticker 并转换为高质量透明背景 GIF：
    1. 视频贴纸 (.webm): 使用 FFmpeg 两阶段自适应调色板 (palettegen + paletteuse) 算法，保留透明通道与丝滑帧率
    2. 静态贴纸 (.webp): 高清调色板生成并无损转为 GIF
    3. 矢量贴纸 (.tgs): 给出友好格式提示
    4. 即下即清: 临时目录在操作完毕后立即强制清理，保证 0 磁盘堆积
    """
    sticker = message.sticker
    if not sticker:
        return

    is_video = getattr(sticker, 'is_video', False)
    is_animated = getattr(sticker, 'is_animated', False)
    emoji = getattr(sticker, 'emoji', '') or '✨'

    # 若为 .tgs 矢量动画贴纸，友好提示
    if is_animated:
        bot.reply_to(
            message,
            f"{emoji} 检测到 Telegram Lottie 矢量动画贴纸 (.tgs)。\n"
            f"💡 建议发送【视频贴纸 (WebM 动图)】或【普通贴纸】，系统将基于 WebM 专属调色板算法为您生成极致画质 GIF！"
        )
        return

    status_msg = bot.reply_to(message, f"{emoji} 正在下载贴纸并转码为 APNG / WebP / GIF 全套动图...")

    import tempfile
    import subprocess
    import shutil
    import zipfile

    with tempfile.TemporaryDirectory() as tmpdir:
        local_source_file = None
        try:
            file_info = bot.get_file(sticker.file_id)
            file_path = file_info.file_path

            # 自适应获取贴纸数据：
            # 在 telegram-bot-api --local 模式下，直接从本地磁盘秒读（0网络延迟与0流量）
            downloaded_bytes = None
            if file_path:
                # 1. 尝试直接作为绝对路径读取
                if os.path.isabs(file_path) and os.path.exists(file_path):
                    local_source_file = file_path
                    with open(file_path, 'rb') as f:
                        downloaded_bytes = f.read()

                # 2. 尝试从本地 telegram-bot-api 存储目录读取
                if downloaded_bytes is None:
                    candidates = [
                        f"/var/lib/telegram-bot-api/{TOKEN}/{file_path}",
                        f"/var/lib/telegram-bot-api/{file_path}",
                        f"/tmp/telegram-bot-api/{TOKEN}/{file_path}",
                        f"/tmp/telegram-bot-api/{file_path}",
                    ]
                    for cand in candidates:
                        if os.path.exists(cand) and os.path.isfile(cand):
                            local_source_file = cand
                            with open(cand, 'rb') as f:
                                downloaded_bytes = f.read()
                                break

            # 3. 若本地未找到，通过官方 Telegram API 接口下载 (绕过本地 8081 的 501 / 404 限制)
            if downloaded_bytes is None:
                import requests
                try:
                    official_url = f"https://api.telegram.org/file/bot{TOKEN}/{file_path}"
                    resp = requests.get(official_url, timeout=30)
                    if resp.status_code == 200:
                        downloaded_bytes = resp.content
                except Exception as net_e:
                    print(f"[-] 官方网络下载异常: {net_e}")

            # 4. 回退调用 bot.download_file
            if downloaded_bytes is None:
                downloaded_bytes = bot.download_file(file_path)

            if not downloaded_bytes:
                bot.edit_message_text("❌ 无法获取贴纸文件内容", chat_id=message.chat.id, message_id=status_msg.message_id)
                return

            ext = os.path.splitext(file_path)[1].lower() if file_path else ('.webm' if is_video else '.webp')
            if not ext:
                ext = '.webm' if is_video else '.webp'

            unique_id = getattr(sticker, 'file_unique_id', 'temp')
            input_path = os.path.join(tmpdir, f"input_{unique_id}{ext}")
            output_gif_path = os.path.join(tmpdir, f"sticker_{unique_id}.gif")
            output_apng_path = os.path.join(tmpdir, f"sticker_{unique_id}.png")
            output_webp_path = os.path.join(tmpdir, f"sticker_{unique_id}.webp")

            with open(input_path, 'wb') as f:
                f.write(downloaded_bytes)

            ffmpeg_bin = shutil.which("ffmpeg")
            if not ffmpeg_bin:
                bot.edit_message_text("❌ 服务器环境未找到 ffmpeg，请先安装 ffmpeg 工具。", chat_id=message.chat.id, message_id=status_msg.message_id)
                return

            gifsicle_bin = shutil.which("gifsicle")

            if is_video or ext == '.webm':
                # 动态贴纸处理:
                # 1. 转换为 GIF (采用 QQ 规范 240px + fps=12 + max_colors=128 + Gifsicle 优化)
                cmd_gif = [
                    ffmpeg_bin, "-y", "-i", input_path,
                    "-filter_complex",
                    "[0:v] fps=fps=12:round=near,scale='min(240,iw)':-1:flags=lanczos,split [a][b];"
                    "[a] palettegen=reserve_transparent=on:transparency_color=ffffff:max_colors=128 [p];"
                    "[b][p] paletteuse=alpha_threshold=128:dither=bayer:bayer_scale=3",
                    "-map_metadata", "-1",
                    output_gif_path
                ]
                subprocess.run(cmd_gif, capture_output=True, text=True, timeout=60)
                if gifsicle_bin and os.path.exists(output_gif_path):
                    opt_gif_path = os.path.join(tmpdir, f"opt_{unique_id}.gif")
                    try:
                        subprocess.run(
                            [gifsicle_bin, "-O3", "--lossy=80", output_gif_path, "-o", opt_gif_path],
                            capture_output=True, text=True, timeout=30
                        )
                        if os.path.exists(opt_gif_path) and os.path.getsize(opt_gif_path) < os.path.getsize(output_gif_path):
                            output_gif_path = opt_gif_path
                    except Exception as opt_err:
                        print(f"[-] Gifsicle 优化跳过: {opt_err}")

                # 2. 转换为 APNG (.png) (QQ 表情防检测首选: 调色板深度瘦身 + Alpha透明 + plays=0循环 + 剥离元数据)
                cmd_apng = [
                    ffmpeg_bin, "-y", "-i", input_path,
                    "-filter_complex",
                    "[0:v] fps=fps=12:round=near,scale='min(240,iw)':-1:flags=lanczos,split [a][b];"
                    "[a] palettegen=reserve_transparent=on:transparency_color=ffffff:max_colors=128 [p];"
                    "[b][p] paletteuse=alpha_threshold=128:dither=bayer:bayer_scale=3",
                    "-f", "apng",
                    "-plays", "0",
                    "-map_metadata", "-1",
                    output_apng_path
                ]
                subprocess.run(cmd_apng, capture_output=True, text=True, timeout=60)

                # 3. 转换为 动态 WebP (.webp) (超高压缩比 + 8-bit Alpha 边缘平滑无杂色)
                cmd_webp = [
                    ffmpeg_bin, "-y", "-i", input_path,
                    "-vf", "fps=fps=12:round=near,scale='min(240,iw)':-1:flags=lanczos",
                    "-c:v", "libwebp_anim",
                    "-lossless", "0",
                    "-q:v", "70",
                    "-loop", "0",
                    "-an",
                    "-map_metadata", "-1",
                    output_webp_path
                ]
                subprocess.run(cmd_webp, capture_output=True, text=True, timeout=60)
            else:
                # 静态贴纸处理:
                # 1. 转换为 GIF
                cmd_gif = [
                    ffmpeg_bin, "-y", "-i", input_path,
                    "-filter_complex",
                    "[0:v] scale='min(240,iw)':-1:flags=lanczos,split [a][b];"
                    "[a] palettegen=reserve_transparent=on:max_colors=128 [p];"
                    "[b][p] paletteuse=alpha_threshold=128",
                    "-map_metadata", "-1",
                    output_gif_path
                ]
                subprocess.run(cmd_gif, capture_output=True, text=True, timeout=60)

                # 2. 转换为 静态 PNG
                cmd_apng = [
                    ffmpeg_bin, "-y", "-i", input_path,
                    "-vf", "scale='min(240,iw)':-1:flags=lanczos",
                    "-map_metadata", "-1",
                    output_apng_path
                ]
                subprocess.run(cmd_apng, capture_output=True, text=True, timeout=60)

                # 3. 转换为 标准 WebP
                cmd_webp = [
                    ffmpeg_bin, "-y", "-i", input_path,
                    "-vf", "scale='min(240,iw)':-1:flags=lanczos",
                    "-c:v", "libwebp",
                    "-lossless", "0",
                    "-q:v", "75",
                    "-an",
                    "-map_metadata", "-1",
                    output_webp_path
                ]
                subprocess.run(cmd_webp, capture_output=True, text=True, timeout=60)

            valid_files = []
            if os.path.exists(output_apng_path) and os.path.getsize(output_apng_path) > 0:
                valid_files.append((output_apng_path, "sticker.png", "APNG 动图 / PNG"))
            if os.path.exists(output_webp_path) and os.path.getsize(output_webp_path) > 0:
                valid_files.append((output_webp_path, "sticker.webp", "动态 WebP"))
            if os.path.exists(output_gif_path) and os.path.getsize(output_gif_path) > 0:
                valid_files.append((output_gif_path, "sticker.gif", "GIF 动图"))

            if not valid_files:
                bot.edit_message_text("❌ 贴纸转码失败，未能生成有效格式文件", chat_id=message.chat.id, message_id=status_msg.message_id)
                return

            output_zip_path = os.path.join(tmpdir, f"sticker_{unique_id}.zip")
            with zipfile.ZipFile(output_zip_path, "w", compression=zipfile.ZIP_DEFLATED) as zf:
                for file_path_item, arc_name, _ in valid_files:
                    zf.write(file_path_item, arcname=arc_name)

            zip_size_kb = os.path.getsize(output_zip_path) / 1024

            file_details = []
            for file_path_item, arc_name, desc in valid_files:
                sz = os.path.getsize(file_path_item) / 1024
                file_details.append(f"• <code>{arc_name}</code> ({desc}): <b>{sz:.1f} KB</b>")
            details_str = "\n".join(file_details)

            caption_text = (
                f"{emoji} <b>贴纸转码成功！全套表情包已就绪</b>\n\n"
                f"📦 <b>归档内含文件清单:</b>\n"
                f"{details_str}\n"
                f"📊 压缩包总大小: <code>{zip_size_kb:.1f} KB</code>\n\n"
                f"✨ <b>格式特性与使用指南:</b>\n"
                f"1. <b>sticker.png (APNG)</b>: ⭐ <b>QQ 添加首选！</b> 原生动态 PNG，完美避开 QQ 对 GIF 的风控拦截和黑底压缩，直接添加即享丝滑透明动效。\n"
                f"2. <b>sticker.webp (动态 WebP)</b>: 极小体积与原生 8-bit Alpha 边缘平滑无杂色，现代应用首选。\n"
                f"3. <b>sticker.gif (标准 GIF)</b>: 传统通用格式，经 Gifsicle 极致体积优化。\n\n"
                f"💡 <b>说明:</b> Ayugram/Telegram 客户端对直发的动图会强制展开为大图且无法保存文件。打包为 ZIP 彻底规避此限制，点击下方文件卡片即可直接下载，解压后即可直接获取上述表情文件！"
            )

            zip_file_name = f"sticker_{unique_id}.zip"
            with open(output_zip_path, 'rb') as zf_obj:
                bot.send_document(
                    chat_id=message.chat.id,
                    document=zf_obj,
                    visible_file_name=zip_file_name,
                    caption=caption_text,
                    parse_mode="HTML",
                    reply_to_message_id=message.message_id
                )

            # 发送成功后删除过渡提示消息
            try:
                bot.delete_message(chat_id=message.chat.id, message_id=status_msg.message_id)
            except Exception:
                pass

        except Exception as e:
            bot.edit_message_text(f"❌ 贴纸处理异常: {e}", chat_id=message.chat.id, message_id=status_msg.message_id)
        finally:
            # 💡 核心保障：即下即清！不仅 tmpdir 临时目录会自动销毁，
            # 本地 telegram-bot-api 在数据目录下生成的原始贴纸文件也强制立即删除，确保 VPS 磁盘 0 残留！
            if local_source_file and os.path.exists(local_source_file):
                try:
                    os.remove(local_source_file)
                    print(f"[+] [即下即清] 已成功删除本地 telegram-bot-api 原始贴纸缓存: {local_source_file}")
                except Exception as del_err:
                    print(f"[-] 删除原始贴纸缓存失败: {del_err}")

@bot.message_handler(func=lambda message: message.chat.type == 'private' and message.from_user.id == ADMIN_ID,
                     content_types=['text', 'photo', 'video', 'document', 'audio', 'voice', 'animation'])
def handle_private_message(message):
    try: 
        # 0. 检测 Telegram 链接并触发 Userbot 下载
        if message.content_type == 'text':
            import re
            import json
            import subprocess
            urls = re.findall(r'(https?://t\.me/\S+)', message.text)
            if urls:
                url = urls[0]
                
                # 方案 A: 若配置了 HK-VPS Worker，优先将大流量媒体下载与转推委托给 HK-VPS 执行
                if HK_WORKER_URL:
                    status_msg = bot.reply_to(message, "⏳ 检测到 Telegram 链接，已派发至 HK-VPS 高速 Worker 处理中 (0 公网流量)...")
                    import requests
                    try:
                        headers = {}
                        if HK_WORKER_SECRET_TOKEN:
                            headers["Authorization"] = f"Bearer {HK_WORKER_SECRET_TOKEN}"
                        resp = requests.post(
                            f"{HK_WORKER_URL}/api/forward",
                            json={
                                "url": url,
                                "target_chat_id": GROUP_ID,
                                "caption": message.text,
                                "progress_chat_id": message.chat.id,
                                "progress_msg_id": status_msg.message_id,
                            },
                            headers=headers,
                            timeout=30  # 异步快速入队，30秒超时足够
                        )
                        if resp.status_code == 200:
                            res_json = resp.json()
                            if res_json.get("success"):
                                # 任务已成功排入 HK-VPS 异步队列，HK-VPS Worker 将直接原位刷新进度条与完成通知
                                return
                            else:
                                err = res_json.get("error", "未知错误")
                                bot.edit_message_text(f"❌ [HK-VPS 错误]: {err}", chat_id=message.chat.id, message_id=status_msg.message_id)
                        else:
                            try:
                                err_detail = resp.json().get("error", resp.text[:100])
                            except Exception:
                                err_detail = resp.text[:100]
                            bot.edit_message_text(f"❌ [HK-VPS HTTP {resp.status_code}]: {err_detail}", chat_id=message.chat.id, message_id=status_msg.message_id)
                    except Exception as req_err:
                        bot.edit_message_text(f"❌ 连接 HK-VPS Worker 异常: {req_err}", chat_id=message.chat.id, message_id=status_msg.message_id)
                    return

                status_msg = bot.reply_to(message, "⏳ 检测到 Telegram 链接，正在启动 Userbot 下载媒体...")
                fetch_script = os.path.join(os.path.dirname(os.path.abspath(__file__)), "fetch_link.py")
                
                # 同步调用后台 Userbot 下载脚本
                process_result = subprocess.run([sys.executable, fetch_script, url], capture_output=True, text=True)
                
                if process_result.returncode != 0:
                    bot.edit_message_text(f"❌ 下载脚本执行失败: {process_result.stderr[:100]}", chat_id=message.chat.id, message_id=status_msg.message_id)
                    return
                try:
                    res_data = json.loads(process_result.stdout)
                except Exception:
                    bot.edit_message_text(f"❌ 解析下载结果失败: {process_result.stdout[:100]}", chat_id=message.chat.id, message_id=status_msg.message_id)
                    return
                
                if "error" in res_data:
                    bot.edit_message_text(f"❌ 链接解析/下载失败: {res_data['error']}", chat_id=message.chat.id, message_id=status_msg.message_id)
                    return
                
                files = res_data.get("files", [])
                if not files:
                    bot.edit_message_text(f"❌ 未找到可下载的文件", chat_id=message.chat.id, message_id=status_msg.message_id)
                    return
                
                # 拼接保留原描述、tag 与来源链接的 final_caption
                orig_caption = res_data.get("original_caption", "").strip()
                if orig_caption:
                    final_caption = f"{orig_caption}\n\n🔗 来源: {url}"
                else:
                    final_caption = url
                if len(final_caption) > 1024:
                    suffix = f"\n\n🔗 来源: {url}"
                    final_caption = orig_caption[:max(10, 1024 - len(suffix) - 5)] + "..." + suffix

                # 转发到目标频道：智能分流大小判断与错误处理
                try:
                    use_userbot_upload = False
                    for f in files:
                        if os.path.exists(f['path']) and os.path.getsize(f['path']) > 48 * 1024 * 1024 and not is_port_open("127.0.0.1", 8081):
                            use_userbot_upload = True
                            break

                    if not use_userbot_upload:
                        try:
                            if len(files) == 1:
                                f = files[0]
                                with open(f['path'], 'rb') as file_obj:
                                    if f["type"].startswith("video/"):
                                        bot.send_video(GROUP_ID, file_obj, caption=final_caption, timeout=600)
                                    elif f["type"].startswith("image/"):
                                        bot.send_photo(GROUP_ID, file_obj, caption=final_caption, timeout=600)
                                    else:
                                        bot.send_document(GROUP_ID, file_obj, caption=final_caption, timeout=600)
                            else:
                                opened_files = []
                                try:
                                    media_list = []
                                    for i, f in enumerate(files):
                                        file_obj = open(f['path'], 'rb')
                                        opened_files.append(file_obj)
                                        
                                        cap = final_caption if i == 0 else None
                                        
                                        if f["type"].startswith("video/"):
                                            media_list.append(InputMediaVideo(file_obj, caption=cap))
                                        elif f["type"].startswith("image/"):
                                            media_list.append(InputMediaPhoto(file_obj, caption=cap))
                                        else:
                                            media_list.append(InputMediaDocument(file_obj, caption=cap))
                                    
                                    bot.send_media_group(GROUP_ID, media_list, timeout=600)
                                finally:
                                    for fo in opened_files:
                                        try:
                                            fo.close()
                                        except Exception:
                                            pass
                        except Exception as bot_send_err:
                            if "Too Large" in str(bot_send_err) or "413" in str(bot_send_err):
                                use_userbot_upload = True
                            else:
                                raise bot_send_err

                    if use_userbot_upload:
                        bot.edit_message_text("⚡ 检测到文件大于 48MB 触发官方 API 大小受限，正在启用 Userbot 2GB MTProto 高速通道直传目标频道...", chat_id=message.chat.id, message_id=status_msg.message_id)
                        for i, f in enumerate(files):
                            cap = final_caption if i == 0 else ""
                            up_res = subprocess.run([sys.executable, fetch_script, "--upload", f['path'], "--to", str(GROUP_ID), "--caption", cap or ""], capture_output=True, text=True)
                            if up_res.returncode != 0 or "error" in up_res.stdout:
                                bot.edit_message_text(f"❌ Userbot 2GB 大文件传输通道失败: {up_res.stderr or up_res.stdout[:100]}", chat_id=message.chat.id, message_id=status_msg.message_id)
                                return

                    bot.edit_message_text("✅ Userbot 下载并转发频道成功，已保留原描述与Tag。", chat_id=message.chat.id, message_id=status_msg.message_id)
                    return
                finally:
                    # 即下即清：清理本地下载的媒体临时文件，防止占满磁盘
                    for f in files:
                        p = f.get('path')
                        if p and os.path.exists(p):
                            try:
                                os.remove(p)
                            except Exception:
                                pass

        # 1. 处理合并消息（相册）
        if message.media_group_id:
            group_id = message.media_group_id
            # 初始化该相册的缓存字典
            if group_id not in media_groups:
                media_groups[group_id] = {'media': [], 'caption': None, 'caption_entities': None}
                # 启动 2 秒定时器收集碎片
                Timer(2.0, send_grouped_media, args=[group_id, GROUP_ID, message.chat.id]).start()

            # 💡 捕获并保存带有描述文本/Tag的那一条碎片信息
            if message.caption:
                media_groups[group_id]['caption'] = message.caption
                media_groups[group_id]['caption_entities'] = message.caption_entities

            # 将媒体转换为 InputMedia 对象（不再单独赋 caption，统一在合并时处理）
            input_media = None
            if message.content_type == 'photo':
                input_media = InputMediaPhoto(message.photo[-1].file_id)
            elif message.content_type == 'video':
                input_media = InputMediaVideo(message.video.file_id)
            elif message.content_type == 'document':
                input_media = InputMediaDocument(message.document.file_id)
            elif message.content_type == 'audio':
                input_media = InputMediaAudio(message.audio.file_id)

            if input_media:
                media_groups[group_id]['media'].append(input_media)

            bot.delete_message(message.chat.id, message.message_id)
            return

        # 2. 处理单条消息（单图/单视频/纯文本）
        bot.copy_message(chat_id=GROUP_ID, from_chat_id=message.chat.id, message_id=message.message_id)
        bot.send_message(message.chat.id, "✅ 单条消息（已保留原描述）已成功无痕转发。")
        bot.delete_message(chat_id=message.chat.id, message_id=message.message_id)

    except Exception as e:
        bot.send_message(message.chat.id, f"❌ 转发失败: {e}")

def clean_stale_sticker_cache():
    """定期清理本地 telegram-bot-api 与系统的孤立历史贴纸残留，防止 VPS 磁盘长期膨胀"""
    import glob
    import time
    now = time.time()
    patterns = [
        "/var/lib/telegram-bot-api/*/stickers/*",
        "/var/lib/telegram-bot-api/*/temp/*",
        "/tmp/telegram-bot-api/*",
        "/tmp/sticker_*.gif",
        "/tmp/input_*",
    ]
    cleaned_count = 0
    cleaned_bytes = 0
    for pat in patterns:
        try:
            for fpath in glob.glob(pat):
                if os.path.isfile(fpath):
                    # 清理修改时间超过 15 分钟的孤立残留文件
                    if now - os.path.getmtime(fpath) > 900:
                        try:
                            fsize = os.path.getsize(fpath)
                            os.remove(fpath)
                            cleaned_bytes += fsize
                            cleaned_count += 1
                        except Exception:
                            pass
        except Exception:
            pass
    if cleaned_count > 0:
        print(f"[*] [磁盘巡检] 已自动清理 {cleaned_count} 个历史贴纸/临时残留文件，释放磁盘: {cleaned_bytes / 1024:.1f} KB")

def start_periodic_cleaner(interval_seconds=3600):
    """启动后台定时磁盘巡检清理守护线程"""
    import threading
    import time
    def _run():
        while True:
            time.sleep(interval_seconds)
            clean_stale_sticker_cache()
    t = threading.Thread(target=_run, daemon=True)
    t.start()

if __name__ == '__main__':
    # 启动前先执行一次历史孤立缓存大扫除
    clean_stale_sticker_cache()
    # 启动后台守护定时清理线程 (每 1 小时自动巡检清理一次)
    start_periodic_cleaner(3600)
    print("机器人已启动，等待接收消息...")
    bot.infinity_polling()


