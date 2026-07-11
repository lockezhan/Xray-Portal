#!/usr/local/vpn-web/venv/bin/python
# -*- coding: utf-8 -*-
import os
import sys
from telethon import TelegramClient

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

API_ID = os.environ.get("TELEGRAM_USER_API_ID")
API_HASH = os.environ.get("TELEGRAM_USER_API_HASH")

if not API_ID or not API_HASH:
    print("错误: 请先在 .env 中配置 TELEGRAM_USER_API_ID 和 TELEGRAM_USER_API_HASH！")
    sys.exit(1)

try:
    API_ID = int(API_ID)
except ValueError:
    print("错误: TELEGRAM_USER_API_ID 必须为整数数字！")
    sys.exit(1)

SESSION_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "telegram_session")

print("正在初始化 Telegram 客户端，请按照终端提示输入手机号、验证码以及两步验证密码（若有）...")
client = TelegramClient(SESSION_PATH, API_ID, API_HASH)

async def main():
    await client.start()
    if await client.is_user_authorized():
        print(f"🎉 授权成功！Session 文件已生成在: {SESSION_PATH}.session")
    else:
        print("❌ 授权失败，请重新运行脚本。")

if __name__ == "__main__":
    import asyncio
    asyncio.run(main())
