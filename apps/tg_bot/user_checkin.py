#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Telegram 个人账号 (Userbot) 定时自动签到脚本
- 支持多目标任务（群聊文本打卡 + 机器人私聊按钮/指令打卡）
- 目标 1: coser鉴赏屋 闲聊频道 (-1003944232789) -> 发送 "签到"
- 目标 2: 鉴赏屋发送机 (@coserrar_bot / 8836025051) -> 点击 "🗓 每日签到" 按钮或发送 "签到"
- 支持 8 点多随机延迟防风控
- 支持每日仅签到一次状态持久化
- 支持回执反馈并私聊推送通知
"""

import os
import sys
import time
import json
import random
import asyncio
import argparse
import datetime
from telethon import TelegramClient

def load_env():
    """自动向上查找并加载 .env 文件"""
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

# 基础路径配置
BASE_DIR = os.path.dirname(os.path.abspath(__file__))
SESSION_PATH = os.path.join(BASE_DIR, "telegram_session")
STATE_FILE = os.path.join(BASE_DIR, "checkin_state.json")
LOG_FILE = "/var/log/tg_user_checkin.log"

API_ID = int(os.environ.get("TELEGRAM_USER_API_ID", 0))
API_HASH = os.environ.get("TELEGRAM_USER_API_HASH", "")

NOTIFY_BOT_TOKEN = os.environ.get("CHANNEL_BOT_TOKEN")
ADMIN_ID = os.environ.get("CHANNEL_ADMIN_ID")

# 签到任务清单
TASKS = [
    {
        "id": "group_-1003944232789",
        "name": "coser鉴赏屋 闲聊群",
        "type": "chat_text",
        "target": -1003944232789,
        "text": "签到"
    },
    {
        "id": "bot_8836025051",
        "name": "鉴赏屋发送机 机器人",
        "type": "bot_checkin",
        "target": "@coserrar_bot",  # 也兼容 8836025051
        "button_data": b"points:checkin",
        "button_keyword": "签到",
        "fallback_cmd": "/start",
        "fallback_text": "签到"
    }
]


def log(msg: str):
    timestamp = datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    formatted = f"[{timestamp}] {msg}"
    print(formatted, flush=True)
    try:
        with open(LOG_FILE, "a", encoding="utf-8") as f:
            f.write(formatted + "\n")
    except Exception:
        pass


def send_notify_message(text: str):
    """通过现有的官方 Bot 私聊通知管理员签到结果（可选）"""
    if not NOTIFY_BOT_TOKEN or not ADMIN_ID or NOTIFY_BOT_TOKEN == "replace_me":
        return
    try:
        import urllib.request
        url = f"https://api.telegram.org/bot{NOTIFY_BOT_TOKEN}/sendMessage"
        payload = json.dumps({
            "chat_id": int(ADMIN_ID),
            "text": text
        }).encode("utf-8")
        req = urllib.request.Request(url, data=payload, headers={"Content-Type": "application/json"})
        with urllib.request.urlopen(req, timeout=10) as resp:
            pass
    except Exception as e:
        log(f"⚠️ 发送通知消息失败: {e}")


def get_state() -> dict:
    if os.path.exists(STATE_FILE):
        try:
            with open(STATE_FILE, "r", encoding="utf-8") as f:
                return json.load(f)
        except Exception:
            pass
    return {}


def save_state(state: dict):
    try:
        with open(STATE_FILE, "w", encoding="utf-8") as f:
            json.dump(state, f, ensure_ascii=False, indent=2)
    except Exception as e:
        log(f"⚠️ 保存状态文件失败: {e}")


async def execute_task(client: TelegramClient, task: dict, force: bool = False) -> str:
    """执行单个签到任务"""
    task_id = task["id"]
    task_name = task["name"]
    today_str = datetime.date.today().strftime("%Y-%m-%d")
    state = get_state()

    last_date = state.get(task_id, {}).get("last_date")
    if last_date == today_str and not force:
        log(f"ℹ️ [{task_name}] 今日 ({today_str}) 已完成过签到，跳过。")
        return f"[{task_name}] 今日已签到，跳过"

    target = task["target"]
    log(f"🎯 正在执行任务: {task_name} (目标: {target})...")

    try:
        entity = await client.get_entity(target)
    except Exception as e:
        log(f"❌ 无法解析目标实体 {target}: {e}")
        return f"[{task_name}] 目标解析失败: {e}"

    feedback = ""

    if task["type"] == "chat_text":
        # 群文本发送签到
        text = task.get("text", "签到")
        log(f"📤 发送群消息: '{text}' ...")
        sent = await client.send_message(entity, text)
        log(f"✅ 消息已发出 (Msg ID: {sent.id})，等待 6 秒获取回执...")
        await asyncio.sleep(6)

        try:
            async for msg in client.iter_messages(entity, limit=5):
                if msg.id > sent.id:
                    if (msg.reply_to and msg.reply_to.reply_to_msg_id == sent.id) or \
                       (msg.sender and getattr(msg.sender, "bot", False)):
                        feedback = (msg.text or "[富媒体/按钮回执]").strip().replace("\n", " ")
                        log(f"🤖 捕获到群回复: {feedback}")
                        break
        except Exception as e:
            log(f"⚠️ 捕获群回执异常: {e}")

    elif task["type"] == "bot_checkin":
        # 机器人私聊签到（优先点击按钮，兜底发送指令）
        btn_data = task.get("button_data")
        btn_keyword = task.get("button_keyword", "签到")
        clicked = False

        # 1. 检查最近的消息中是否有签到按钮
        async for msg in client.iter_messages(entity, limit=5):
            if msg.reply_markup and hasattr(msg.reply_markup, "rows"):
                for row in msg.reply_markup.rows:
                    for b in row.buttons:
                        match_data = (btn_data and getattr(b, "data", None) == btn_data)
                        match_text = (btn_keyword and btn_keyword in getattr(b, "text", ""))
                        if match_data or match_text:
                            log(f"🔘 发现签到按钮 '{b.text}' (msg_id: {msg.id})，正在点击...")
                            try:
                                res = await msg.click(data=getattr(b, "data", None))
                                if res:
                                    feedback = getattr(res, "message", str(res))
                                log(f"✅ 按钮点击完成，结果: {feedback or '无弹窗返回'}")
                                clicked = True
                                break
                            except Exception as ce:
                                log(f"⚠️ 点击按钮异常: {ce}")
                    if clicked:
                        break
            if clicked:
                break

        # 2. 如果未找到按钮，先发送唤起命令 /start，等待回执后再点击
        if not clicked:
            fallback_cmd = task.get("fallback_cmd", "/start")
            log(f"ℹ️ 未在历史消息中找到签到按钮，发送 '{fallback_cmd}' 唤起控制面板...")
            await client.send_message(entity, fallback_cmd)
            await asyncio.sleep(3)

            async for msg in client.iter_messages(entity, limit=3):
                if msg.reply_markup and hasattr(msg.reply_markup, "rows"):
                    for row in msg.reply_markup.rows:
                        for b in row.buttons:
                            match_data = (btn_data and getattr(b, "data", None) == btn_data)
                            match_text = (btn_keyword and btn_keyword in getattr(b, "text", ""))
                            if match_data or match_text:
                                log(f"🔘 成功唤起并发现按钮 '{b.text}'，正在点击...")
                                try:
                                    res = await msg.click(data=getattr(b, "data", None))
                                    if res:
                                        feedback = getattr(res, "message", str(res))
                                    log(f"✅ 按钮点击完成: {feedback or '无弹窗返回'}")
                                    clicked = True
                                    break
                                except Exception as ce:
                                    log(f"⚠️ 点击按钮异常: {ce}")
                        if clicked:
                            break
                if clicked:
                    break

        # 3. 如果点击依然未成功，使用纯文本签到作为双保险
        if not clicked:
            fallback_text = task.get("fallback_text", "签到")
            log(f"ℹ️ 按钮点击未触发，使用文本双保险: 发送 '{fallback_text}' ...")
            sent = await client.send_message(entity, fallback_text)
            await asyncio.sleep(4)
            async for msg in client.iter_messages(entity, limit=2):
                if msg.id > sent.id:
                    feedback = (msg.text or "[富媒体]").strip().replace("\n", " ")
                    break

        # 4. 获取最新的回复信息
        if not feedback:
            await asyncio.sleep(2)
            async for msg in client.iter_messages(entity, limit=2):
                if not msg.out and msg.text:
                    feedback = msg.text.strip().replace("\n", " ")
                    break

        log(f"🤖 机器人最终响应: {feedback or '已执行完毕'}")

    # 保存状态
    state[task_id] = {
        "last_date": today_str,
        "last_time": datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S"),
        "task_name": task_name,
        "reply": feedback or "成功"
    }
    save_state(state)
    return f"[{task_name}] 执行成功！反馈: {feedback or '已完成'}"


async def run_all(force: bool = False):
    if not API_ID or not API_HASH:
        log("❌ 错误: .env 中缺少 TELEGRAM_USER_API_ID 或 TELEGRAM_USER_API_HASH！")
        return

    client = TelegramClient(SESSION_PATH, API_ID, API_HASH)
    await client.connect()

    if not await client.is_user_authorized():
        log("❌ 错误: Telegram 客户端未授权，请检查 session 文件！")
        await client.disconnect()
        return

    me = await client.get_me()
    user_name = me.first_name + (f" (@{me.username})" if me.username else "")
    log(f"👤 登录账号: {user_name} (ID: {me.id})")

    results = []
    for i, task in enumerate(TASKS):
        if i > 0:
            # 多个任务之间增加 4~8 秒随机等待，避免连续请求风控
            wait_s = random.randint(4, 8)
            log(f"⏳ 任务间歇等待 {wait_s} 秒...")
            await asyncio.sleep(wait_s)

        res = await execute_task(client, task, force=force)
        results.append(res)

    await client.disconnect()

    # 汇总通知
    summary = f"🎉【Telegram 每日签到汇总】\n账号: {user_name}\n时间: {datetime.datetime.now().strftime('%H:%M:%S')}\n" + "\n".join(results)
    send_notify_message(summary)
    log("🏁 全部签到任务已处理完毕。")


def main():
    parser = argparse.ArgumentParser(description="Telegram Userbot 自动签到系统（群+机器人）")
    parser.add_argument("--now", action="store_true", help="立即执行，跳过随机延迟")
    parser.add_argument("--force", action="store_true", help="强制执行，忽略今日是否已签到")
    parser.add_argument("--min-delay", type=int, default=60, help="最小随机等待秒数（默认 60s）")
    parser.add_argument("--max-delay", type=int, default=2700, help="最大随机等待秒数（默认 2700s，即 45 分钟）")

    args = parser.parse_args()

    if not args.now:
        delay_seconds = random.randint(args.min_delay, args.max_delay)
        target_time = datetime.datetime.now() + datetime.timedelta(seconds=delay_seconds)
        log(f"🎲 启动随机防风控延迟: 将随机休眠 {delay_seconds} 秒 ({delay_seconds // 60} 分钟)，预计将在 {target_time.strftime('%H:%M:%S')} 执行。")
        time.sleep(delay_seconds)

    asyncio.run(run_all(force=args.force))


if __name__ == "__main__":
    main()
