def _normalize_url(val, default_scheme="https", port_suffix=""):
    val = val.rstrip("/")
    if not val.startswith("http://") and not val.startswith("https://"):
        val = f"{default_scheme}://{val}"
    if port_suffix:
        val = f"{val}:{port_suffix}"
    return val

def get_webhook_url(base_url_raw, legacy_ip_raw, public_port):
    if base_url_raw and legacy_ip_raw:
        norm_base = _normalize_url(base_url_raw)
        norm_legacy = _normalize_url(legacy_ip_raw, port_suffix=public_port)
        if norm_base != norm_legacy:
            raise ValueError(
                f"错误: 发现互斥配置！\n"
                f"BRIDGE_PUBLIC_BASE_URL='{base_url_raw}' 与旧版 BRIDGE_SERVER_PUBLIC_IP='{legacy_ip_raw}' "
                f"解析后不一致。请仅保留 BRIDGE_PUBLIC_BASE_URL 并确保其完整合法（如 https://bot.example.com）。"
            )
        return norm_base
    elif base_url_raw:
        return _normalize_url(base_url_raw)
    elif legacy_ip_raw:
        print("警告: [DEPRECATED] 正在使用 BRIDGE_SERVER_PUBLIC_IP，此配置项已弃用。请升级为 BRIDGE_PUBLIC_BASE_URL。")
        return _normalize_url(legacy_ip_raw, port_suffix=public_port)
    else:
        raise ValueError("错误: 未配置 BRIDGE_PUBLIC_BASE_URL！启动失败。")

def format_view_url(base_url, token):
    return f"{base_url}/view?token={token}"
