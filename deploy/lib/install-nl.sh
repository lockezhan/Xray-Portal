#!/usr/bin/env bash
# =============================================================================
# Xray_portal 荷兰副服务器完整部署流水线 (deploy/lib/install-nl.sh)
#
# 12 个阶段，每阶段失败立即退出（fail-closed）
# =============================================================================

set -euo pipefail

install_nl() {
    # ------------------------------------------------------------------------
    # 解析传入选项
    # ------------------------------------------------------------------------
    local _skip_proxy="false"
    local _proxy_only="false"
    local _skip_nginx="false"
    local _no_certbot="false"
    local _state_file=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --skip-proxy)  _skip_proxy="$2"; shift 2 ;;
            --proxy-only)  _proxy_only="$2"; shift 2 ;;
            --skip-nginx)  _skip_nginx="$2"; shift 2 ;;
            --no-certbot)  _no_certbot="$2"; shift 2 ;;
            --state-file)  _state_file="$2"; shift 2 ;;
            *) shift ;;
        esac
    done

    local root_dir
    root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

    log_info "============================================================"
    log_info "  荷兰副服务器 (NL) 部署流水线启动"
    log_info "============================================================"

    # =========================================================================
    # 阶段 1: preflight
    # =========================================================================
    log_info "--- [1/12] Preflight 预检 ---"
    _nl_preflight "${root_dir}"

    # =========================================================================
    # 阶段 2: install_packages
    # =========================================================================
    log_info "--- [2/12] 安装系统依赖包 ---"
    _nl_install_packages

    # =========================================================================
    # 阶段 3: install_proxy
    # =========================================================================
    if [[ "${_skip_proxy}" == "true" ]]; then
        log_info "--- [3/12] 安装 Xray 代理 [SKIPPED: --skip-proxy] ---"
        _state_update "${_state_file}" "proxy" "skipped"
    else
        log_info "--- [3/12] 安装 Xray 代理 ---"
        _nl_install_proxy "${root_dir}"
        _state_update "${_state_file}" "proxy" "installed"
    fi

    if [[ "${_proxy_only}" == "true" ]]; then
        log_info "--- [--proxy-only 模式: 跳过阶段 4-12] ---"
        _nl_print_summary "${_state_file}" "${_skip_proxy}" "${_skip_nginx}" "${_no_certbot}"
        return 0
    fi

    # =========================================================================
    # 阶段 4: verify_xray
    # =========================================================================
    if [[ "${_skip_proxy}" == "true" ]]; then
        log_info "--- [4/12] 验证 Xray [SKIPPED] ---"
    else
        log_info "--- [4/12] 验证 Xray 服务 ---"
        # shellcheck disable=SC1091
        source "${root_dir}/apps/vpn_web/proxy/lib/verify-xray.sh"
        verify_xray || {
            log_error "[4/12] Xray 验证失败，中止部署！"
            exit 1
        }
    fi

    # =========================================================================
    # 阶段 5: generate_clash_source
    # =========================================================================
    log_info "--- [5/12] 生成荷兰 Clash 原始配置 ---"
    _nl_generate_clash_source "${root_dir}" || {
        log_error "[5/12] Clash 源生成失败，中止部署！"
        exit 1
    }

    # =========================================================================
    # 阶段 6: install_mirror_service — 建立镜像站目录和权限
    # =========================================================================
    log_info "--- [6/12] 安装订阅镜像服务 ---"
    _nl_install_mirror_service || {
        log_error "[6/12] 镜像服务安装失败！"
        exit 1
    }

    # =========================================================================
    # 阶段 7: install_push_client — 安装推送客户端脚本
    # =========================================================================
    log_info "--- [7/12] 安装订阅推送客户端 ---"
    _nl_install_push_client "${root_dir}" || {
        log_error "[7/12] 推送客户端安装失败！"
        exit 1
    }

    # =========================================================================
    # 阶段 8: configure_nginx — Nginx 配置（HTTP 阶段）
    # =========================================================================
    if [[ "${_skip_nginx}" == "true" ]]; then
        log_info "--- [8/12] Nginx 配置 [SKIPPED] ---"
        _state_update "${_state_file}" "nginx_http" "skipped"
    else
        log_info "--- [8/12] 配置 Nginx（HTTP 阶段）---"
        _nl_configure_nginx_http "${root_dir}" || {
            log_error "[8/12] Nginx HTTP 配置失败！"
            exit 1
        }
        _state_update "${_state_file}" "nginx_http" "active"
    fi

    # =========================================================================
    # 阶段 9: configure_tls — TLS 两阶段
    # =========================================================================
    if [[ "${_no_certbot}" == "true" || "${_skip_nginx}" == "true" ]]; then
        log_info "--- [9/12] TLS [SKIPPED] ---"
        _state_update "${_state_file}" "tls" "skipped"
        _state_update "${_state_file}" "nginx_tls" "skipped"
    else
        log_info "--- [9/12] 申请 TLS 证书 ---"
        _nl_configure_tls || {
            log_error "[9/12] TLS 配置失败！"
            exit 1
        }
        _state_update "${_state_file}" "tls" "active"
        _state_update "${_state_file}" "nginx_tls" "active"
    fi

    # =========================================================================
    # 阶段 10: generate_subpush_key — 生成 SSH 密钥（幂等）
    # =========================================================================
    log_info "--- [10/12] 生成订阅推送密钥 ---"
    _nl_generate_subpush_key || {
        log_error "[10/12] 密钥生成失败！"
        exit 1
    }

    # =========================================================================
    # 阶段 11: verify_local_mirror — 验证本地镜像状态
    # =========================================================================
    log_info "--- [11/12] 验证本地镜像状态 ---"
    _nl_verify_local_mirror "${_state_file}"
    # 注意: verify 仅判断状态（PENDING/PASS），不因 PENDING 中止

    # =========================================================================
    # 阶段 12: print_deployment_summary
    # =========================================================================
    log_info "--- [12/12] 生成部署摘要 ---"
    _nl_print_summary "${_state_file}" "${_skip_proxy}" "${_skip_nginx}" "${_no_certbot}"
}

# =============================================================================
# 内部函数
# =============================================================================

_nl_preflight() {
    local root_dir="$1"

    local required_files=(
        "${root_dir}/apps/vpn_web/proxy/install-noninteractive.sh"
        "${root_dir}/apps/vpn_web/proxy/gen_clash_config.sh"
        "${root_dir}/deploy/clash-sub/nl/push-clash-subscription-nl.sh"
        "${root_dir}/deploy/clash-sub/nl/nl_init.sh"
    )
    for f in "${required_files[@]}"; do
        if [[ ! -f "${f}" ]]; then
            log_error "预检失败: 仓库文件缺失: ${f}"
            exit 1
        fi
    done

    local required_vars=(NL_SUB_DOMAIN SUB_TOKEN)
    for var in "${required_vars[@]}"; do
        if [[ -z "${!var:-}" ]]; then
            log_error "预检失败: 环境变量未设置: ${var}"
            exit 1
        fi
    done

    log_success "[1/12] 预检通过"
}

_nl_install_packages() {
    if [[ "${DRY_RUN:-false}" == "true" ]]; then
        log_info "[DRY-RUN] apt-get install nginx certbot rsync curl openssl ufw"
        return 0
    fi

    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y --no-install-recommends \
        nginx \
        certbot \
        python3-certbot-nginx \
        rsync \
        curl \
        openssl \
        ufw \
        unzip \
        coreutils

    log_success "[2/12] 系统包安装完成"
}

_nl_install_proxy() {
    local root_dir="$1"

    # shellcheck disable=SC1091
    source "${root_dir}/apps/vpn_web/proxy/lib/install-xray.sh"
    # shellcheck disable=SC1091
    source "${root_dir}/apps/vpn_web/proxy/lib/render-xray-config.sh"
    # shellcheck disable=SC1091
    source "${root_dir}/apps/vpn_web/proxy/lib/firewall.sh"

    install_xray || { log_error "Xray 安装失败！"; exit 1; }
    render_xray_config || { log_error "Xray 配置渲染失败！"; exit 1; }
    configure_xray_service || { log_error "Xray 服务配置失败！"; exit 1; }
    restart_xray_service || { log_error "Xray 服务启动失败！"; exit 1; }
    configure_ufw || { log_error "UFW 配置失败！"; exit 1; }

    # BBR
    if [[ "${ENABLE_BBR:-true}" == "true" && "${DRY_RUN:-false}" != "true" ]]; then
        grep -q "net.core.default_qdisc=fq" /etc/sysctl.conf 2>/dev/null || echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
        grep -q "net.ipv4.tcp_congestion_control=bbr" /etc/sysctl.conf 2>/dev/null || echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
        sysctl -p -q 2>/dev/null || true
    fi

    log_success "[3/12] Xray 代理安装完成"
}

_nl_generate_clash_source() {
    local root_dir="$1"

    if [[ "${DRY_RUN:-false}" == "true" ]]; then
        log_info "[DRY-RUN] gen_clash_config.sh → /var/www/clash/clash.yaml"
        return 0
    fi

    if ! bash "${root_dir}/apps/vpn_web/proxy/gen_clash_config.sh"; then
        log_error "Clash 源配置生成失败！"
        return 1
    fi

    local clash_source="${CLASH_NL_SOURCE:-/var/www/clash/clash.yaml}"
    if [[ ! -f "${clash_source}" ]]; then
        log_error "Clash 源文件未生成: ${clash_source}"
        return 1
    fi

    python3 -c "import yaml; yaml.safe_load(open('${clash_source}'))" 2>/dev/null || {
        log_error "生成的 Clash 源 YAML 语法无效！"
        return 1
    }

    log_success "[5/12] 荷兰 Clash 原始配置生成完成"
}

_nl_install_mirror_service() {
    if [[ "${DRY_RUN:-false}" == "true" ]]; then
        log_info "[DRY-RUN] 建立镜像目录: ${NL_MIRROR_DIR:-/var/www/sub}/${SUB_TOKEN}"
        return 0
    fi

    # 创建 submirror 用户（幂等）
    if ! id -u "${SUBMIRROR_USER:-submirror}" >/dev/null 2>&1; then
        useradd --system --shell /bin/bash \
            --home-dir /home/submirror --create-home \
            "${SUBMIRROR_USER:-submirror}"
        log_success "创建系统用户: ${SUBMIRROR_USER:-submirror}"
    else
        log_info "系统用户已存在: ${SUBMIRROR_USER:-submirror}"
    fi

    # 建立镜像目录（权限 775，组限定）
    safe_mkdir "${NL_MIRROR_DIR:-/var/www/sub}/${SUB_TOKEN}" 0775 "root:${SUBMIRROR_GROUP:-submirror}"
    safe_mkdir "/home/${SUBMIRROR_USER:-submirror}/.ssh" 0700 "${SUBMIRROR_USER:-submirror}:${SUBMIRROR_GROUP:-submirror}"

    log_success "[6/12] 镜像服务目录初始化完成"
}

_nl_install_push_client() {
    local root_dir="$1"
    local run_user="${SUBMIRROR_USER:-submirror}"
    local run_group="${SUBMIRROR_GROUP:-submirror}"
    local work_dir="/opt/clash-sub-mirror"
    local config_path="${work_dir}/config.env"

    if [[ "${DRY_RUN:-false}" != "true" ]]; then
        # 顶层目录必须由 root 控制，防止运行用户替换 config.env。
        install -d \
            -o root \
            -g root \
            -m 0755 \
            "${work_dir}"

        # 只有日志目录需要允许 submirror 写入。
        install -d \
            -o "${run_user}" \
            -g "${run_group}" \
            -m 0750 \
            "${work_dir}/logs"

        # 临时文件必须创建在目标目录中，确保 mv 是同文件系统原子替换。
        local tmp_cfg
        tmp_cfg="$(mktemp "${work_dir}/.config.env.XXXXXX")"

        if ! cat > "${tmp_cfg}" <<EOF
US_IP=${US_SERVER_IP}
EOF
        then
            rm -f -- "${tmp_cfg}"
            log_error "生成 NL 推送配置失败"
            return 1
        fi

        # 配置由 root 管理，submirror 只能读取。
        chown root:"${run_group}" "${tmp_cfg}"
        chmod 0640 "${tmp_cfg}"

        mv -f -- "${tmp_cfg}" "${config_path}"
    else
        log_info "[DRY-RUN] 生成 ${config_path}，所有者 root:${run_group}，权限 0640"
    fi

    safe_install \
        "${root_dir}/deploy/clash-sub/nl/push-clash-subscription-nl.sh" \
        "/usr/local/sbin/push-clash-subscription-nl" \
        0755 \
        "root:root"

    safe_install \
        "${root_dir}/deploy/clash-sub/nl/nl_init.sh" \
        "/usr/local/sbin/nl_init" \
        0755 \
        "root:root"

    log_success "[7/12] 推送客户端脚本安装完成"
}

_nl_configure_nginx_http() {
    local root_dir="$1"

    if [[ "${DRY_RUN:-false}" == "true" ]]; then
        log_info "[DRY-RUN] 渲染 NL Nginx HTTP 配置"
        return 0
    fi

    mkdir -p /etc/nginx/sites-available

    # 删除 default 站点
    if [[ -L /etc/nginx/sites-enabled/default ]]; then
        local default_target
        default_target=$(readlink -f /etc/nginx/sites-enabled/default 2>/dev/null || echo "unknown")
        echo "# default site was: ${default_target}" > /etc/nginx/sites-available/default.disabled.bak
        rm -f /etc/nginx/sites-enabled/default
    fi

    local tmp_conf
    tmp_conf=$(mktemp /tmp/nl-subscription.conf.XXXXXX)

    cat > "${tmp_conf}" <<NGINX_EOF
# 荷兰只读镜像站 - HTTP Phase 1（TLS 申请前）
server {
    listen 80;
    listen [::]:80;
    server_name ${NL_SUB_DOMAIN};

    # Let's Encrypt 验证
    location ^~ /.well-known/acme-challenge/ {
        root /var/www/html;
        default_type text/plain;
    }

    # 订阅镜像文件（Token 保护）
    location = /${SUB_TOKEN}/clash.yaml {
        alias ${NL_MIRROR_DIR:-/var/www/sub}/${SUB_TOKEN}/clash.yaml;
        add_header X-Robots-Tag "noindex, nofollow";
        add_header Content-Type "text/yaml; charset=utf-8";
        auth_basic off;
        autoindex off;
    }

    # 无 Token 路径返回 410
    location = /clash.yaml {
        return 410;
    }

    # 默认拒绝其他访问
    location / {
        return 404;
    }
}
NGINX_EOF

    chmod 644 "${tmp_conf}"
    mv -f "${tmp_conf}" /etc/nginx/sites-available/nl-subscription.conf

    ln -sf /etc/nginx/sites-available/nl-subscription.conf \
        /etc/nginx/sites-enabled/nl-subscription.conf

    # 语法测试（fail closed）
    nginx -t -q 2>&1 || {
        log_error "Nginx 语法测试失败！"
        rm -f /etc/nginx/sites-enabled/nl-subscription.conf
        return 1
    }

    systemctl reload nginx || {
        log_error "Nginx reload 失败！"
        return 1
    }

    log_success "[8/12] NL Nginx HTTP 配置部署完成"
}

_nl_configure_tls() {
    if [[ "${DRY_RUN:-false}" == "true" ]]; then
        log_info "[DRY-RUN] certbot → 渲染 NL HTTPS Nginx 配置"
        return 0
    fi

    mkdir -p /var/www/html/.well-known/acme-challenge

    if ! certbot certonly \
        --webroot \
        --webroot-path /var/www/html \
        --domain "${NL_SUB_DOMAIN}" \
        --non-interactive \
        --agree-tos \
        --email "admin@${NL_SUB_DOMAIN}" \
        --quiet 2>&1; then
        log_error "Certbot 证书申请失败！"
        return 1
    fi

    local cert_path="/etc/letsencrypt/live/${NL_SUB_DOMAIN}/fullchain.pem"
    [[ ! -f "${cert_path}" ]] && {
        log_error "证书文件不存在！"
        return 1
    }

    local tmp_conf
    tmp_conf=$(mktemp /tmp/nl-subscription-tls.conf.XXXXXX)

    cat > "${tmp_conf}" <<NGINX_EOF
# 荷兰只读镜像站 - HTTPS Phase 2
server {
    server_name ${NL_SUB_DOMAIN};
    listen 80;
    listen [::]:80;
    return 301 https://\$host\$request_uri;
}

server {
    server_name ${NL_SUB_DOMAIN};
    listen 443 ssl;
    listen [::]:443 ssl;

    ssl_certificate /etc/letsencrypt/live/${NL_SUB_DOMAIN}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${NL_SUB_DOMAIN}/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;

    location = /${SUB_TOKEN}/clash.yaml {
        alias ${NL_MIRROR_DIR:-/var/www/sub}/${SUB_TOKEN}/clash.yaml;
        add_header X-Robots-Tag "noindex, nofollow";
        add_header Content-Type "text/yaml; charset=utf-8";
    }

    location = /clash.yaml {
        return 410;
    }

    location / {
        return 404;
    }
}
NGINX_EOF

    chmod 644 "${tmp_conf}"
    mv -f "${tmp_conf}" /etc/nginx/sites-available/nl-subscription.conf

    nginx -t -q 2>&1 || {
        log_error "NL HTTPS Nginx 语法测试失败！"
        return 1
    }

    systemctl reload nginx || {
        log_error "Nginx HTTPS reload 失败！"
        return 1
    }

    log_success "[9/12] NL TLS 证书部署完成"
}

_nl_generate_subpush_key() {
    local key_path="/home/${SUBMIRROR_USER:-submirror}/.ssh/subpush_key"

    # 幂等：密钥已存在则复用
    if [[ ! -f "${key_path}" ]]; then
        # shellcheck disable=SC1091
        generate_ssh_keypair "${key_path}" \
            "nl-subpush@$(hostname)" \
            "${SUBMIRROR_USER:-submirror}:${SUBMIRROR_GROUP:-submirror}"
        log_success "[10/12] subpush SSH 密钥生成完成: ${key_path}"
    else
        log_info "SSH 推送密钥已存在，复用: ${key_path}"
    fi

    # 确保同时存在于 /opt/clash-sub-mirror/ 供客户端使用
    if [[ "${DRY_RUN:-false}" != "true" ]]; then
        cp -f "${key_path}" "/opt/clash-sub-mirror/subpush_key"
        chmod 600 "/opt/clash-sub-mirror/subpush_key"
        chown "${SUBMIRROR_USER:-submirror}:${SUBMIRROR_GROUP:-submirror}" "/opt/clash-sub-mirror/subpush_key"
    fi

    log_info "公钥内容（需手动复制到美国服务器）:"
    log_info "---"
    cat "${key_path}.pub" 2>/dev/null || log_warn "公钥文件未生成"
    log_info "---"
}

_nl_verify_local_mirror() {
    local state_file="$1"
    local mirror_file="${NL_MIRROR_DIR:-/var/www/sub}/${SUB_TOKEN}/clash.yaml"

    log_info "验证本地镜像状态..."

    # submirror 用户
    if id -u "${SUBMIRROR_USER:-submirror}" >/dev/null 2>&1; then
        log_success "[PASS] submirror 用户存在"
    else
        log_error "[FAIL] submirror 用户不存在"
    fi

    # 目录权限
    if [[ -d "${NL_MIRROR_DIR:-/var/www/sub}/${SUB_TOKEN}" ]]; then
        log_success "[PASS] 镜像目录存在"
    else
        log_error "[FAIL] 镜像目录不存在"
    fi

    # 密钥权限
    local key_path="/home/${SUBMIRROR_USER:-submirror}/.ssh/subpush_key"
    if [[ -f "${key_path}" ]]; then
        local perm
        perm=$(stat -c "%a" "${key_path}" 2>/dev/null || echo "unknown")
        if [[ "${perm}" == "600" ]]; then
            log_success "[PASS] subpush 私钥权限 0600"
        else
            log_error "[FAIL] subpush 私钥权限 ${perm}（期望 0600）"
        fi
    fi

    # 镜像文件（PENDING 状态，不报 FAIL）
    if [[ -f "${mirror_file}" ]]; then
        log_success "[PASS] 镜像文件存在: ${mirror_file}"
        _state_update "${state_file}" "subscription" "pending-mirror"
    else
        log_warn "[PENDING] 镜像文件尚未同步: ${mirror_file}"
        log_warn "  → 首份镜像需美国端生成订阅后主动推送到本机"
        _state_update "${state_file}" "subscription" "pending"
    fi
}

_nl_print_summary() {
    local state_file="$1"
    local skip_proxy="$2"
    local skip_nginx="$3"
    local no_certbot="$4"

    local key_path="/home/${SUBMIRROR_USER:-submirror}/.ssh/subpush_key.pub"
    local has_mirror_file="false"
    [[ -f "${NL_MIRROR_DIR:-/var/www/sub}/${SUB_TOKEN}/clash.yaml" ]] && has_mirror_file="true"

    log_info ""
    log_info "================================================================"
    log_info "  荷兰服务器部署摘要"
    log_info "================================================================"

    log_info ""
    log_info "【已自动完成】"
    [[ "${skip_proxy}" != "true" ]] && log_success "  ✓ Xray 代理安装"
    log_success "  ✓ Clash 原始配置生成"
    log_success "  ✓ 镜像服务目录和权限"
    log_success "  ✓ 推送客户端脚本"
    [[ "${skip_nginx}" != "true" ]] && log_success "  ✓ Nginx HTTP 配置"
    [[ "${no_certbot}" != "true" && "${skip_nginx}" != "true" ]] && log_success "  ✓ TLS 证书"
    log_success "  ✓ subpush SSH 密钥生成"

    log_info ""
    log_info "【需要人工完成】"
    log_warn "  ⊡ 将以下公钥内容复制到美国服务器（subpush 用户 authorized_keys）:"
    if [[ -f "${key_path}" ]]; then
        log_info "  $(cat "${key_path}" 2>/dev/null)"
    else
        log_warn "  （公钥文件未找到: ${key_path}）"
    fi
    log_warn "  ⊡ 执行首次节点配置推送: sudo push-clash-subscription-nl"

    log_info ""
    if [[ "${has_mirror_file}" == "true" ]]; then
        log_info "【订阅镜像状态: PASS】"
        log_info "  镜像地址: https://${NL_SUB_DOMAIN}/${SUB_TOKEN}/clash.yaml"
    else
        log_warn "【订阅镜像状态: PENDING】"
        log_warn "  首份镜像文件尚未同步，访问将返回 404"
        log_warn "  同步命令: sudo /usr/local/sbin/push-clash-subscription-nl"
    fi

    log_info ""
    log_info "【排障命令】"
    log_info "  systemctl status xray nginx"
    log_info "  sudo ./deploy/verify.sh nl --env <env-file>"
}

# 复用 US 的 _state_update 函数
_state_update() {
    local state_file="$1"
    local key="$2"
    local value="$3"

    if [[ -z "${state_file}" || "${DRY_RUN:-false}" == "true" ]]; then
        return 0
    fi
    if [[ -f "${state_file}" ]]; then
        sed -i "s|\"${key}\": \"[^\"]*\"|\"${key}\": \"${value}\"|g" "${state_file}" 2>/dev/null || true
    fi
}
