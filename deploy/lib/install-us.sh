#!/usr/bin/env bash
# =============================================================================
# Xray_portal 美国主控端一键自动化部署逻辑 (deploy/lib/install-us.sh)
# =============================================================================

set -euo pipefail

install_us() {
    log_info "开始执行美国主控端 (US Role) 环境初始化与脚本部署..."

    local root_dir
    root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

    # 1. 注册受限账户 subpush
    if [[ "${DRY_RUN}" == "true" ]]; then
        log_info "[DRY-RUN] 创建或检查受限服务用户: ${SUBPUSH_USER}"
    else
        if ! id -u "${SUBPUSH_USER}" >/dev/null 2>&1; then
            useradd --system --shell /bin/bash --home-dir "${US_INSTALL_DIR}" --no-create-home "${SUBPUSH_USER}"
            log_success "建立专有账户 ${SUBPUSH_USER} 成功。"
        else
            log_info "系统用户 ${SUBPUSH_USER} 已存在，继续部署。"
        fi
    fi

    # 2. 创建主干物理目录结构并设定极严物理控制
    local dirs=(incoming sources template generated published backups scripts logs)
    for sub in "${dirs[@]}"; do
        safe_mkdir "${US_INSTALL_DIR}/${sub}" 0770 "root:${SUBPUSH_GROUP}"
    done
    safe_mkdir "${US_INSTALL_DIR}/.ssh" 0700 "${SUBPUSH_USER}:${SUBPUSH_GROUP}"

    # 3. 原子安全部署核心业务脚本
    safe_install "${root_dir}/deploy/clash-sub/us/extract_merge.py" \
                 "${US_INSTALL_DIR}/scripts/extract_merge.py" 0750 "root:${SUBPUSH_GROUP}"

    safe_install "${root_dir}/deploy/clash-sub/us/upload_validator.py" \
                 "${US_INSTALL_DIR}/scripts/upload_validator.py" 0750 "root:${SUBPUSH_GROUP}"

    safe_install "${root_dir}/deploy/clash-sub/us/subpush-cmd-wrapper" \
                 "${US_INSTALL_DIR}/scripts/subpush-cmd-wrapper" 0750 "root:${SUBPUSH_GROUP}"

    safe_install "${root_dir}/deploy/clash-sub/us/rebuild-clash-subscription.sh" \
                 "/usr/local/sbin/rebuild-clash-subscription" 0755 "root:root"

    # 4. 生成订阅同步运行时安全配置文件 (0600 权限)
    local cfg_path="${US_INSTALL_DIR}/scripts/config.env"
    if [[ "${DRY_RUN}" == "true" ]]; then
        log_info "[DRY-RUN] 生成安全配置文件: ${cfg_path} (模式: 0600)"
    else
        local tmp_cfg
        tmp_cfg="$(mktemp "${US_INSTALL_DIR}/scripts/.config.env.XXXXXX")"
        cat > "${tmp_cfg}" <<EOF
# =============================================================================
# 美国订阅生成与同步专用环境运行配置 (由自动部署脚本生成)
# =============================================================================
SUB_TOKEN="${SUB_TOKEN}"
CLASH_US_SOURCE="${CLASH_US_SOURCE}"
US_PUBLISH_DIR="${US_PUBLISH_DIR}"
US_SUB_DOMAIN="${US_SUB_DOMAIN}"
NL_SUB_DOMAIN="${NL_SUB_DOMAIN}"
EOF
        chmod 600 "${tmp_cfg}"
        chown "${SUBPUSH_USER}:${SUBPUSH_GROUP}" "${tmp_cfg}"
        mv -f "${tmp_cfg}" "${cfg_path}"
        log_success "运行环境配置写入完成: ${cfg_path}"
    fi

    # 5. 自动部署 Flask 管理面板 (vpn-web)
    log_info "正在部署 Flask 管理面板 (vpn-web) 至 /usr/local/vpn-web ..."
    safe_mkdir "/usr/local/vpn-web" 0750 "root:root"

    if [[ "${DRY_RUN}" == "true" ]]; then
        log_info "[DRY-RUN] 复制 apps/vpn_web/web/ 下的核心源码至 /usr/local/vpn-web"
        log_info "[DRY-RUN] 生成面板安全凭据配置文件 /usr/local/vpn-web/config.py 与 .env (0600)"
        log_info "[DRY-RUN] 创建虚拟环境 /usr/local/vpn-web/venv 并安装依赖"
    else
        # 复制 Python 源码及 templates
        cp -a "${root_dir}/apps/vpn_web/web/app.py" "/usr/local/vpn-web/app.py"
        cp -a "${root_dir}/apps/vpn_web/web/utils.py" "/usr/local/vpn-web/utils.py"
        rm -rf "/usr/local/vpn-web/templates"
        cp -a "${root_dir}/apps/vpn_web/web/templates" "/usr/local/vpn-web/templates"
        chmod 640 /usr/local/vpn-web/*.py
        chmod -R 750 /usr/local/vpn-web/templates

        # 生成 config.py
        local tmp_portal_cfg
        tmp_portal_cfg="$(mktemp "/usr/local/vpn-web/.config.py.XXXXXX")"
        cat > "${tmp_portal_cfg}" <<EOF
import os

PORTAL_PASSWORD = "${PORTAL_PASSWORD}"
SECRET_KEY = os.environ.get("FLASK_SECRET_KEY", "${FLASK_SECRET_KEY:-$PORTAL_PASSWORD}")
EOF
        chmod 600 "${tmp_portal_cfg}"
        mv -f "${tmp_portal_cfg}" "/usr/local/vpn-web/config.py"

        # 生成 .env 运行时环境
        local tmp_portal_env
        tmp_portal_env="$(mktemp "/usr/local/vpn-web/.env.XXXXXX")"
        cat > "${tmp_portal_env}" <<EOF
SUB_TOKEN=${SUB_TOKEN}
SUB_PUBLIC_URL=https://${US_SUB_DOMAIN}/${SUB_TOKEN}/clash.yaml
SUB_PUBLIC_BASE_URL=https://${US_SUB_DOMAIN}
PORTAL_PASSWORD=${PORTAL_PASSWORD}
FLASK_SECRET_KEY=${FLASK_SECRET_KEY:-$PORTAL_PASSWORD}
EOF
        chmod 600 "${tmp_portal_env}"
        mv -f "${tmp_portal_env}" "/usr/local/vpn-web/.env"

        # 创建或复用独立 Python 虚拟环境
        if [[ ! -x "/usr/local/vpn-web/venv/bin/python" ]]; then
            log_info "初始化 /usr/local/vpn-web/venv 虚拟环境..."
            python3 -m venv "/usr/local/vpn-web/venv"
        fi

        log_info "安装 Flask 前端面板所需 Python 依赖项..."
        if ! "/usr/local/vpn-web/venv/bin/pip" install -q -r "${root_dir}/apps/vpn_web/requirements.txt"; then
            log_warn "Pip 在线依赖下载失败，请检查本机网络或代理变量设置 (如 http_proxy/https_proxy)。"
        else
            log_success "Flask 面板 Python 依赖安装就绪。"
        fi
    fi

    # 6. 注册 Systemd 守护服务 (支持 vpn-web 和 clash-subscribe 双方服务名查询)
    log_info "配置 systemd 服务 (vpn-web.service / clash-subscribe.service) ..."
    if [[ "${DRY_RUN}" == "true" ]]; then
        log_info "[DRY-RUN] 写入 /etc/systemd/system/vpn-web.service 并启用服务"
    else
        local tmp_svc
        tmp_svc="$(mktemp "/etc/systemd/system/.vpn-web.service.XXXXXX")"
        cat > "${tmp_svc}" <<EOF
[Unit]
Description=Clash Subscription YAML Web Panel (vpn-web)
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/usr/local/vpn-web
ExecStart=/usr/local/vpn-web/venv/bin/python app.py 8080
Restart=on-failure
RestartSec=5
EnvironmentFile=-/usr/local/vpn-web/.env

[Install]
WantedBy=multi-user.target
Alias=clash-subscribe.service
EOF
        chmod 644 "${tmp_svc}"
        mv -f "${tmp_svc}" "/etc/systemd/system/vpn-web.service"
        ln -sf "/etc/systemd/system/vpn-web.service" "/etc/systemd/system/clash-subscribe.service"

        if command -v systemctl >/dev/null 2>&1; then
            systemctl daemon-reload
            systemctl enable vpn-web.service >/dev/null 2>&1 || true
            if systemctl restart vpn-web.service; then
                log_success "服务 vpn-web.service 已启动并设置为开机自启。"
            else
                log_warn "服务 vpn-web.service 重启未成功，请运行 journalctl -u vpn-web -e 查看详细日志。"
            fi
        fi
    fi

    # 7. 渲染并部署 Nginx 站点配置
    local tpl="${root_dir}/deploy/nginx/us-subscription.conf.template"
    if [[ -f "${tpl}" ]]; then
        if [[ "${DRY_RUN}" == "true" ]]; then
            log_info "[DRY-RUN] 渲染 Nginx 模板 ${tpl} 至 /etc/nginx/sites-available/us-subscription.conf"
        else
            mkdir -p /etc/nginx/sites-available
            local tmp_conf
            tmp_conf="$(mktemp "/etc/nginx/sites-available/.us-subscription.conf.XXXXXX")"
            sed -e "s|\${US_SUB_DOMAIN}|${US_SUB_DOMAIN}|g" \
                -e "s|\${SUB_TOKEN}|${SUB_TOKEN}|g" "${tpl}" > "${tmp_conf}"
            chmod 644 "${tmp_conf}"
            mv -f "${tmp_conf}" /etc/nginx/sites-available/us-subscription.conf

            if [[ -d /etc/nginx/sites-enabled ]]; then
                ln -sf /etc/nginx/sites-available/us-subscription.conf /etc/nginx/sites-enabled/us-subscription.conf
            fi
            if command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet nginx; then
                systemctl reload nginx || true
            fi
            log_success "美国端 Nginx 配置渲染部署完成。"
        fi
    fi

    # 8. 自动触发首次订阅合成生成发布快照（防止首次拉取订阅报 404 Not Found）
    log_info "正在尝试合成初始订阅快照至 /opt/clash-sub/published/clash.yaml ..."
    if [[ "${DRY_RUN}" == "true" ]]; then
        log_info "[DRY-RUN] 执行 /usr/local/sbin/rebuild-clash-subscription"
    else
        if [[ -f "${CLASH_US_SOURCE:-/var/www/clash/clash.yaml}" ]]; then
            if /usr/local/sbin/rebuild-clash-subscription; then
                log_success "初始订阅快照发布完成！地址 URL 可直接拉取访问。"
            else
                log_warn "订阅合成过程提示异常，请运行 /usr/local/sbin/rebuild-clash-subscription 查看构建日志。"
            fi
        else
            log_warn "暂未在 ${CLASH_US_SOURCE:-/var/www/clash/clash.yaml} 找到美国节点源文件。若之后运行了 gen_clash_config.sh，请手动执行一条命令合成快照：sudo /usr/local/sbin/rebuild-clash-subscription"
        fi
    fi

    log_success "美国主服务器 (US Role) 一键部署处理完成。"
}
