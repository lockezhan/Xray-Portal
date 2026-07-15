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
    apihelper.FILE_URL = "http://127.0.0.1:8081"
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
                
                # 转发到目标频道：智能分流大小判断与错误处理
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
                                    bot.send_video(GROUP_ID, file_obj, caption=message.text, timeout=600)
                                elif f["type"].startswith("image/"):
                                    bot.send_photo(GROUP_ID, file_obj, caption=message.text, timeout=600)
                                else:
                                    bot.send_document(GROUP_ID, file_obj, caption=message.text, timeout=600)
                        else:
                            opened_files = []
                            try:
                                media_list = []
                                for i, f in enumerate(files):
                                    file_obj = open(f['path'], 'rb')
                                    opened_files.append(file_obj)
                                    
                                    # 把用户发来的包含 link 的文本，作为第一张图/视频的描述（标签）
                                    cap = message.text if i == 0 else None
                                    
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
                        cap = message.text if i == 0 else ""
                        up_res = subprocess.run([sys.executable, fetch_script, "--upload", f['path'], "--to", str(GROUP_ID), "--caption", cap or ""], capture_output=True, text=True)
                        if up_res.returncode != 0 or "error" in up_res.stdout:
                            bot.edit_message_text(f"❌ Userbot 2GB 大文件传输通道失败: {up_res.stderr or up_res.stdout[:100]}", chat_id=message.chat.id, message_id=status_msg.message_id)
                            return

                bot.edit_message_text("✅ Userbot 下载并转发频道成功，已保留原文本作为描述。", chat_id=message.chat.id, message_id=status_msg.message_id)
                return

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

if __name__ == '__main__':
    print("机器人已启动，等待接收消息...")
    bot.infinity_polling()


