#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
节点提取与主从多端融合脚本
从 Primary (主节点) 与 Secondary (副节点) 原始 Clash YAML 中提取 proxies，
自动探测并附加地理位置国旗 Emoji，构建安全分流规则体系：
- SENSITIVE-PRIMARY: 敏感 AI 服务 (OpenAI / Claude / Gemini / Google API / Perplexity 等) 强制走主节点
- GENERAL-PROXY: 境外普通流量 (亚太低延迟优先 + 主节点容灾 fallback)
- MANUAL: 手动选择组
- 中国大陆流量直连 (GEOSITE/GEOIP, CN, DIRECT)
"""

import sys
import os
import yaml
import copy
import logging
import tempfile
import shutil
import urllib.request
import json
from typing import List, Dict, Optional

logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s [%(levelname)s] %(message)s',
    handlers=[
        logging.StreamHandler(sys.stdout),
    ]
)
logger = logging.getLogger(__name__)

# 排除的非远程代理类型
EXCLUDED_TYPES = {'direct', 'reject', 'dns', 'selector', 'urltest', 'fallback', 'loadbalance'}
REQUIRED_FIELDS = {'type', 'server', 'port'}
CHAINED_PROXY_FIELDS = {'dialer-proxy', 'detour', 'underlying-proxy'}

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

_GEO_CACHE = {}

def get_flag_and_name_for_ip(ip: str) -> tuple:
    """根据 IP 探测国家国旗 Emoji 与中文名称"""
    if not ip or ip in ('127.0.0.1', 'localhost', '1.2.3.4'):
        return "🌐", "节点"
    if ip in _GEO_CACHE:
        return _GEO_CACHE[ip]

    try:
        url = f"http://ip-api.com/json/{ip}?fields=status,country,countryCode"
        req = urllib.request.Request(url, headers={"User-Agent": "curl/7.88.1"})
        with urllib.request.urlopen(req, timeout=2.5) as resp:
            data = json.loads(resp.read().decode('utf-8'))
            if data.get('status') == 'success':
                code = data.get('countryCode', '').upper()
                if len(code) == 2:
                    flag = "".join(chr(127397 + ord(c)) for c in code)
                    name = COUNTRY_CN_MAP.get(code, data.get('country', code))
                    _GEO_CACHE[ip] = (flag, name)
                    return flag, name
    except Exception:
        pass

    _GEO_CACHE[ip] = ("🌐", "节点")
    return "🌐", "节点"


def load_yaml_safe(path: str) -> Optional[dict]:
    """安全加载 YAML 文件，返回 None 表示失败"""
    if not os.path.isfile(path):
        logger.warning("文件不存在: {}".format(path))
        return None
    try:
        with open(path, 'r', encoding='utf-8') as f:
            data = yaml.safe_load(f)
        if not isinstance(data, dict):
            logger.error("YAML 根节点不是 dict: {}".format(path))
            return None
        return data
    except yaml.YAMLError as e:
        logger.error("YAML 解析失败 {}: {}".format(path, e))
        return None
    except Exception as e:
        logger.error("读取文件失败 {}: {}".format(path, e))
        return None


def extract_proxies(data: dict, source_name: str) -> List[dict]:
    """
    从 YAML dict 提取有效代理节点列表
    过滤掉 DIRECT/REJECT/DNS 等非远程节点，并硬性阻断链式依赖字段
    """
    proxies = data.get('proxies', [])
    if not proxies:
        logger.warning("{}: proxies 字段为空或不存在".format(source_name))
        return []
    if not isinstance(proxies, list):
        logger.error("{}: proxies 字段不是列表".format(source_name))
        return []

    valid = []
    for p in proxies:
        if not isinstance(p, dict):
            continue
        ptype = str(p.get('type', '')).lower()
        if ptype in EXCLUDED_TYPES:
            logger.info("跳过非远程节点: {} (type={})".format(p.get('name', '?'), ptype))
            continue
        if 'server' not in p or 'port' not in p:
            logger.warning("节点缺少 server/port，跳过: {}".format(p.get('name', '?')))
            continue

        # 🔒 硬性审计禁止链式代理依赖字段
        found_chained = [k for k in p.keys() if k.lower() in CHAINED_PROXY_FIELDS]
        if found_chained:
            logger.error("[CRITICAL] 检测到节点 '{}' 含有禁用字段 {}, 本系统禁止任何链式代理！".format(
                p.get('name', '未知'), found_chained
            ))
            sys.exit(1)

        valid.append(copy.deepcopy(p))

    logger.info("{}: 提取到 {} 个有效节点（原始 {} 个）".format(source_name, len(valid), len(proxies)))
    return valid


def format_proxies_with_geo(proxies: List[dict], default_role_label: str) -> List[dict]:
    """
    为节点添加国家国旗与友好名称：
    - 若节点原始名称已经包含 Emoji 国旗（如 🇰🇷 韩国 · IPv4），则优先沿用
    - 若节点原始名称为机械前缀（如 MyVPS-IPv4 / PRIMARY-NODE-IPv4），则通过 server IP 自动识别
    """
    if not proxies:
        return []
    
    formatted = []
    seen_names = set()

    for i, proxy in enumerate(proxies, 1):
        p = copy.deepcopy(proxy)
        orig_name = str(p.get('name', '')).strip()
        server = str(p.get('server', '')).strip()
        
        # 判断原始名字是否已包含国旗 Emoji（Unicode > 0x1F000）
        has_flag = any(ord(char) > 0x1F000 for char in orig_name)
        
        if has_flag:
            new_name = orig_name
        else:
            flag, country_name = get_flag_and_name_for_ip(server)
            net_type = "IPv6" if ":" in server else "IPv4"
            if "legacy" in orig_name.lower():
                net_type = "Legacy"
            new_name = f"{flag} {country_name} · {net_type}"
        
        # 确保名称全局唯一
        final_name = new_name
        cnt = 2
        while final_name in seen_names:
            final_name = f"{new_name} #{cnt}"
            cnt += 1

        seen_names.add(final_name)
        p['name'] = final_name
        formatted.append(p)

    names = [p['name'] for p in formatted]
    logger.info("节点国旗与名称规整完成: {}".format(names))
    return formatted


def build_proxy_groups(primary_names: List[str], secondary_names: List[str]) -> List[dict]:
    """
    构建主从代理组体系：
    - SENSITIVE-PRIMARY: 敏感 AI 服务专用组 (OpenAI / Claude / Gemini / Google API / Perplexity)，强制走主节点
    - GENERAL-PROXY: 境外普通流量代理组，fallback 自动容灾模式（香港副节点低延迟优先，主节点备用）
    - MANUAL: 手动选择组
    """
    groups = []

    # 1. GENERAL-PROXY 境外普通组 (副节点在前，主节点备用容灾)
    # 若有副节点（如香港），优先走亚太低延迟副节点，主节点作为 fallback 容灾
    gp_proxies = (secondary_names + primary_names) if secondary_names else primary_names
    if not gp_proxies:
        gp_proxies = ['DIRECT']

    url = os.environ.get("PROXY_HEALTHCHECK_URL", "https://www.gstatic.com/generate_204")
    try:
        interval = int(os.environ.get("PROXY_HEALTHCHECK_INTERVAL", "300"))
    except ValueError:
        interval = 300
    try:
        timeout = int(os.environ.get("PROXY_HEALTHCHECK_TIMEOUT", "5000"))
    except ValueError:
        timeout = 5000

    groups.append({
        'name': 'GENERAL-PROXY',
        'type': 'fallback',
        'proxies': gp_proxies,
        'url': url,
        'interval': interval,
        'timeout': timeout,
        'lazy': False,
        'expected-status': 204,
        'max-failed-times': 2
    })

    # 2. SENSITIVE-PRIMARY 敏感 AI 业务组 (强制走主节点，绝不走香港副节点或直连)
    if primary_names:
        groups.append({
            'name': 'SENSITIVE-PRIMARY',
            'type': 'select',
            'proxies': primary_names
        })
    else:
        logger.warning("主节点缺失，SENSITIVE-PRIMARY 退化至: REJECT")
        groups.append({
            'name': 'SENSITIVE-PRIMARY',
            'type': 'select',
            'proxies': ['REJECT']
        })

    # 3. MANUAL 手动选择组
    manual_proxies = ['GENERAL-PROXY', 'SENSITIVE-PRIMARY']
    manual_proxies.extend(secondary_names)
    manual_proxies.extend(primary_names)
    manual_proxies.append('DIRECT')

    # 去重
    seen = set()
    dedup_manual = []
    for item in manual_proxies:
        if item not in seen:
            seen.add(item)
            dedup_manual.append(item)

    groups.append({
        'name': 'MANUAL',
        'type': 'select',
        'proxies': dedup_manual
    })

    return groups


def build_rules() -> List[str]:
    """生成分流规则（敏感 AI 域名优先走 SENSITIVE-PRIMARY）"""
    rules = []

    # 1. OpenAI / ChatGPT
    for domain in [
        'chatgpt.com',
        'openai.com',
        'oaistatic.com',
        'oaiusercontent.com',
        'oaistatsig.com',
        'openaimerge.com'
    ]:
        rules.append(f'DOMAIN-SUFFIX,{domain},SENSITIVE-PRIMARY')

    # 2. Claude / Anthropic
    rules.append('DOMAIN,claude.ai,SENSITIVE-PRIMARY')
    rules.append('DOMAIN-SUFFIX,claude.com,SENSITIVE-PRIMARY')
    rules.append('DOMAIN-SUFFIX,anthropic.com,SENSITIVE-PRIMARY')

    # 3. Perplexity
    rules.append('DOMAIN-SUFFIX,perplexity.ai,SENSITIVE-PRIMARY')

    # 4. Google API & Gemini & AI Studio
    rules.append('DOMAIN-SUFFIX,googleapis.com,SENSITIVE-PRIMARY')
    rules.append('DOMAIN,gemini.google.com,SENSITIVE-PRIMARY')
    rules.append('DOMAIN,aistudio.google.com,SENSITIVE-PRIMARY')
    rules.append('DOMAIN-SUFFIX,ai.google.dev,SENSITIVE-PRIMARY')

    # 5. 中国大陆直连 (CN 流量)
    rules.append('GEOSITE,CN,DIRECT')
    rules.append('GEOIP,CN,DIRECT,no-resolve')

    # 6. 其余境外普通流量走 GENERAL-PROXY 优先级组
    rules.append('MATCH,GENERAL-PROXY')

    return rules


def build_base_config() -> dict:
    """构建基础 Mihomo 配置"""
    return {
        'mixed-port': 7890,
        'mode': 'rule',
        'log-level': 'warning',
        'ipv6': True,
        'unified-delay': True,
        'tcp-concurrent': True,
        'allow-lan': False,
        'profile': {
            'store-selected': True,
            'store-fake-ip': False,
        },
        'dns': {
            'enable': True,
            'ipv6': True,
            'respect-rules': True,
            'enhanced-mode': 'redir-host',
            'proxy-server-nameserver': [
                '223.5.5.5',
                '119.29.29.29',
            ],
            'nameserver': [
                '223.5.5.5',
                '119.29.29.29',
            ],
            'fallback': [
                '8.8.8.8',
                '1.1.1.1',
            ],
            'fallback-filter': {
                'geoip': True,
                'geoip-code': 'CN',
                'ipcidr': ['240.0.0.0/4'],
            },
        },
    }


def validate_config(config: dict) -> bool:
    """验证生成的配置逻辑一致性，强化交叉防链式依赖校验"""
    proxies = config.get('proxies', [])
    proxy_names = {p['name'] for p in proxies}

    groups = config.get('proxy-groups', [])
    group_names = {g['name'] for g in groups}

    overlap = proxy_names.intersection(group_names)
    if overlap:
        logger.error("检测到节点名与代理组名发生冲突: {}".format(overlap))
        return False

    for p in proxies:
        name = p.get('name', '')
        for field in CHAINED_PROXY_FIELDS:
            val = p.get(field)
            if val:
                logger.error("节点 '{}' 含有非法的链式依赖字段: {} = {}".format(name, field, val))
                return False

    for group in groups:
        gname = group['name']
        group_proxies = group.get('proxies', [])

        for ref in group_proxies:
            if ref in ('DIRECT', 'REJECT'):
                continue
            if ref not in proxy_names and ref not in group_names:
                logger.error("代理组 '{}' 引用了不存在的节点/组: {}".format(gname, ref))
                return False

    for rule in config.get('rules', []):
        parts = rule.split(',')
        if len(parts) >= 3:
            target = parts[2].strip()
            if target not in ('DIRECT', 'REJECT') and target not in group_names:
                logger.error("规则引用了不存在的代理组: {} (规则: {})".format(target, rule))
                return False
        elif len(parts) == 2 and parts[0] == 'MATCH':
            target = parts[1].strip()
            if target not in ('DIRECT', 'REJECT') and target not in group_names:
                logger.error("MATCH 规则引用了不存在的代理组: {}".format(target))
                return False

    logger.info("合并后最终 YAML 逻辑配置自检通过。")
    return True


def merge_and_generate(
    primary_source: str,
    secondary_source: str,
    output_path: str
) -> bool:
    """主合并入口（支持国家国旗 Emoji 渲染与精准分流）"""
    logger.info("=== 开始节点提取与合并 ===")

    primary_proxies_raw = []
    if os.path.isfile(primary_source):
        primary_data = load_yaml_safe(primary_source)
        if primary_data is None:
            logger.error("Primary配置存在但解析失败！中止构建。")
            return False
        primary_proxies_raw = extract_proxies(primary_data, 'PRIMARY')
    else:
        logger.warning("Primary配置不存在，将采用空Primary节点集进行构建。")

    secondary_proxies_raw = []
    if os.path.isfile(secondary_source):
        secondary_data = load_yaml_safe(secondary_source)
        if secondary_data is None:
            logger.error("Secondary配置存在但解析失败！中止构建。")
            return False
        secondary_proxies_raw = extract_proxies(secondary_data, 'SECONDARY')
    else:
        logger.warning("Secondary配置不存在，将采用空Secondary节点集进行构建。")

    if not primary_proxies_raw and not secondary_proxies_raw:
        logger.error("Primary与Secondary配置源中均无任何有效的远程节点！中止构建。")
        return False

    # 格式化节点国旗与名称
    primary_proxies = format_proxies_with_geo(primary_proxies_raw, '主节点')
    secondary_proxies = format_proxies_with_geo(secondary_proxies_raw, '副节点')

    primary_names = [p['name'] for p in primary_proxies]
    secondary_names = [p['name'] for p in secondary_proxies]

    logger.info("Primary可用节点: {}".format(primary_names))
    logger.info("Secondary可用节点: {}".format(secondary_names))

    config = build_base_config()
    config['proxies'] = primary_proxies + secondary_proxies
    config['proxy-groups'] = build_proxy_groups(primary_names, secondary_names)
    config['rules'] = build_rules()

    if not validate_config(config):
        logger.error("配置逻辑规则校验未通过！中止生成。")
        return False

    output_dir = os.path.dirname(os.path.abspath(output_path))
    os.makedirs(output_dir, exist_ok=True)

    tmp_fd, tmp_path = tempfile.mkstemp(
        suffix='.yaml.tmp',
        dir=output_dir
    )
    try:
        with os.fdopen(tmp_fd, 'w', encoding='utf-8') as f:
            f.write("# 由 Xray Portal 自动融合生成 (主从架构 + 敏感AI规则隔离)\n")
            f.write("# 生成时间: {}\n".format(__import__('datetime').datetime.now().isoformat()))
            f.write("# 包含主节点 (SENSITIVE-PRIMARY) 与附属节点 (GENERAL-PROXY)\n\n")
            yaml.dump(
                config,
                f,
                allow_unicode=True,
                default_flow_style=False,
                sort_keys=False,
                indent=2
            )
        shutil.move(tmp_path, output_path)
        logger.info("配置原子发布候选路径: {}".format(output_path))
    except Exception as e:
        logger.error("生成配置文件失败: {}".format(e))
        try:
            os.unlink(tmp_path)
        except:
            pass
        return False

    return True


if __name__ == '__main__':
    if len(sys.argv) != 4:
        print("用法: {} <primary-source.yaml> <secondary-source.yaml> <output.yaml>".format(sys.argv[0]))
        sys.exit(1)

    primary_src = sys.argv[1]
    secondary_src = sys.argv[2]
    out = sys.argv[3]

    success = merge_and_generate(primary_src, secondary_src, out)
    sys.exit(0 if success else 1)
