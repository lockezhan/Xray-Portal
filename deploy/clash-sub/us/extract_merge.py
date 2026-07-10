#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
节点提取与合并脚本
从美国/荷兰原始 Clash YAML 中提取 proxies，重命名后合并到基础模板
"""

import sys
import os
import yaml
import copy
import logging
import tempfile
import shutil
from typing import List, Dict, Optional

logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s [%(levelname)s] %(message)s',
    handlers=[
        logging.StreamHandler(sys.stdout),
    ]
)
logger = logging.getLogger(__name__)

# 排除的非远程代理类型（不是真实远程节点）
EXCLUDED_TYPES = {'direct', 'reject', 'dns', 'selector', 'urltest', 'fallback', 'loadbalance'}
REQUIRED_FIELDS = {'type', 'server', 'port'}


def load_yaml_safe(path: str) -> Optional[dict]:
    """安全加载 YAML 文件，返回 None 表示失败"""
    if not os.path.isfile(path):
        logger.error("文件不存在: {}".format(path))
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
    过滤掉 DIRECT/REJECT/DNS 等非远程节点
    """
    proxies = data.get('proxies', [])
    if not proxies:
        logger.error("{}: proxies 字段为空或不存在".format(source_name))
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
        # 必须有 server 和 port 字段
        if 'server' not in p or 'port' not in p:
            logger.warning("节点缺少 server/port，跳过: {}".format(p.get('name', '?')))
            continue
        valid.append(copy.deepcopy(p))

    logger.info("{}: 提取到 {} 个有效节点（原始 {} 个）".format(source_name, len(valid), len(proxies)))
    return valid


def rename_proxies(proxies: List[dict], prefix: str) -> List[dict]:
    """
    对节点统一重命名：
    - 只有1个节点时：直接命名为 prefix
    - 多个节点时：prefix-1, prefix-2, ...
    """
    if not proxies:
        return []
    renamed = []
    if len(proxies) == 1:
        p = copy.deepcopy(proxies[0])
        p['name'] = prefix
        renamed.append(p)
    else:
        for i, proxy in enumerate(proxies, 1):
            p = copy.deepcopy(proxy)
            p['name'] = "{}-{}".format(prefix, i)
            renamed.append(p)
    names = [p['name'] for p in renamed]
    logger.info("节点重命名完成: {}".format(names))
    return renamed


def build_proxy_groups(us_names: List[str], nl_names: List[str]) -> List[dict]:
    """
    构建代理组：
    - DEFAULT-US: 只含美国节点
    - SENSITIVE-NL: 只含荷兰节点
    - MANUAL: 手动选择，包含两组和 DIRECT
    """
    groups = []

    # DEFAULT-US
    if us_names:
        groups.append({
            'name': 'DEFAULT-US',
            'type': 'select',
            'proxies': us_names
        })
    else:
        logger.warning("无美国节点，DEFAULT-US 将不可用")

    # SENSITIVE-NL
    if nl_names:
        groups.append({
            'name': 'SENSITIVE-NL',
            'type': 'select',
            'proxies': nl_names
        })
    else:
        logger.warning("无荷兰节点，SENSITIVE-NL 将不可用")

    # MANUAL
    manual_proxies = []
    if us_names:
        manual_proxies.append('DEFAULT-US')
    if nl_names:
        manual_proxies.append('SENSITIVE-NL')
    manual_proxies.append('DIRECT')

    groups.append({
        'name': 'MANUAL',
        'type': 'select',
        'proxies': manual_proxies
    })

    return groups


def build_rules(us_available: bool, nl_available: bool) -> List[str]:
    """生成分流规则"""
    nl_group = 'SENSITIVE-NL' if nl_available else 'DIRECT'
    us_group = 'DEFAULT-US' if us_available else 'DIRECT'

    rules = []

    # OpenAI / ChatGPT
    for domain in ['chatgpt.com', 'openai.com', 'oaistatic.com', 'oaiusercontent.com',
                   'oaistatsig.com', 'openaimerge.com']:
        rules.append('DOMAIN-SUFFIX,{},{}'.format(domain, nl_group))

    # Claude
    for domain in ['claude.ai', 'claude.com', 'anthropic.com']:
        rules.append('DOMAIN-SUFFIX,{},{}'.format(domain, nl_group))

    # Perplexity
    rules.append('DOMAIN-SUFFIX,perplexity.ai,{}'.format(nl_group))

    # Gemini / AI Studio
    rules.append('DOMAIN,gemini.google.com,{}'.format(nl_group))
    rules.append('DOMAIN,aistudio.google.com,{}'.format(nl_group))
    rules.append('DOMAIN,generativelanguage.googleapis.com,{}'.format(nl_group))
    rules.append('DOMAIN-SUFFIX,ai.google.dev,{}'.format(nl_group))

    # 中国大陆直连
    rules.append('GEOSITE,CN,DIRECT')
    rules.append('GEOIP,CN,DIRECT,no-resolve')

    # 其余外网默认走美国
    rules.append('MATCH,{}'.format(us_group))

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
            'store-fake-ip': True,
        },
        'dns': {
            'enable': True,
            'ipv6': True,
            'respect-rules': False, # 关闭以避免缺少 proxy-server-nameserver 报错
            'enhanced-mode': 'fake-ip',
            'fake-ip-range': '198.18.0.1/16',
            'fake-ip-filter': [
                '*.lan', '*.local', 'localhost', '*.localhost',
                '*.example', 'time.windows.com', 'time.nist.gov',
                'pool.ntp.org', '*.pool.ntp.org',
            ],
            'nameserver': [
                '223.5.5.5',
                '119.29.29.29',
                'https://dns.alidns.com/dns-query',
                'https://doh.pub/dns-query',
                'https://cloudflare-dns.com/dns-query',
                'https://dns.google/dns-query',
            ],
            'fallback': [
                'https://1.1.1.1/dns-query',
                'https://8.8.8.8/dns-query',
            ],
            'fallback-filter': {
                'geoip': True,
                'geoip-code': 'CN',
                'ipcidr': ['240.0.0.0/4'],
            },
        },
    }


def validate_config(config: dict) -> bool:
    """验证生成的配置逻辑一致性"""
    proxies = config.get('proxies', [])
    proxy_names = {p['name'] for p in proxies}

    groups = config.get('proxy-groups', [])
    group_names = {g['name'] for g in groups}

    # 检查代理组引用的节点全部存在
    for group in groups:
        for ref in group.get('proxies', []):
            if ref == 'DIRECT':
                continue
            if ref not in proxy_names and ref not in group_names:
                logger.error("代理组 '{}' 引用了不存在的节点/组: {}".format(group['name'], ref))
                return False

    # 检查规则引用的代理组全部存在
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

    logger.info("配置逻辑验证通过")
    return True


def merge_and_generate(
    us_source: str,
    nl_source: str,
    output_path: str
) -> bool:
    """
    主合并函数：
    1. 加载两份原始 YAML
    2. 提取节点
    3. 重命名节点
    4. 构建完整配置
    5. 写入临时文件
    6. 验证
    7. 原子替换
    """
    logger.info("=== 开始节点提取与合并 ===")

    # 加载美国配置
    us_data = load_yaml_safe(us_source)
    if us_data is None:
        logger.error("美国配置加载失败，中止")
        return False

    # 加载荷兰配置 (允许荷兰不存在以支持单机降级容灾)
    nl_data = load_yaml_safe(nl_source)
    nl_proxies_raw = []
    if nl_data is None:
        logger.warning("荷兰配置加载失败或不存在，系统自动采用单美国节点容灾模式合并！")
    else:
        nl_proxies_raw = extract_proxies(nl_data, 'NL')

    # 提取节点
    us_proxies_raw = extract_proxies(us_data, 'US')

    if not us_proxies_raw and not nl_proxies_raw:
        logger.error("两份配置均无有效节点，中止")
        return False

    # 重命名节点
    us_proxies = rename_proxies(us_proxies_raw, 'US-MAIN')
    nl_proxies = rename_proxies(nl_proxies_raw, 'NL-SENSITIVE')

    us_names = [p['name'] for p in us_proxies]
    nl_names = [p['name'] for p in nl_proxies]

    logger.info("美国节点: {}".format(us_names))
    logger.info("荷兰节点: {}".format(nl_names))

    # 构建完整配置
    config = build_base_config()
    config['proxies'] = us_proxies + nl_proxies
    config['proxy-groups'] = build_proxy_groups(us_names, nl_names)
    config['rules'] = build_rules(bool(us_names), bool(nl_names))

    # 验证逻辑一致性
    if not validate_config(config):
        logger.error("配置逻辑验证失败，中止")
        return False

    # 写入临时文件（原子替换）
    output_dir = os.path.dirname(os.path.abspath(output_path))
    os.makedirs(output_dir, exist_ok=True)

    tmp_fd, tmp_path = tempfile.mkstemp(
        suffix='.yaml.tmp',
        dir=output_dir
    )
    try:
        with os.fdopen(tmp_fd, 'w', encoding='utf-8') as f:
            f.write("# 由 rebuild-clash-subscription 自动生成\n")
            f.write("# 生成时间: {}\n".format(__import__('datetime').datetime.now().isoformat()))
            f.write("# 请勿手动修改此文件，修改将被下次构建覆盖\n\n")
            yaml.dump(
                config,
                f,
                allow_unicode=True,
                default_flow_style=False,
                sort_keys=False,
                indent=2
            )
        # 原子替换
        shutil.move(tmp_path, output_path)
        logger.info("配置已写入: {}".format(output_path))
    except Exception as e:
        logger.error("写入配置失败: {}".format(e))
        try:
            os.unlink(tmp_path)
        except:
            pass
        return False

    return True


if __name__ == '__main__':
    if len(sys.argv) != 4:
        print("用法: {} <us-source.yaml> <nl-source.yaml> <output.yaml>".format(sys.argv[0]))
        sys.exit(1)

    us_src = sys.argv[1]
    nl_src = sys.argv[2]
    out = sys.argv[3]

    success = merge_and_generate(us_src, nl_src, out)
    sys.exit(0 if success else 1)
