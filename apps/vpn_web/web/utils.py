import json
import requests
import urllib3
import time
import random
import os
import re
import threading

# 禁用 urllib3 的不安全请求警告
urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)

# ============ 壁纸缓存与异步更新机制 ============
WALLPAPER_CACHE = {
    "time": 0,
    "images": []
}
_WALLPAPER_UPDATING = False
_WALLPAPER_LOCK = threading.Lock()

def _async_fetch_wallpapers():
    global _WALLPAPER_UPDATING, WALLPAPER_CACHE
    try:
        api_url = "https://wallhaven.cc/api/v1/search?sorting=toplist&purity=100"
        res = requests.get(api_url, timeout=5)
        if res.status_code == 200:
            data = res.json().get('data', [])
            images = [item.get('thumbs', {}).get("large") for item in data]
            images = [url for url in images if url]
            if images:
                with _WALLPAPER_LOCK:
                    WALLPAPER_CACHE["images"] = images
                    WALLPAPER_CACHE["time"] = time.time()
    except Exception as e:
        print("Failed to fetch wallpapers in background:", e)
    finally:
        _WALLPAPER_UPDATING = False

def get_random_wallpapers():
    """获取动态壁纸（0ms 立即返回，后台异步刷新，绝不同步阻塞页面渲染）"""
    global _WALLPAPER_UPDATING, WALLPAPER_CACHE
    current_time = time.time()
    cache_ttl = 3600
    count = 5

    # 如果缓存过期且当前未在更新中，后台线程异步抓取
    if (current_time - WALLPAPER_CACHE["time"] > cache_ttl or not WALLPAPER_CACHE["images"]) and not _WALLPAPER_UPDATING:
        _WALLPAPER_UPDATING = True
        threading.Thread(target=_async_fetch_wallpapers, daemon=True).start()

    with _WALLPAPER_LOCK:
        pool = WALLPAPER_CACHE["images"]

    if pool:
        return random.sample(pool, min(count, len(pool)))
    
    # 优质极速兜底
    fallbacks = [
        "data:image/svg+xml;utf8,<svg xmlns='http://www.w3.org/2000/svg' width='1920' height='1080'><defs><linearGradient id='g' x1='0' y1='0' x2='1' y2='1'><stop offset='0%25' stop-color='%238b5cf6'/><stop offset='100%25' stop-color='%233b82f6'/></linearGradient></defs><rect width='100%25' height='100%25' fill='url(%23g)'/><circle cx='320' cy='300' r='220' fill='rgba(255,255,255,0.15)'/><circle cx='1550' cy='820' r='260' fill='rgba(255,255,255,0.12)'/></svg>"
    ]
    return fallbacks[:count] if fallbacks else []


# ============ Release 缓存与异步更新机制 ============
CLASH_RELEASE_CACHE = {
    "time": 0,
    "data": []
}
_RELEASE_UPDATING = False
_RELEASE_LOCK = threading.Lock()

def _async_fetch_releases():
    global _RELEASE_UPDATING, CLASH_RELEASE_CACHE
    try:
        repos = [
            {"repo": "clash-verge-rev/clash-verge-rev", "label": "ClashVergeRev", "platform": "Windows"},
            {"repo": "chen08209/FlClash", "label": "FlClash", "platform": "Android"},
        ]

        headers = {
            "Accept": "application/vnd.github.v3+json",
            "User-Agent": "Mozilla/5.0"
        }
        token = os.environ.get("GITHUB_TOKEN", "")
        if token:
            headers["Authorization"] = f"token {token}"

        results = []
        for repo_info in repos:
            try:
                api_url = f"https://api.github.com/repos/{repo_info['repo']}/releases/latest"
                res = requests.get(api_url, headers=headers, timeout=8)
                if res.status_code != 200:
                    continue
                data = res.json()
                version = data.get("tag_name", "unknown")
                published_at = (data.get("published_at") or "")[:10]

                assets = []
                for asset in data.get("assets", []):
                    name = asset.get("name", "")
                    download_url = asset.get("browser_download_url", "")
                    name_lower = name.lower()
                    if repo_info["label"] == "ClashVergeRev":
                        if not (name_lower.endswith('.exe') or name_lower.endswith('.zip')):
                            continue
                        if 'arm64' in name_lower or 'aarch64' in name_lower:
                            continue
                    elif repo_info["label"] == "FlClash":
                        if not name_lower.endswith('.apk'):
                            continue
                        if 'arm' not in name_lower and 'aarch64' not in name_lower:
                            continue
                        
                    size_bytes = asset.get("size", 0)
                    if size_bytes >= 1024 * 1024:
                        size_str = f"{size_bytes / (1024 * 1024):.1f} MB"
                    elif size_bytes >= 1024:
                        size_str = f"{size_bytes / 1024:.1f} KB"
                    else:
                        size_str = f"{size_bytes} B"
                    if name and download_url:
                        assets.append({"name": name, "url": download_url, "size": size_str})

                results.append({
                    "label": repo_info["label"],
                    "platform": repo_info["platform"],
                    "version": version,
                    "published_at": published_at,
                    "assets": assets,
                })
            except Exception as e:
                print(f"获取 {repo_info['repo']} Release 失败: {e}")

        if results:
            with _RELEASE_LOCK:
                CLASH_RELEASE_CACHE["data"] = results
                CLASH_RELEASE_CACHE["time"] = time.time()
    except Exception as e:
        print("Async fetch releases error:", e)
    finally:
        _RELEASE_UPDATING = False

def get_clash_releases():
    """从 GitHub API 获取最新 Release（0ms 响应，后台异步拉取，绝不阻塞用户）"""
    global _RELEASE_UPDATING, CLASH_RELEASE_CACHE
    current_time = time.time()
    cache_ttl = 3600

    if (current_time - CLASH_RELEASE_CACHE["time"] > cache_ttl or not CLASH_RELEASE_CACHE["data"]) and not _RELEASE_UPDATING:
        _RELEASE_UPDATING = True
        threading.Thread(target=_async_fetch_releases, daemon=True).start()

    with _RELEASE_LOCK:
        return CLASH_RELEASE_CACHE["data"]
