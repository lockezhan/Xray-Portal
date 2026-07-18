#!/usr/bin/env bash
# =============================================================================
# Xray_portal 机器人 (tg_bot) 独立部署模块
# =============================================================================

install_bots() {
    local root_dir="$1"
    local role="$2"

    if [[ "${ENABLE_BOTS:-false}" != "true" ]]; then
        log_info "ENABLE_BOTS 未开启，跳过 tg_bot 部署"
        if [[ "${DRY_RUN:-false}" != "true" ]]; then
            systemctl disable tgbot tg-qq-bridge >/dev/null 2>&1 || true
            systemctl stop tgbot tg-qq-bridge >/dev/null 2>&1 || true
        fi
        return 0
    fi

    if [[ "${BOT_HOST_ROLE:-none}" != "${role}" ]]; then
        log_info "当前节点角色 (${role}) 与 BOT_HOST_ROLE (${BOT_HOST_ROLE:-none}) 不匹配，跳过启动 bot"
        if [[ "${DRY_RUN:-false}" != "true" ]]; then
            systemctl disable tgbot tg-qq-bridge >/dev/null 2>&1 || true
            systemctl stop tgbot tg-qq-bridge >/dev/null 2>&1 || true
        fi
        return 0
    fi

    if [[ "${DRY_RUN:-false}" == "true" ]]; then
        log_info "[DRY-RUN] 部署 tg_bot 模块 → /usr/local/tg_bot"
        return 0
    fi

    log_info "创建 tg_bot 工作目录和缓存目录..."
    mkdir -p /usr/local/tg_bot
    mkdir -p /var/lib/tg-bridge-cache
    chmod 755 /var/lib/tg-bridge-cache

    log_info "创建 NapCat Docker 挂载目录及 OneBot 11 JSON 配置文件..."
    mkdir -p /opt/napcat/qq/stickers
    mkdir -p /opt/napcat/config
    chmod -R 777 /opt/napcat/qq

    local napcat_cfg_content='{
  "enableLocalFile2Url": true,
  "network": {
    "httpServers": [
      {
        "name": "HTTPServer",
        "enable": true,
        "port": 3000,
        "host": "0.0.0.0",
        "enableCors": true,
        "enableWebsocket": false,
        "messagePostFormat": "array",
        "token": "",
        "debug": false
      }
    ],
    "httpSseServers": [],
    "httpClients": [],
    "websocketServers": [
      {
        "name": "BridgeStreamServer",
        "enable": true,
        "host": "127.0.0.1",
        "port": 3001,
        "messagePostFormat": "array",
        "reportSelfMessage": false,
        "token": "",
        "enableForcePushEvent": false,
        "debug": false,
        "heartInterval": 30000
      }
    ],
    "websocketClients": [],
    "plugins": []
  },
  "musicSignUrl": "",
  "parseMultMsg": false,
  "imageDownloadProxy": ""
}'
    echo "${napcat_cfg_content}" > "/opt/napcat/config/onebot11.json"
    chmod 644 "/opt/napcat/config/onebot11.json"

    for cfg_file in /opt/napcat/config/onebot11_*.json; do
        if [[ -f "${cfg_file}" ]]; then
            echo "${napcat_cfg_content}" > "${cfg_file}"
            chmod 644 "${cfg_file}"
        fi
    done

    install -o root -g root -m 0755 "${root_dir}/apps/tg_bot/tg_bot.py" /usr/local/tg_bot/tg_bot.py
    install -o root -g root -m 0755 "${root_dir}/apps/tg_bot/bridge_bot.py" /usr/local/tg_bot/bridge_bot.py
    install -o root -g root -m 0755 "${root_dir}/apps/tg_bot/fetch_link.py" /usr/local/tg_bot/fetch_link.py
    install -o root -g root -m 0755 "${root_dir}/apps/tg_bot/login_userbot.py" /usr/local/tg_bot/login_userbot.py

    local env_dest="/usr/local/tg_bot/.env"

    cat > "${env_dest}" <<ENVEOF
# 由 install-bots.sh 自动生成
CHANNEL_BOT_TOKEN=${CHANNEL_BOT_TOKEN:-}
CHANNEL_ADMIN_ID=${CHANNEL_ADMIN_ID:-}
CHANNEL_GROUP_ID=${CHANNEL_GROUP_ID:-}
BRIDGE_BOT_TOKEN=${BRIDGE_BOT_TOKEN:-}
BRIDGE_TARGET_QQ_GROUP=${BRIDGE_TARGET_QQ_GROUP:-}
BRIDGE_TARGET_QQ_TYPE=${BRIDGE_TARGET_QQ_TYPE:-group}
BRIDGE_PUBLIC_BASE_URL=${BRIDGE_PUBLIC_BASE_URL:-}
BRIDGE_WEB_HOST=${BRIDGE_WEB_HOST:-127.0.0.1}
BRIDGE_WEB_PORT=${BRIDGE_WEB_PORT:-8082}
BRIDGE_PUBLIC_PORT=${BRIDGE_PUBLIC_PORT:-8083}
BRIDGE_NAPCAT_API_URL=${BRIDGE_NAPCAT_API_URL:-http://127.0.0.1:3000/send_msg}
BRIDGE_NAPCAT_TIMEOUT=${BRIDGE_NAPCAT_TIMEOUT:-300}
BRIDGE_NAPCAT_MAX_CONCURRENCY=${BRIDGE_NAPCAT_MAX_CONCURRENCY:-1}
BRIDGE_NAPCAT_WS_URL=${BRIDGE_NAPCAT_WS_URL:-ws://127.0.0.1:3001}
BRIDGE_NAPCAT_STREAM_THRESHOLD=${BRIDGE_NAPCAT_STREAM_THRESHOLD:-52428800}
BRIDGE_NAPCAT_STREAM_CHUNK_SIZE=${BRIDGE_NAPCAT_STREAM_CHUNK_SIZE:-1048576}
BRIDGE_MEDIA_GROUP_SETTLE_DELAY=${BRIDGE_MEDIA_GROUP_SETTLE_DELAY:-8}
BRIDGE_WEB_TRANSCODE_MAX_CONCURRENCY=${BRIDGE_WEB_TRANSCODE_MAX_CONCURRENCY:-1}
BRIDGE_WEB_TRANSCODE_PRESET=${BRIDGE_WEB_TRANSCODE_PRESET:-veryfast}
BRIDGE_WEB_TRANSCODE_CRF=${BRIDGE_WEB_TRANSCODE_CRF:-23}
BRIDGE_FORWARD_MODE=${BRIDGE_FORWARD_MODE:-both}
TELEGRAM_USER_API_ID=${TELEGRAM_USER_API_ID:-}
TELEGRAM_USER_API_HASH=${TELEGRAM_USER_API_HASH:-}
ENVEOF

    if [[ -n "${BRIDGE_SERVER_PUBLIC_IP:-}" ]]; then
        echo "BRIDGE_SERVER_PUBLIC_IP=${BRIDGE_SERVER_PUBLIC_IP}" >> "${env_dest}"
    fi
    chmod 600 "${env_dest}"
    chown root:root "${env_dest}"

    if [[ ! -x /usr/local/tg_bot/venv/bin/python ]]; then
        log_info "为 tg_bot 创建独立 Python 虚拟环境..."
        if ! dpkg -s python3-venv >/dev/null 2>&1; then
            log_info "正在安装 python3-venv..."
            export DEBIAN_FRONTEND=noninteractive
            apt-get update -qq || true
            apt-get install -y --no-install-recommends python3-venv || {
                log_error "安装 python3-venv 失败，无法创建虚拟环境！"
                return 1
            }
        fi
        python3 -m venv /usr/local/tg_bot/venv || {
            log_error "tg_bot venv 创建失败！"
            return 1
        }
    fi

    log_info "为 tg_bot 安装 Python 依赖..."
    /usr/local/tg_bot/venv/bin/pip install -q -r "${root_dir}/apps/tg_bot/requirements.txt" || {
        log_error "tg_bot 依赖安装失败！请检查网络连接。"
        return 1
    }
    log_success "tg_bot 依赖安装完成"

    # 部署 systemd 服务
    local tgbot_svc="${root_dir}/deploy/systemd/tgbot.service"
    local bridge_svc="${root_dir}/deploy/systemd/tg-qq-bridge.service"

    if [[ -f "${tgbot_svc}" ]]; then
        install -o root -g root -m 0644 "${tgbot_svc}" /etc/systemd/system/tgbot.service
    else
        log_error "tgbot.service 模板不存在！"
        return 1
    fi

    if [[ -f "${bridge_svc}" ]]; then
        install -o root -g root -m 0644 "${bridge_svc}" /etc/systemd/system/tg-qq-bridge.service
    else
        log_error "tg-qq-bridge.service 模板不存在！"
        return 1
    fi

    systemctl daemon-reload

    log_info "启用并启动 tgbot 与 tg-qq-bridge 服务..."
    systemctl enable tgbot tg-qq-bridge >/dev/null 2>&1
    systemctl restart tgbot tg-qq-bridge || {
        log_error "启动 tgbot 或 tg-qq-bridge 失败（检查 journalctl -xeu tgbot 确认原因）"
        return 1
    }

    log_success "tg_bot 模块部署完成"
}

configure_bot_nginx() {
    local role="$1"

    if [[ "${ENABLE_BOTS:-false}" != "true" || "${BOT_HOST_ROLE:-none}" != "${role}" ]]; then
        return 0
    fi

    if [[ "${DRY_RUN:-false}" == "true" ]]; then
        log_info "[DRY-RUN] 配置 Bot Nginx"
        return 0
    fi

    local base_url="${BRIDGE_PUBLIC_BASE_URL:-}"
    local bot_domain=""
    if [[ -n "${base_url}" && "${base_url}" =~ ^https?://([^/:]+) ]]; then
        bot_domain="${BASH_REMATCH[1]}"
    else
        if [[ "${role}" == "primary" ]]; then
            bot_domain="${PRIMARY_SUB_DOMAIN}"
        else
            bot_domain="${SECONDARY_SUB_DOMAIN}"
        fi
    fi

    local web_port="${BRIDGE_WEB_PORT:-8082}"
    local pub_port="${BRIDGE_PUBLIC_PORT:-8083}"

    log_info "配置 Bot Nginx (域名: ${bot_domain}, 端口: ${pub_port} -> ${web_port})"

    local conf_path="/etc/nginx/sites-available/bot.conf"
    local tmp_conf=$(mktemp)
    cat > "${tmp_conf}" <<EOF
server {
    listen ${pub_port} ssl http2;
    listen [::]:${pub_port} ssl http2;
    server_name ${bot_domain};

    ssl_certificate /etc/letsencrypt/live/${bot_domain}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${bot_domain}/privkey.pem;

    # 安全 Headers
    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;
    add_header X-Content-Type-Options nosniff;

    # 日志
    access_log /var/log/nginx/bot_access.log;
    error_log /var/log/nginx/bot_error.log;

    location / {
        proxy_pass http://127.0.0.1:${web_port};
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;

        # Disable buffering to allow smooth streaming and range requests
        proxy_buffering off;
        proxy_request_buffering off;
    }

    # Protected media alias for X-Accel-Redirect
    location /protected_media/ {
        internal;
        alias /var/lib/tg-bridge-cache/;
    }
}
EOF

    if [[ ! -f /etc/letsencrypt/live/${bot_domain}/fullchain.pem ]]; then
        log_error "Bot 部署失败: 域名 ${bot_domain} 的 TLS 证书不存在！"
        rm -f "${tmp_conf}"
        return 1
    fi

    local backup_conf=""
    if [[ -f "${conf_path}" ]]; then
        backup_conf=$(mktemp)
        cp "${conf_path}" "${backup_conf}"
    fi

    cp "${tmp_conf}" "${conf_path}"
    ln -sf "${conf_path}" /etc/nginx/sites-enabled/bot.conf

    if nginx -t >/dev/null 2>&1; then
        systemctl reload nginx || {
            log_error "Bot Nginx reload 失败"
            if [[ -n "${backup_conf}" ]]; then cp "${backup_conf}" "${conf_path}"; else rm -f "${conf_path}" /etc/nginx/sites-enabled/bot.conf; fi
            rm -f "${tmp_conf}" "${backup_conf:-}"
            return 1
        }
        log_success "Bot Nginx 配置成功"
    else
        log_error "Bot Nginx 语法检查失败，移除配置并中止部署"
        if [[ -n "${backup_conf}" ]]; then cp "${backup_conf}" "${conf_path}"; else rm -f "${conf_path}" /etc/nginx/sites-enabled/bot.conf; fi
        rm -f "${tmp_conf}" "${backup_conf:-}"
        return 1
    fi
    rm -f "${tmp_conf}" "${backup_conf:-}"
}

verify_bots() {
    local role="$1"

    if [[ "${ENABLE_BOTS:-false}" != "true" || "${BOT_HOST_ROLE:-none}" != "${role}" ]]; then
        return 0
    fi

    log_info ""
    log_info "--- Bot 服务 ---"

    local svc_res
    svc_res=$(_svc_active "tgbot.service")
    _check "tgbot.service 运行状态" "${svc_res}"

    svc_res=$(_svc_active "tg-qq-bridge.service")
    _check "tg-qq-bridge.service 运行状态" "${svc_res}"

    local web_port="${BRIDGE_WEB_PORT:-8082}"
    local port_res
    port_res=$(_port_listening "${web_port}")
    _check "本地 Bot Web 端口 (${web_port})" "${port_res}"

    local conf_res="FAIL:not-found"
    [[ -f "/etc/nginx/sites-enabled/bot.conf" ]] && conf_res="PASS"
    _check "Bot Nginx 配置文件加载状态" "${conf_res}"

    local venv_res="FAIL:not-found"
    [[ -x "/usr/local/tg_bot/venv/bin/python" ]] && venv_res="PASS"
    _check "Bot 独立虚拟环境状态" "${venv_res}"

    local env_perm_res
    env_perm_res=$(_file_perm "/usr/local/tg_bot/.env" "600")
    _check "Bot 环境变量文件权限 (0600)" "${env_perm_res}"
}

print_bot_summary() {
    local role="$1"
    if [[ "${ENABLE_BOTS:-false}" == "true" && "${BOT_HOST_ROLE:-none}" == "${role}" ]]; then
        log_info "  Bot 服务 (tgbot, tg-qq-bridge) 已部署并在当前节点运行"
    fi
}
