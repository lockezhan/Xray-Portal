#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
节点提取与合并脚本
从美国/荷兰原始 Clash YAML 中提取 proxies，重命名后合并到基础模板
支持非对称故障转移、硬性阻断链式代理以及降级容灾模式
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

# 排除的非远程代理类型
EXCLUDED_TYPES = {'direct', 'reject', 'dns', 'selector', 'urltest', 'fallback', 'loadbalance'}
REQUIRED_FIELDS = {'type', 'server', 'port'}
CHAINED_PROXY_FIELDS = {'dialer-proxy', 'detour', 'underlying-proxy'}


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
        # 必须有 server 和 port 字段
        if 'server' not in p or 'port' not in p:
            logger.warning("节点缺少 server/port，跳过: {}".format(p.get('name', '?')))
            continue

        # 🔒 硬性审计禁止链式代理依赖字段
        found_chained = [k for k in p.keys() if k.lower() in CHAINED_PROXY_FIELDS]
        if found_chained:
            logger.error("[CRITICAL] 检测到节点 '{}' 含有禁用字段 {}, 本系统禁止任何链式代理！".format(
                p.get('name', '未知'), found_chained
            ))
            # 强行中止构建，确保漏洞不扩散
            sys.exit(1)

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
    构建非对称故障转移代理组：
    - GENERAL-PROXY: 境外普通流量代理组，fallback 自动容灾模式（美在前，荷在后）
    - SENSITIVE-NL: 仅能通过荷兰节点出站的敏感组，荷兰失效时强制 REJECT
    - MANUAL: 手动选择组
    """
    groups = []

    # 1. GENERAL-PROXY 境外普通组 (美国优先，荷兰备用)
    gp_proxies = us_names + nl_names
    if not gp_proxies:
        gp_proxies = ['DIRECT']

    # 从环境变量读取健康检查参数
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

    # 2. SENSITIVE-NL 敏感 AI 组 (只走荷兰，绝不回落美国或直连)
    if nl_names:
        groups.append({
            'name': 'SENSITIVE-NL',
            'type': 'select',
            'proxies': nl_names
        })
    else:
        logger.warning("荷兰节点完全缺失，为了防止泄露，SENSITIVE-NL 代理组已退化至内置安全策略: REJECT")
        groups.append({
            'name': 'SENSITIVE-NL',
            'type': 'select',
            'proxies': ['REJECT']
        })

    # 3. MANUAL 手动选择组
    manual_proxies = ['GENERAL-PROXY']
    if nl_names:
        manual_proxies.append('SENSITIVE-NL')
    manual_proxies.append('DIRECT')

    groups.append({
        'name': 'MANUAL',
        'type': 'select',
        'proxies': manual_proxies
    })

    return groups


def build_rules() -> List[str]:
    """生成分流规则（敏感规则在 MATCH 之前）"""
    rules = []

    # OpenAI / ChatGPT
    for domain in ['chatgpt.com', 'openai.com', 'oaistatic.com', 'oaiusercontent.com',
                   'oaistatsig.com', 'openaimerge.com']:
        rules.append('DOMAIN-SUFFIX,{},SENSITIVE-NL'.format(domain))

    # Claude
    for domain in ['claude.ai', 'claude.com', 'anthropic.com']:
        rules.append('DOMAIN-SUFFIX,{},SENSITIVE-NL'.format(domain))

    # Perplexity
    rules.append('DOMAIN-SUFFIX,perplexity.ai,SENSITIVE-NL')

    # Gemini / AI Studio
    rules.append('DOMAIN,gemini.google.com,SENSITIVE-NL')
    rules.append('DOMAIN,aistudio.google.com,SENSITIVE-NL')
    rules.append('DOMAIN,generativelanguage.googleapis.com,SENSITIVE-NL')
    rules.append('DOMAIN-SUFFIX,ai.google.dev,SENSITIVE-NL')

    # 中国大陆直连 (CN 流量)
    rules.append('GEOSITE,CN,DIRECT')
    rules.append('GEOIP,CN,DIRECT,no-resolve')

    # 其余境外普通流量走 Fallback 优先级代理组
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
            # respect-rules=True：境外域名的 DNS 查询走代理，防止 DNS 泄露
            'respect-rules': True,
            # 使用 redir-host 而非 fake-ip：
            # fake-ip 会将所有 DNS 查询强制走 DoH（HTTPS），
            # 每次解析都需要额外建立 TLS 握手，延迟从 30ms 飙升到 200-400ms。
            # redir-host 允许使用传统 UDP DNS，国内直接 30ms 内返回，
            # 境外通过 fallback 走代理解析，整体延迟降低约 30-50%。
            'enhanced-mode': 'redir-host',
            # 当 respect-rules 为 True 时，必须指定 proxy-server-nameserver，
            # 否则 Mihomo 内核启动校验会报错 "if 'respect-rules' is turned on, 'proxy-server-nameserver' cannot be empty"
            'proxy-server-nameserver': [
                '223.5.5.5',
                '119.29.29.29',
            ],
            # 国内 nameserver：纯 UDP 明文 DNS，延迟极低（约 20-50ms）
            'nameserver': [
                '223.5.5.5',    # 阿里 DNS
                '119.29.29.29', # DNSPod
            ],
            # 境外 fallback：仅用于非 CN 域名的解析，走代理转发
            # 保留 DoH 是为了防境外 DNS 污染，但仅在 fallback 触发时才使用
            'fallback': [
                '8.8.8.8',         # Google DNS UDP（通过代理）
                '1.1.1.1',         # Cloudflare DNS UDP（通过代理）
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

    # 1. 检查节点字段是否包含链式代理
    for p in proxies:
        name = p.get('name', '')
        for field in CHAINED_PROXY_FIELDS:
            val = p.get(field)
            if val:
                logger.error("节点 '{}' 含有非法的链式依赖字段: {} = {}".format(name, field, val))
                return False

        # 交叉校验：美国节点不得含有荷兰节点名作为其任何字段的值，反之亦然
        for key, val in p.items():
            if isinstance(val, str):
                if name.startswith('NL-SENSITIVE') and 'US-MAIN' in val:
                    logger.error("荷兰节点 '{}' 引用了美国节点: {} = {}".format(name, key, val))
                    return False
                if name.startswith('US-MAIN') and 'NL-SENSITIVE' in val:
                    logger.error("美国节点 '{}' 引用了荷兰节点: {} = {}".format(name, key, val))
                    return False

    # 2. 检查代理组引用的节点是否存在，且执行敏感组白名单过滤
    for group in groups:
        gname = group['name']
        group_proxies = group.get('proxies', [])

        # 敏感组 SENSITIVE-NL 绝不允许包含美国节点、GENERAL-PROXY 或 DIRECT/REJECT (REJECT 策略除外)
        if gname == 'SENSITIVE-NL':
            for ref in group_proxies:
                if ref == 'DIRECT' or ref == 'GENERAL-PROXY' or ref.startswith('US-MAIN'):
                    logger.error("SENSITIVE-NL 代理组包含非法出站目的地: {}".format(ref))
                    return False

        for ref in group_proxies:
            if ref in ('DIRECT', 'REJECT'):
                continue
            if ref not in proxy_names and ref not in group_names:
                logger.error("代理组 '{}' 引用了不存在的节点/组: {}".format(gname, ref))
                return False

    # 3. 检查规则引用的代理组是否全都合法存在
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
    us_source: str,
    nl_source: str,
    output_path: str
) -> bool:
    """主合并入口（支持美国缺失、单荷兰紧急模式构建）"""
    logger.info("=== 开始节点提取与合并 ===")

    # 加载美国配置
    us_proxies_raw = []
    if os.path.isfile(us_source):
        us_data = load_yaml_safe(us_source)
        if us_data is None:
            logger.error("美国配置存在但解析失败，可能是损坏的文件！中止构建。")
            return False
        us_proxies_raw = extract_proxies(us_data, 'US')
    else:
        logger.warning("美国配置不存在，将采用空美国节点集进行构建。")

    # 加载荷兰配置
    nl_proxies_raw = []
    if os.path.isfile(nl_source):
        nl_data = load_yaml_safe(nl_source)
        if nl_data is None:
            logger.error("荷兰配置存在但解析失败，可能是损坏的文件！中止构建。")
            return False
        nl_proxies_raw = extract_proxies(nl_data, 'NL')
    else:
        logger.warning("荷兰配置不存在，将采用空荷兰节点集进行构建。")

    # 双端缺失则中止构建
    if not us_proxies_raw and not nl_proxies_raw:
        logger.error("美国与荷兰配置源中均无任何有效的远程节点！中止构建。")
        return False

    # 重命名节点
    us_proxies = rename_proxies(us_proxies_raw, 'US-MAIN')
    nl_proxies = rename_proxies(nl_proxies_raw, 'NL-SENSITIVE')

    us_names = [p['name'] for p in us_proxies]
    nl_names = [p['name'] for p in nl_proxies]

    logger.info("美国可用节点: {}".format(us_names))
    logger.info("荷兰可用节点: {}".format(nl_names))

    # 合成最终配置
    config = build_base_config()
    config['proxies'] = us_proxies + nl_proxies
    config['proxy-groups'] = build_proxy_groups(us_names, nl_names)
    config['rules'] = build_rules()

    # 逻辑规则检测
    if not validate_config(config):
        logger.error("配置逻辑规则校验未通过！中止生成。")
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
        print("用法: {} <us-source.yaml> <nl-source.yaml> <output.yaml>".format(sys.argv[0]))
        sys.exit(1)

    us_src = sys.argv[1]
    nl_src = sys.argv[2]
    out = sys.argv[3]

    success = merge_and_generate(us_src, nl_src, out)
    sys.exit(0 if success else 1)
