import json
import requests
import urllib3
import time
import random
import os
import re

# 禁用 urllib3 的不安全请求警告
urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)

# ============ 壁纸缓存机制 ============
WALLPAPER_CACHE = {
    "time": 0,
    "images": []
}

def get_random_wallpapers():
    """获取动态壁纸，带缓存机制"""
    global WALLPAPER_CACHE
    current_time = time.time()
    cache_ttl = 3600
    count = 5

    if current_time - WALLPAPER_CACHE["time"] > cache_ttl or not WALLPAPER_CACHE["images"]:
        try:
            images = []
            api_url = "https://wallhaven.cc/api/v1/search?sorting=toplist&purity=100"
            res = requests.get(api_url, timeout=5)
            if res.status_code == 200:
                data = res.json().get('data', [])
                images = [item.get('thumbs', {}).get("large") for item in data]
                images = [url for url in images if url]
            
            if images:
                WALLPAPER_CACHE["images"] = images
                WALLPAPER_CACHE["time"] = current_time
        except Exception as e:
            print("Failed to fetch wallpapers:", e)

    pool = WALLPAPER_CACHE["images"]
    if pool:
        # 从缓存池中随机挑选5张
        return random.sample(pool, min(count, len(pool)))
    
    # 极致兜底：所有网络请求都失败时的备用图
    fallbacks = [
        "data:image/svg+xml;utf8,<svg xmlns='http://www.w3.org/2000/svg' width='1920' height='1080'><defs><linearGradient id='g' x1='0' y1='0' x2='1' y2='1'><stop offset='0%25' stop-color='%238b5cf6'/><stop offset='100%25' stop-color='%233b82f6'/></linearGradient></defs><rect width='100%25' height='100%25' fill='url(%23g)'/><circle cx='320' cy='300' r='220' fill='rgba(255,255,255,0.15)'/><circle cx='1550' cy='820' r='260' fill='rgba(255,255,255,0.12)'/></svg>"
    ]
    return fallbacks[:count] if fallbacks else []

# ============ Release 缓存机制 ============
CLASH_RELEASE_CACHE = {
    "time": 0,
    "data": []
}

def get_clash_releases():
    """从 GitHub API 获取 ClashVergeRev (Windows) 和 FlClash (Android) 的最新 Release，带缓存。"""
    global CLASH_RELEASE_CACHE
    current_time = time.time()
    cache_ttl = 3600

    if current_time - CLASH_RELEASE_CACHE["time"] < cache_ttl and CLASH_RELEASE_CACHE["data"]:
        return CLASH_RELEASE_CACHE["data"]

    repos = [
        {"repo": "clash-verge-rev/clash-verge-rev",  "label": "ClashVergeRev",  "platform": "Windows"},
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
            res = requests.get(api_url, headers=headers, timeout=10)
            if res.status_code != 200:
                print(f"GitHub API 返回 {res.status_code}（{repo_info['repo']}）")
                continue
            data = res.json()
            version = data.get("tag_name", "unknown")
            published_at = (data.get("published_at") or "")[:10]

            assets = []
            for asset in data.get("assets", []):
                name = asset.get("name", "")
                download_url = asset.get("browser_download_url", "")
                
                # 过滤安装包
                name_lower = name.lower()
                if repo_info["label"] == "ClashVergeRev":
                    # Clash Verge：只保留 Windows 版 exe 和 zip（屏蔽便携版或安装版之外的多余包），以及不保留 linux/mac 包
                    if not (name_lower.endswith('.exe') or name_lower.endswith('.zip')):
                        continue
                    if 'arm64' in name_lower or 'aarch64' in name_lower:
                        continue
                elif repo_info["label"] == "FlClash":
                    # FlClash：只保留 Android 版 apk
                    if not name_lower.endswith('.apk'):
                        continue
                    # 如果有分架构的 apk，可以保留全部或者只保留 arm64
                    
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
        CLASH_RELEASE_CACHE["data"] = results
        CLASH_RELEASE_CACHE["time"] = current_time

    return results
