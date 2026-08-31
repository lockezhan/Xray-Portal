#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
IP 地理位置与国旗 Emoji 探测工具
用于在安装与生成 Clash 订阅时自动获取物理机所在国家、中文名称及国旗 Emoji
"""

import sys
import json
import urllib.request
import urllib.error

# 常见国家代码 -> 中文名称映射表
COUNTRY_CN_MAP = {
    'US': '美国',
    'KR': '韩国',
    'JP': '日本',
    'SG': '新加坡',
    'HK': '香港',
    'TW': '台湾',
    'NL': '荷兰',
    'DE': '德国',
    'GB': '英国',
    'UK': '英国',
    'FR': '法国',
    'CA': '加拿大',
    'AU': '澳大利亚',
    'RU': '俄罗斯',
    'IN': '印度',
    'TH': '泰国',
    'MY': '马来西亚',
    'VN': '越南',
    'PH': '菲律宾',
    'ID': '印尼',
    'BR': '巴西',
    'ZA': '南非',
    'CH': '瑞士',
    'SE': '瑞典',
    'NO': '挪威',
    'FI': '芬兰',
    'IS': '冰岛',
    'IT': '意大利',
    'ES': '西班牙',
    'TR': '土耳其',
    'AE': '阿联酋',
    'IE': '爱尔兰',
    'PL': '波兰',
    'UA': '乌克兰',
    'CN': '中国',
    'MO': '澳门',
}

def country_code_to_flag(code: str) -> str:
    """将两字母国家代码转换为对应的 Unicode 国旗 Emoji"""
    if not code or len(code) != 2 or not code.isalpha():
        return "🌐"
    code = code.upper()
    # Unicode Regional Indicator Symbol: 0x1F1E6 是 'A'
    return "".join(chr(127397 + ord(c)) for c in code)

def detect_geo(ip: str = "") -> dict:
    """
    通过多个轻量 API 探测 IP 的地理位置（国家代码、国家名、城市、国旗）
    超时时间极短（<= 3s），保证不阻塞安装流水线
    """
    res = {
        "status": "success",
        "code": "UN",
        "name_cn": "未知地区",
        "name_en": "Unknown",
        "city": "",
        "flag": "🌐"
    }

    # API 1: ip-api.com
    try:
        url = f"http://ip-api.com/json/{ip}?fields=status,country,countryCode,city" if ip else "http://ip-api.com/json/?fields=status,country,countryCode,city"
        req = urllib.request.Request(url, headers={"User-Agent": "curl/7.88.1"})
        with urllib.request.urlopen(req, timeout=3) as resp:
            data = json.loads(resp.read().decode('utf-8'))
            if data.get('status') == 'success':
                code = data.get('countryCode', '').upper()
                name_en = data.get('country', '')
                city = data.get('city', '')
                if code:
                    res["code"] = code
                    res["name_en"] = name_en
                    res["name_cn"] = COUNTRY_CN_MAP.get(code, name_en)
                    res["city"] = city
                    res["flag"] = country_code_to_flag(code)
                    return res
    except Exception:
        pass

    # API 2: ipinfo.io
    try:
        url = f"https://ipinfo.io/{ip}/json" if ip else "https://ipinfo.io/json"
        req = urllib.request.Request(url, headers={"User-Agent": "curl/7.88.1"})
        with urllib.request.urlopen(req, timeout=3) as resp:
            data = json.loads(resp.read().decode('utf-8'))
            code = data.get('country', '').upper()
            city = data.get('city', '')
            if code:
                res["code"] = code
                res["name_en"] = code
                res["name_cn"] = COUNTRY_CN_MAP.get(code, code)
                res["city"] = city
                res["flag"] = country_code_to_flag(code)
                return res
    except Exception:
        pass

    # API 3: country.is
    try:
        url = f"https://api.country.is/{ip}" if ip else "https://api.country.is/"
        req = urllib.request.Request(url, headers={"User-Agent": "curl/7.88.1"})
        with urllib.request.urlopen(req, timeout=3) as resp:
            data = json.loads(resp.read().decode('utf-8'))
            code = data.get('country', '').upper()
            if code:
                res["code"] = code
                res["name_en"] = code
                res["name_cn"] = COUNTRY_CN_MAP.get(code, code)
                res["flag"] = country_code_to_flag(code)
                return res
    except Exception:
        pass

    return res

if __name__ == '__main__':
    target_ip = sys.argv[1] if len(sys.argv) > 1 else ""
    format_type = sys.argv[2] if len(sys.argv) > 2 else "env"

    geo = detect_geo(target_ip)
    
    if format_type == "json":
        print(json.dumps(geo, ensure_ascii=False))
    elif format_type == "flag":
        print(geo["flag"])
    elif format_type == "name":
        print(geo["name_cn"])
    elif format_type == "prefix":
        # 输出完整前缀，如 "🇰🇷 韩国" 或 "🇺🇸 美国"
        print(f"{geo['flag']} {geo['name_cn']}")
    else:
        # 默认输出可供 bash eval 的环境变量键值对
        print(f"PROXY_COUNTRY_CODE=\"{geo['code']}\"")
        print(f"PROXY_COUNTRY_NAME=\"{geo['name_cn']}\"")
        print(f"PROXY_COUNTRY_FLAG=\"{geo['flag']}\"")
        print(f"PROXY_CITY=\"{geo['city']}\"")

