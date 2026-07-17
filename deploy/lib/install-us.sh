#!/usr/bin/env bash
# =============================================================================
# Xray_portal 美国主控端完整部署流水线 (deploy/lib/install-us.sh)
#
# 13 个阶段，每阶段失败立即退出（fail-closed）
# 调用方式: install_us --skip-proxy false --proxy-only false ... --state-file <path>
# =============================================================================

set -euo pipefail

install_us() {
    # ------------------------------------------------------------------------
    # 解析传入选项
    # ------------------------------------------------------------------------
    local _skip_proxy="false"
    local _proxy_only="false"
    local _skip_web="false"
    local _skip_nginx="false"
    local _no_certbot="false"
    local _bots_only="false"
    local _state_file=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --skip-proxy)   _skip_proxy="$2";  shift 2 ;;
            --proxy-only)   _proxy_only="$2";  shift 2 ;;
            --skip-web)     _skip_web="$2";    shift 2 ;;
            --skip-nginx)   _skip_nginx="$2";  shift 2 ;;
            --no-certbot)   _no_certbot="$2";  shift 2 ;;
            --bots-only)    _bots_only="$2";   shift 2 ;;
            --state-file)   _state_file="$2";  shift 2 ;;
            *) shift ;;
        esac
    done

    local root_dir
    root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

    if [[ "${_bots_only}" == "true" ]]; then
        log_info "============================================================"
        log_info "  仅更新/部署 Telegram & QQ 机器人 (tg_bot) 流水线启动"
        log_info "============================================================"
        
        # 确保 vpn-web 虚拟环境存在，否则无法单独部署机器人
        if [[ ! -x /usr/local/vpn-web/venv/bin/python ]]; then
            log_error "vpn-web 虚拟环境不存在 (/usr/local/vpn-web/venv)，请先运行一次常规完整安装！"
            exit 1
        fi
        
        _us_install_tg_bot "${root_dir}" || {
            log_error "机器人模块部署失败！"
            exit 1
        }
        
        log_success "================================================================"
        log_success "  机器人部署/更新步骤已执行完毕！"
        log_info ""
        log_warn "  👉 【注意：请务必按照提示进行以下手动操作以完成最终部署】 👈"
        log_warn "  1. 授权登录 Telegram 账号（如果是初次部署，请运行以下命令进行登录）："
        log_warn "     /usr/local/vpn-web/venv/bin/python /usr/local/tg_bot/login_userbot.py"
        log_warn ""
        log_warn "  2. 启用并立即启动系统服务（如果您还未启用它们）："
        log_warn "     sudo systemctl daemon-reload"
        log_warn "     sudo systemctl enable --now tgbot tg-qq-bridge"
        log_warn ""
        if [[ "${ENABLE_BOTS:-false}" != "true" ]]; then
            log_info "  * 当前主配置文件中 ENABLE_BOTS 为 false（未开启状态）。"
            log_info "    如果您稍后修改为 true 并重跑脚本，它们会自动启动；或者您可以随时手动执行上述 enable 命令启动。"
        fi
        log_success "================================================================"
        return 0
    fi

    log_info "============================================================"
    log_info "  美国主服务器 (US) 部署流水线启动"
    log_info "============================================================"

    # =========================================================================
    # 阶段 1: preflight — 环境预检
    # =========================================================================
    log_info "--- [1/13] Preflight 预检 ---"
    _us_preflight "${root_dir}"

    # =========================================================================
    # 阶段 2: install_packages — 安装系统包
    # =========================================================================
    log_info "--- [2/13] 安装系统依赖包 ---"
    _us_install_packages

    # =========================================================================
    # 阶段 3: install_proxy — 安装 Xray 代理
    # =========================================================================
    if [[ "${_skip_proxy}" == "true" ]]; then
        log_info "--- [3/13] 安装 Xray 代理 [SKIPPED: --skip-proxy] ---"
        _state_update "${_state_file}" "proxy" "skipped"
    else
        log_info "--- [3/13] 安装 Xray 代理 ---"
        _us_install_proxy "${root_dir}"
        _state_update "${_state_file}" "proxy" "installed"
    fi

    if [[ "${_proxy_only}" == "true" ]]; then
        log_info "--- [--proxy-only 模式: 跳过控制面阶段 4-13] ---"
        _us_print_summary "${_state_file}" "${_skip_proxy}" "${_proxy_only}" "${_skip_web}" "${_skip_nginx}" "${_no_certbot}"
        return 0
    fi

    # =========================================================================
    # 阶段 4: verify_xray — 验证 Xray
    # =========================================================================
    if [[ "${_skip_proxy}" == "true" ]]; then
        log_info "--- [4/13] 验证 Xray [SKIPPED: --skip-proxy] ---"
    else
        log_info "--- [4/13] 验证 Xray 服务 ---"
        # shellcheck disable=SC1091
        source "${root_dir}/apps/vpn_web/proxy/lib/verify-xray.sh"
        verify_xray || {
            log_error "[4/13] Xray 验证失败，中止部署！"
            exit 1
        }
    fi

    # =========================================================================
    # 阶段 5: generate_clash_source — 生成本机 Clash 原始配置
    # =========================================================================
    log_info "--- [5/13] 生成 Clash 原始配置 ---"
    _us_generate_clash_source "${root_dir}" || {
        log_error "[5/13] Clash 源配置生成失败，中止部署！"
        exit 1
    }

    # =========================================================================
    # 阶段 6: install_clash_builder — 安装 Mihomo + 订阅构建脚本
    # =========================================================================
    log_info "--- [6/13] 安装 Clash 订阅构建器 ---"
    _us_install_clash_builder "${root_dir}" || {
        log_error "[6/13] Clash 构建器安装失败，中止部署！"
        exit 1
    }

    # =========================================================================
    # 阶段 7: install_vpn_web — 部署 Flask Web 面板
    # =========================================================================
    if [[ "${_skip_web}" == "true" ]]; then
        log_info "--- [7/13] 部署 Web 面板与机器人 [SKIPPED: --skip-web] ---"
        _state_update "${_state_file}" "web" "skipped"
    else
        log_info "--- [7/13] 部署 Flask Web 面板 ---"
        _us_install_vpn_web "${root_dir}" || {
            log_error "[7/13] Web 面板部署失败，中止部署！"
            exit 1
        }
        log_info "--- [7.5] 部署 Telegram & QQ 机器人 (tg_bot) ---"
        _us_install_tg_bot "${root_dir}" || {
            log_error "[7.5] 机器人模块部署失败，中止部署！"
            exit 1
        }
        _state_update "${_state_file}" "web" "active"
    fi

    # =========================================================================
    # 阶段 8: verify_vpn_web_local — 本地健康检查
    # =========================================================================
    if [[ "${_skip_web}" == "true" ]]; then
        log_info "--- [8/13] Web 健康检查 [SKIPPED: --skip-web] ---"
    else
        log_info "--- [8/13] 本地 Web 健康检查 ---"
        _us_verify_vpn_web_local || {
            log_error "[8/13] Web 健康检查失败，禁止继续配置 Nginx 指向死后端！"
            exit 1
        }
    fi

    # =========================================================================
    # 阶段 9: configure_nginx — 配置 Nginx（HTTP 阶段）
    # =========================================================================
    if [[ "${_skip_nginx}" == "true" ]]; then
        log_info "--- [9/13] Nginx 配置 [SKIPPED: --skip-nginx] ---"
        _state_update "${_state_file}" "nginx_http" "skipped"
    else
        log_info "--- [9/13] 配置 Nginx（HTTP 阶段）---"
        _us_configure_nginx_http "${root_dir}" "${_skip_web}" || {
            log_error "[9/13] Nginx HTTP 配置失败，中止部署！"
            exit 1
        }
        _state_update "${_state_file}" "nginx_http" "active"
    fi

    # =========================================================================
    # 阶段 10: configure_tls — TLS 证书申请（两阶段）
    # =========================================================================
    if [[ "${_no_certbot}" == "true" || "${_skip_nginx}" == "true" ]]; then
        log_info "--- [10/13] TLS 配置 [SKIPPED] ---"
        _state_update "${_state_file}" "tls" "skipped"
        _state_update "${_state_file}" "nginx_tls" "skipped"
    else
        log_info "--- [10/13] 申请 TLS 证书（两阶段）---"
        _us_configure_tls "${root_dir}" || {
            log_error "[10/13] TLS 证书配置失败，中止部署！"
            exit 1
        }
        _state_update "${_state_file}" "tls" "active"
        _state_update "${_state_file}" "nginx_tls" "active"
    fi

    # =========================================================================
    # 阶段 11: build_initial_subscription — 构建首份订阅
    # =========================================================================
    log_info "--- [11/13] 构建初始订阅快照 ---"
    _us_build_initial_subscription || {
        log_error "[11/13] 初始订阅构建失败，中止部署！"
        exit 1
    }
    _state_update "${_state_file}" "subscription" "published"

    # =========================================================================
    # 阶段 12: verify_subscription — 用 Mihomo 校验订阅
    # =========================================================================
    log_info "--- [12/13] Mihomo 订阅校验 ---"
    _us_verify_subscription || {
        log_error "[12/13] 订阅 Mihomo 校验失败，中止部署！"
        exit 1
    }

    # =========================================================================
    # 阶段 13: print_deployment_summary — 输出部署摘要
    # =========================================================================
    log_info "--- [13/13] 生成部署摘要 ---"
    _us_print_summary "${_state_file}" "${_skip_proxy}" "${_proxy_only}" "${_skip_web}" "${_skip_nginx}" "${_no_certbot}"
}

# =============================================================================
# 内部实现函数
# =============================================================================

_us_preflight() {
    local root_dir="$1"

    # 检查必需的源文件存在
    local required_files=(
        "${root_dir}/apps/vpn_web/proxy/install-noninteractive.sh"
        "${root_dir}/apps/vpn_web/proxy/gen_clash_config.sh"
        "${root_dir}/apps/vpn_web/web/app.py"
        "${root_dir}/apps/vpn_web/requirements.txt"
        "${root_dir}/deploy/clash-sub/us/rebuild-clash-subscription.sh"
        "${root_dir}/deploy/clash-sub/us/extract_merge.py"
    )
    for f in "${required_files[@]}"; do
        if [[ ! -f "${f}" ]]; then
            log_error "预检失败: 仓库文件缺失: ${f}"
            exit 1
        fi
    done

    # 检查并自动安装缺失的必需命令
    local required_cmds=(python3 openssl curl unzip git)
    local missing_cmds=()
    for cmd in "${required_cmds[@]}"; do
        if ! command -v "${cmd}" >/dev/null 2>&1; then
            missing_cmds+=("${cmd}")
        fi
    done

    if [[ ${#missing_cmds[@]} -gt 0 ]]; then
        log_info "检测到缺少必需命令: ${missing_cmds[*]}，将自动尝试安装..."
        if [[ "${DRY_RUN:-false}" == "true" ]]; then
            log_info "[DRY-RUN] apt-get update && apt-get install -y ${missing_cmds[*]}"
        else
            export DEBIAN_FRONTEND=noninteractive
            local pkgs=()
            for cmd in "${missing_cmds[@]}"; do
                case "${cmd}" in
                    python3) pkgs+=("python3" "python3-venv" "python3-pip") ;;
                    unzip)   pkgs+=("unzip") ;;
                    git)     pkgs+=("git") ;;
                    curl)    pkgs+=("curl") ;;
                    openssl) pkgs+=("openssl") ;;
                    *)       pkgs+=("${cmd}") ;;
                esac
            done
            apt-get update -qq
            apt-get install -y --no-install-recommends "${pkgs[@]}" || {
                log_error "自动安装缺失命令失败，请手动运行: apt-get install -y ${pkgs[*]}"
                exit 1
            }
            log_success "缺失命令安装成功。"
        fi
    fi

    # 校验必要环境变量已设置
    local required_vars=(US_SUB_DOMAIN SUB_TOKEN PORTAL_PASSWORD FLASK_SECRET_KEY)
    for var in "${required_vars[@]}"; do
        if [[ -z "${!var:-}" ]]; then
            log_error "预检失败: 环境变量未设置: ${var}"
            exit 1
        fi
    done

    log_success "[1/13] 预检通过"
}

_us_install_packages() {
    if [[ "${DRY_RUN:-false}" == "true" ]]; then
        log_info "[DRY-RUN] apt-get install python3 python3-venv nginx certbot python3-certbot-nginx"
        return 0
    fi

    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    # 安装控制面所需包（不执行 upgrade）
    apt-get install -y --no-install-recommends \
        python3 \
        python3-venv \
        python3-pip \
        nginx \
        certbot \
        python3-certbot-nginx \
        curl \
        jq \
        openssl \
        ufw \
        ffmpeg \
        unzip \
        rsync \
        coreutils

    log_success "[2/13] 系统包安装完成"
}

_us_install_proxy() {
    local root_dir="$1"

    if [[ "${DRY_RUN:-false}" == "true" ]]; then
        log_info "[DRY-RUN] 执行 proxy/install-noninteractive.sh"
        return 0
    fi

    # 加载 proxy lib 函数（从非交互脚本 source lib/）
    # shellcheck disable=SC1091
    source "${root_dir}/apps/vpn_web/proxy/lib/install-xray.sh"
    # shellcheck disable=SC1091
    source "${root_dir}/apps/vpn_web/proxy/lib/render-xray-config.sh"
    # shellcheck disable=SC1091
    source "${root_dir}/apps/vpn_web/proxy/lib/firewall.sh"
    # shellcheck disable=SC1091
    source "${root_dir}/apps/vpn_web/proxy/lib/verify-xray.sh"

    install_xray || {
        log_error "Xray 安装失败！"
        exit 1
    }
    render_xray_config || {
        log_error "Xray 配置渲染失败！"
        exit 1
    }
    configure_xray_service || {
        log_error "Xray 服务配置失败！"
        exit 1
    }
    restart_xray_service || {
        log_error "Xray 服务启动失败！"
        exit 1
    }
    configure_ufw || {
        log_error "UFW 防火墙配置失败！"
        exit 1
    }

    # BBR（可选，失败不中止）
    if [[ "${ENABLE_BBR:-true}" == "true" ]]; then
        local sysctl_conf="/etc/sysctl.conf"
        grep -q "net.core.default_qdisc=fq" "${sysctl_conf}" 2>/dev/null || echo "net.core.default_qdisc=fq" >> "${sysctl_conf}"
        grep -q "net.ipv4.tcp_congestion_control=bbr" "${sysctl_conf}" 2>/dev/null || echo "net.ipv4.tcp_congestion_control=bbr" >> "${sysctl_conf}"
        sysctl -p -q 2>/dev/null || true
    fi

    log_success "[3/13] Xray 代理安装完成"
}

_us_generate_clash_source() {
    local root_dir="$1"

    if [[ "${DRY_RUN:-false}" == "true" ]]; then
        log_info "[DRY-RUN] gen_clash_config.sh → /var/www/clash/clash.yaml"
        return 0
    fi

    # gen_clash_config.sh 从 /etc/xray-portal/proxy.env 和 proxy-meta.conf 读取
    # 不需要交互输入
    if ! bash "${root_dir}/apps/vpn_web/proxy/gen_clash_config.sh"; then
        log_error "Clash 源配置生成失败！"
        return 1
    fi

    # 验证输出文件存在且合法
    local clash_source="${CLASH_US_SOURCE:-/var/www/clash/clash.yaml}"
    if [[ ! -f "${clash_source}" ]]; then
        log_error "Clash 源文件未生成: ${clash_source}"
        return 1
    fi

    # 基本 YAML 语法校验
    if ! python3 -c "import yaml; yaml.safe_load(open('${clash_source}'))" 2>/dev/null; then
        log_error "生成的 Clash 源文件 YAML 语法无效: ${clash_source}"
        return 1
    fi

    log_success "[5/13] Clash 原始配置生成完成: ${clash_source}"
}

_us_install_clash_builder() {
    local root_dir="$1"
    local clash_sub_dir="${CLASH_SUB_DIR:-/opt/clash-sub}"
    local subpush_user="${SUBPUSH_USER:-subpush}"
    local subpush_group="${SUBPUSH_GROUP:-subpush}"

    # 安装 Mihomo（固定版本 + SHA256 校验）
    # shellcheck disable=SC1091
    source "${root_dir}/deploy/lib/install-mihomo.sh"
    install_mihomo || {
        log_error "Mihomo 安装失败！"
        return 1
    }

    # 安装订阅合并脚本
    # 1. 创建 subpush 用户与组（必须先创建，目录才能设定所有权）
    if [[ "${DRY_RUN:-false}" != "true" ]]; then
        if ! id -u "${SUBPUSH_USER:-subpush}" >/dev/null 2>&1; then
            useradd --system --shell /bin/bash \
                --home-dir "${clash_sub_dir}" --no-create-home \
                "${SUBPUSH_USER:-subpush}"
            groupadd -f "${SUBPUSH_GROUP:-subpush}" 2>/dev/null || true
            log_success "创建系统用户: ${SUBPUSH_USER:-subpush}"
        else
            log_info "系统用户已存在: ${SUBPUSH_USER:-subpush}"
        fi
    fi

    # 2. 建立目录结构，所有权与权限模式必须与 upload_validator.py 审计规则绝对一致
    safe_mkdir "${clash_sub_dir}" 0755 "root:root"
    safe_mkdir "${clash_sub_dir}/incoming" 0700 "${SUBPUSH_USER:-subpush}:${SUBPUSH_GROUP:-subpush}"
    safe_mkdir "${clash_sub_dir}/sources" 0750 "root:root"
    safe_mkdir "${clash_sub_dir}/published" 0755 "root:root"

    # 其他辅助子目录保持安全隔离的 0770
    local other_dirs=(template generated backups scripts logs)
    for sub in "${other_dirs[@]}"; do
        safe_mkdir "${clash_sub_dir}/${sub}" 0770 "root:${SUBPUSH_GROUP:-subpush}"
    done

    # 3. 安装核心脚本
    safe_install "${root_dir}/deploy/clash-sub/us/extract_merge.py" \
        "${clash_sub_dir}/scripts/extract_merge.py" 0750 "root:${SUBPUSH_GROUP:-subpush}"

    safe_install "${root_dir}/deploy/clash-sub/us/upload_validator.py" \
        "${clash_sub_dir}/scripts/upload_validator.py" 0750 "root:${SUBPUSH_GROUP:-subpush}"

    safe_install "${root_dir}/deploy/clash-sub/us/subpush-cmd-wrapper" \
        "${clash_sub_dir}/scripts/subpush-cmd-wrapper" 0750 "root:${SUBPUSH_GROUP:-subpush}"

    safe_install "${root_dir}/deploy/clash-sub/us/rebuild-clash-subscription.sh" \
        "/usr/local/sbin/rebuild-clash-subscription" 0755 "root:root"

    # 配置 sudoers 规则，允许 subpush 用户免密执行 rebuild-clash-subscription
    if [[ "${DRY_RUN:-false}" != "true" ]]; then
        local sudoers_file="/etc/sudoers.d/90-xray-portal-subpush"
        log_info "配置 sudoers 规则以允许 ${SUBPUSH_USER:-subpush} 免密运行 rebuild-clash-subscription..."
        echo "${SUBPUSH_USER:-subpush} ALL=(ALL) NOPASSWD: /usr/local/sbin/rebuild-clash-subscription" > "${sudoers_file}"
        chmod 0440 "${sudoers_file}"
        chown root:root "${sudoers_file}"
    fi

    # 生成运行时配置
    local cfg_path="${clash_sub_dir}/scripts/config.env"
    if [[ "${DRY_RUN:-false}" != "true" ]]; then
        local tmp_cfg
        tmp_cfg=$(mktemp /tmp/config.env.XXXXXX)
        cat > "${tmp_cfg}" <<EOF
SUB_TOKEN="${SUB_TOKEN}"
CLASH_US_SOURCE="${CLASH_US_SOURCE:-/var/www/clash/clash.yaml}"
US_SOURCE="${CLASH_US_SOURCE:-/var/www/clash/clash.yaml}"
US_PUBLISH_DIR="${US_PUBLISH_DIR:-/opt/clash-sub/published}"
PUBLISHED_DIR="${US_PUBLISH_DIR:-/opt/clash-sub/published}"
INCOMING_DIR="${clash_sub_dir}/incoming"
US_SUB_DOMAIN="${US_SUB_DOMAIN}"
NL_SUB_DOMAIN="${NL_SUB_DOMAIN:-}"
LOG_FILE="${clash_sub_dir}/logs/rebuild.log"
MIHOMO_BIN="/usr/local/bin/mihomo"
EOF
        chmod 600 "${tmp_cfg}"
        chown "${SUBPUSH_USER:-subpush}:${SUBPUSH_GROUP:-subpush}" "${tmp_cfg}"
        mv -f "${tmp_cfg}" "${cfg_path}"
    fi

    log_success "[6/13] Clash 构建器安装完成"
}

_us_install_vpn_web() {
    local root_dir="$1"

    if [[ "${DRY_RUN:-false}" == "true" ]]; then
        log_info "[DRY-RUN] 部署 Flask 面板 → /usr/local/vpn-web"
        return 0
    fi

    # 创建专用 vpn-web 用户（无登录 Shell）
    if ! id -u vpn-web >/dev/null 2>&1; then
        useradd --system --shell /usr/sbin/nologin \
            --home-dir /usr/local/vpn-web --no-create-home \
            vpn-web
        log_success "创建专用用户: vpn-web"
    fi

    # 创建安装目录
    mkdir -p /usr/local/vpn-web
    mkdir -p /var/log/vpn-web
    chown -R vpn-web:vpn-web /var/log/vpn-web

    # 部署源码
    install -o root -g vpn-web -m 0640 "${root_dir}/apps/vpn_web/web/app.py" /usr/local/vpn-web/app.py
    install -o root -g vpn-web -m 0640 "${root_dir}/apps/vpn_web/web/utils.py" /usr/local/vpn-web/utils.py
    rm -rf /usr/local/vpn-web/templates
    cp -a "${root_dir}/apps/vpn_web/web/templates" /usr/local/vpn-web/templates
    chown -R root:vpn-web /usr/local/vpn-web/templates
    chmod -R 750 /usr/local/vpn-web/templates

    # 渲染 config.py（不含凭据，凭据通过 EnvironmentFile 注入）
    local tmp_cfg
    tmp_cfg=$(mktemp /tmp/config.py.XXXXXX)
    cat > "${tmp_cfg}" <<PYEOF
import os
PORTAL_PASSWORD = os.environ.get("PORTAL_PASSWORD", "")
SECRET_KEY = os.environ.get("FLASK_SECRET_KEY", "")
PYEOF
    chmod 640 "${tmp_cfg}"
    chown root:vpn-web "${tmp_cfg}"
    mv -f "${tmp_cfg}" /usr/local/vpn-web/config.py

    # 生成 EnvironmentFile（/etc/xray-portal/vpn-web.env，0600）
    mkdir -p /etc/xray-portal
    local tmp_env
    tmp_env=$(mktemp /tmp/vpn-web.env.XXXXXX)
    cat > "${tmp_env}" <<ENVEOF
SUB_TOKEN=${SUB_TOKEN}
SUB_PUBLIC_URL=https://${US_SUB_DOMAIN}/${SUB_TOKEN}/clash.yaml
SUB_PUBLIC_BASE_URL=https://${US_SUB_DOMAIN}
PORTAL_PASSWORD=${PORTAL_PASSWORD}
FLASK_SECRET_KEY=${FLASK_SECRET_KEY}
ENVEOF
    chmod 600 "${tmp_env}"
    chown root:root "${tmp_env}"
    mv -f "${tmp_env}" /etc/xray-portal/vpn-web.env

    # 创建或复用 Python venv
    if [[ ! -x /usr/local/vpn-web/venv/bin/python ]]; then
        log_info "创建 Python 虚拟环境..."
        python3 -m venv /usr/local/vpn-web/venv || {
            log_error "Python venv 创建失败！"
            return 1
        }
    fi

    # 安装依赖（fail closed：失败则退出）
    log_info "安装 Python 依赖..."
    /usr/local/vpn-web/venv/bin/pip install -q -r "${root_dir}/apps/vpn_web/requirements.txt" || {
        log_error "pip 依赖安装失败！请检查网络连接。"
        return 1
    }
    log_success "Python 依赖安装完成"

    # 部署 systemd 服务（从正式模板渲染）
    local svc_template="${root_dir}/deploy/systemd/vpn-web.service.template"
    if [[ ! -f "${svc_template}" ]]; then
        log_error "systemd 服务模板不存在: ${svc_template}"
        return 1
    fi

    local tmp_svc
    tmp_svc=$(mktemp /tmp/vpn-web.service.XXXXXX)
    cp "${svc_template}" "${tmp_svc}"
    chmod 644 "${tmp_svc}"
    install -o root -g root -m 0644 "${tmp_svc}" /etc/systemd/system/vpn-web.service
    rm -f "${tmp_svc}"

    # 创建 clash-subscribe.service 软链接（兼容旧名称）
    ln -sf /etc/systemd/system/vpn-web.service /etc/systemd/system/clash-subscribe.service

    systemctl daemon-reload
    systemctl enable vpn-web.service >/dev/null 2>&1

    # 启动服务（fail closed）
    systemctl restart vpn-web.service || {
        log_error "vpn-web.service 启动失败！"
        log_error "排障: journalctl -u vpn-web -n 50 --no-pager"
        return 1
    }

    # 等待服务稳定
    sleep 3

    if ! systemctl is-active --quiet vpn-web.service; then
        log_error "vpn-web.service 启动后立即退出！"
        log_error "排障: journalctl -u vpn-web -n 50 --no-pager"
        return 1
    fi

    log_success "[7/13] Flask Web 面板部署完成"
}

_us_install_tg_bot() {
    local root_dir="$1"

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

    # 写入并更新 NapCat 最新版 OneBot 11 配置文件（支持 network.httpServers 架构）
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

    # 若存在以 QQ 号命名的已有配置文件 (如 onebot11_3430774280.json) 也一并覆写更新
    for cfg_file in /opt/napcat/config/onebot11_*.json; do
        if [[ -f "${cfg_file}" ]]; then
            echo "${napcat_cfg_content}" > "${cfg_file}"
            chmod 644 "${cfg_file}"
        fi
    done

    # 部署源码
    install -o root -g root -m 0755 "${root_dir}/apps/tg_bot/tg_bot.py" /usr/local/tg_bot/tg_bot.py
    install -o root -g root -m 0755 "${root_dir}/apps/tg_bot/bridge_bot.py" /usr/local/tg_bot/bridge_bot.py
    install -o root -g root -m 0755 "${root_dir}/apps/tg_bot/fetch_link.py" /usr/local/tg_bot/fetch_link.py
    install -o root -g root -m 0755 "${root_dir}/apps/tg_bot/login_userbot.py" /usr/local/tg_bot/login_userbot.py

    # 写入专用 .env 配置文件
    local env_dest="/usr/local/tg_bot/.env"
    
    # 智能回退：若未配置 BRIDGE_SERVER_PUBLIC_IP，回退使用美国主机的 US_SUB_DOMAIN 或 US_SERVER_IP
    local public_ip="${BRIDGE_SERVER_PUBLIC_IP:-${US_SUB_DOMAIN:-${US_SERVER_IP}}}"
    
    cat > "${env_dest}" <<ENVEOF
# 由 install.sh 自动生成
CHANNEL_BOT_TOKEN=${CHANNEL_BOT_TOKEN:-}
CHANNEL_ADMIN_ID=${CHANNEL_ADMIN_ID:-}
CHANNEL_GROUP_ID=${CHANNEL_GROUP_ID:-}
BRIDGE_BOT_TOKEN=${BRIDGE_BOT_TOKEN:-}
BRIDGE_TARGET_QQ_GROUP=${BRIDGE_TARGET_QQ_GROUP:-}
BRIDGE_TARGET_QQ_TYPE=${BRIDGE_TARGET_QQ_TYPE:-group}
BRIDGE_SERVER_PUBLIC_IP=${public_ip}
BRIDGE_NAPCAT_API_URL=${BRIDGE_NAPCAT_API_URL:-http://127.0.0.1:3000/send_msg}
BRIDGE_NAPCAT_TIMEOUT=${BRIDGE_NAPCAT_TIMEOUT:-300}
BRIDGE_NAPCAT_MAX_CONCURRENCY=${BRIDGE_NAPCAT_MAX_CONCURRENCY:-1}
BRIDGE_NAPCAT_WS_URL=${BRIDGE_NAPCAT_WS_URL:-ws://127.0.0.1:3001}
BRIDGE_NAPCAT_STREAM_THRESHOLD=${BRIDGE_NAPCAT_STREAM_THRESHOLD:-52428800}
BRIDGE_NAPCAT_STREAM_CHUNK_SIZE=${BRIDGE_NAPCAT_STREAM_CHUNK_SIZE:-1048576}
BRIDGE_MEDIA_GROUP_SETTLE_DELAY=${BRIDGE_MEDIA_GROUP_SETTLE_DELAY:-8}
BRIDGE_FORWARD_MODE=${BRIDGE_FORWARD_MODE:-both}
TELEGRAM_USER_API_ID=${TELEGRAM_USER_API_ID:-}
TELEGRAM_USER_API_HASH=${TELEGRAM_USER_API_HASH:-}
ENVEOF
    chmod 600 "${env_dest}"
    chown root:root "${env_dest}"

    # 安装依赖
    log_info "为 tg_bot 安装 Python 依赖..."
    if [[ -x /usr/local/vpn-web/venv/bin/pip ]]; then
        /usr/local/vpn-web/venv/bin/pip install -q -r "${root_dir}/apps/tg_bot/requirements.txt" || {
            log_error "tg_bot 依赖安装失败！请检查网络连接。"
            return 1
        }
        log_success "tg_bot 依赖安装完成"
    else
        log_error "vpn-web venv 虚拟环境不存在，无法为 tg_bot 安装依赖！"
        return 1
    fi

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

    # 根据 ENABLE_BOTS 配置决定是否启动并使能
    if [[ "${ENABLE_BOTS:-false}" == "true" ]]; then
        log_info "启用并启动 tgbot 与 tg-qq-bridge 服务..."
        systemctl enable tgbot tg-qq-bridge >/dev/null 2>&1
        systemctl restart tgbot tg-qq-bridge || {
            log_warn "启动 tgbot 或 tg-qq-bridge 失败（可能是因为尚未进行 Userbot 登录授权）"
        }
    else
        log_info "ENABLE_BOTS 未开启或设为 false，禁用并关闭 bot 相关服务..."
        systemctl disable tgbot tg-qq-bridge >/dev/null 2>&1
        systemctl stop tgbot tg-qq-bridge >/dev/null 2>&1 || true
    fi

    log_success "[7.5] tg_bot 模块部署完成"
}

_us_verify_vpn_web_local() {
    if [[ "${DRY_RUN:-false}" == "true" ]]; then
        log_info "[DRY-RUN] curl http://127.0.0.1:8080/health"
        return 0
    fi

    log_info "执行本地健康检查: http://127.0.0.1:8080/health"

    local http_code
    http_code=$(curl --silent --fail --max-time 10 \
        --write-out '%{http_code}' \
        --output /dev/null \
        "http://127.0.0.1:8080/health" 2>/dev/null || echo "000")

    if [[ "${http_code}" == "200" ]]; then
        log_success "[8/13] Web 健康检查通过 (HTTP 200)"
    else
        log_error "Web 健康检查失败！HTTP 状态码: ${http_code}"
        log_error "禁止启用指向死后端的 Nginx 配置！"
        log_error "排障: curl -v http://127.0.0.1:8080/health"
        log_error "排障: journalctl -u vpn-web -n 30 --no-pager"
        return 1
    fi
}

_us_configure_nginx_http() {
    local root_dir="$1"
    local skip_web="$2"

    if [[ "${DRY_RUN:-false}" == "true" ]]; then
        log_info "[DRY-RUN] 渲染 Nginx HTTP 配置（条件: ENABLE_WEB=${ENABLE_WEB:-true} ENABLE_API=${ENABLE_API:-false} ENABLE_BOTS=${ENABLE_BOTS:-false}）"
        return 0
    fi

    local tpl="${root_dir}/deploy/nginx/us-subscription.conf.template"
    if [[ ! -f "${tpl}" ]]; then
        log_error "Nginx 模板不存在: ${tpl}"
        return 1
    fi

    mkdir -p /etc/nginx/sites-available

    # 删除 default 站点（备份软链接状态后删除）
    if [[ -L /etc/nginx/sites-enabled/default ]]; then
        log_info "备份并移除 Nginx default 站点..."
        local default_target
        default_target=$(readlink -f /etc/nginx/sites-enabled/default 2>/dev/null || echo "unknown")
        echo "# default site was: ${default_target}" > /etc/nginx/sites-available/default.disabled.bak
        rm -f /etc/nginx/sites-enabled/default
    fi

    # 渲染 HTTP-only 配置（Phase 1，不含 SSL）
    local tmp_conf
    tmp_conf=$(mktemp /tmp/us-subscription.conf.XXXXXX)

    # 生成 Nginx 配置（条件渲染）
    _render_us_nginx_conf_http "${skip_web}" > "${tmp_conf}"

    # 语法校验
    if ! nginx -t -q 2>/dev/null; then
        # 测试当前系统配置（新文件尚未链接，所以还是测试现有配置）
        log_info "链接前先进行语法测试..."
    fi

    chmod 644 "${tmp_conf}"
    mv -f "${tmp_conf}" /etc/nginx/sites-available/us-subscription.conf

    # 启用站点
    ln -sf /etc/nginx/sites-available/us-subscription.conf \
        /etc/nginx/sites-enabled/us-subscription.conf

    # 语法测试（fail closed）
    if ! nginx -t -q 2>&1; then
        log_error "Nginx 语法测试失败！"
        rm -f /etc/nginx/sites-enabled/us-subscription.conf
        return 1
    fi

    # Reload
    systemctl reload nginx || {
        log_error "Nginx reload 失败！"
        return 1
    }

    log_success "[9/13] Nginx HTTP 配置部署完成"
}

_render_us_nginx_conf_http() {
    local skip_web="$1"

    # 构建条件块
    local web_location=""
    if [[ "${ENABLE_WEB:-true}" == "true" && "${skip_web}" != "true" ]]; then
        web_location='
    # 管理面板（已验证后端存活）
    location / {
        proxy_pass http://127.0.0.1:8080;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_connect_timeout 5s;
        proxy_read_timeout 60s;
    }'
    else
        web_location='
    # Web 面板未启用
    location / {
        return 503 "Service not configured";
        add_header Content-Type text/plain;
    }'
    fi

    local api_location=""
    if [[ "${ENABLE_API:-false}" == "true" ]]; then
        api_location='
    # API 后端（ENABLE_API=true）
    location /api/ {
        proxy_pass http://127.0.0.1:9000;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
    }'
    fi

    cat <<NGINX_EOF
# 由 install.sh 自动生成 - 请勿手动修改
# HTTP Phase 1（TLS 申请前）

server {
    server_name ${US_SUB_DOMAIN};
    listen 80;
    listen [::]:80;

    # Let's Encrypt 验证路径
    location ^~ /.well-known/acme-challenge/ {
        root /var/www/html;
        default_type text/plain;
    }

    # 订阅文件（Token 保护）
    location = /${SUB_TOKEN}/clash.yaml {
        alias ${US_PUBLISH_DIR:-/opt/clash-sub/published}/clash.yaml;
        add_header X-Robots-Tag "noindex, nofollow";
        add_header Content-Type "text/yaml; charset=utf-8";
        auth_basic off;
        autoindex off;
    }

    # 无 Token 路径返回 410
    location = /clash.yaml {
        return 410;
    }
    ${web_location}
    ${api_location}
}
NGINX_EOF
}

_us_configure_tls() {
    local root_dir="$1"

    if [[ "${DRY_RUN:-false}" == "true" ]]; then
        log_info "[DRY-RUN] certbot → 渲染 HTTPS Nginx 配置"
        return 0
    fi

    log_info "申请 TLS 证书: ${US_SUB_DOMAIN}"

    # 确保 webroot 目录存在
    mkdir -p /var/www/html/.well-known/acme-challenge

    # 申请证书（非交互）
    if ! certbot certonly \
        --webroot \
        --webroot-path /var/www/html \
        --domain "${US_SUB_DOMAIN}" \
        --non-interactive \
        --agree-tos \
        --email "admin@${US_SUB_DOMAIN}" \
        --quiet 2>&1; then
        log_error "Certbot 证书申请失败！"
        log_error "常见原因: DNS 未解析到本机 IP / 端口 80 未对外开放 / 请求频率限制"
        return 1
    fi

    # 验证证书文件存在
    local cert_path="/etc/letsencrypt/live/${US_SUB_DOMAIN}/fullchain.pem"
    local key_path="/etc/letsencrypt/live/${US_SUB_DOMAIN}/privkey.pem"
    if [[ ! -f "${cert_path}" || ! -f "${key_path}" ]]; then
        log_error "证书文件不存在，禁止写入 HTTPS Nginx 配置！"
        return 1
    fi

    log_info "TLS 证书获取成功，渲染 HTTPS Nginx 配置..."

    # Phase 2：渲染含 SSL 的完整配置
    local tmp_conf
    tmp_conf=$(mktemp /tmp/us-subscription-tls.conf.XXXXXX)
    _render_us_nginx_conf_tls > "${tmp_conf}"
    chmod 644 "${tmp_conf}"
    mv -f "${tmp_conf}" /etc/nginx/sites-available/us-subscription.conf

    # 语法测试（fail closed）
    if ! nginx -t -q 2>&1; then
        log_error "HTTPS Nginx 语法测试失败！"
        return 1
    fi

    systemctl reload nginx || {
        log_error "Nginx HTTPS reload 失败！"
        return 1
    }

    # 验证 HTTPS 健康检查
    sleep 2
    local https_code
    https_code=$(curl --silent --fail --max-time 10 \
        --write-out '%{http_code}' --output /dev/null \
        "https://${US_SUB_DOMAIN}/health" 2>/dev/null || echo "000")

    if [[ "${https_code}" == "200" ]]; then
        log_success "[10/13] TLS 证书部署完成，HTTPS 健康检查通过"
    else
        log_warn "HTTPS 健康检查返回 ${https_code}（DNS 传播可能仍在进行中）"
        log_info "手动验证: curl https://${US_SUB_DOMAIN}/health"
    fi
}

_render_us_nginx_conf_tls() {
    local web_location=""
    if [[ "${ENABLE_WEB:-true}" == "true" ]]; then
        web_location='
    location / {
        proxy_pass http://127.0.0.1:8080;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_connect_timeout 5s;
        proxy_read_timeout 60s;
    }'
    else
        web_location='
    location / { return 503; }'
    fi

    local api_location=""
    if [[ "${ENABLE_API:-false}" == "true" ]]; then
        api_location='
    location /api/ {
        proxy_pass http://127.0.0.1:9000;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
    }'
    fi

    local bots_block=""
    if [[ "${ENABLE_BOTS:-false}" == "true" ]]; then
        bots_block="
# Bot 媒体服务（ENABLE_BOTS=true）
server {
    listen 8083 ssl;
    listen [::]:8083 ssl;
    server_name ${US_SUB_DOMAIN};

    ssl_certificate /etc/letsencrypt/live/${US_SUB_DOMAIN}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${US_SUB_DOMAIN}/privkey.pem;

    # 自动处理误用 http:// 打开 HTTPS 端口的情况 (Nginx 497 状态码自动重定向为 https://)
    error_page 497 https://\$host:8083\$request_uri;

    location / {
        proxy_pass http://127.0.0.1:8082;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_buffering off;
    }
}"
    fi

    cat <<NGINX_EOF
# 由 install.sh 自动生成 - 请勿手动修改
# HTTPS Phase 2

server {
    server_name ${US_SUB_DOMAIN};

    # HTTP → HTTPS 重定向
    listen 80;
    listen [::]:80;
    return 301 https://\$host\$request_uri;
}

server {
    server_name ${US_SUB_DOMAIN};
    # 修复: 不重复声明 ipv6only=on（避免多 server block 冲突）
    listen 443 ssl;
    listen [::]:443 ssl;

    ssl_certificate /etc/letsencrypt/live/${US_SUB_DOMAIN}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${US_SUB_DOMAIN}/privkey.pem;

    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305;
    ssl_prefer_server_ciphers off;

    # 订阅文件（Token 保护）
    location = /${SUB_TOKEN}/clash.yaml {
        alias ${US_PUBLISH_DIR:-/opt/clash-sub/published}/clash.yaml;
        add_header X-Robots-Tag "noindex, nofollow";
        add_header Content-Type "text/yaml; charset=utf-8";
        auth_basic off;
        autoindex off;
    }

    # 无 Token 路径返回 410
    location = /clash.yaml {
        return 410;
    }
    ${web_location}
    ${api_location}
}
${bots_block}
NGINX_EOF
}

_us_build_initial_subscription() {
    if [[ "${DRY_RUN:-false}" == "true" ]]; then
        log_info "[DRY-RUN] /usr/local/sbin/rebuild-clash-subscription"
        return 0
    fi

    if [[ ! -x /usr/local/sbin/rebuild-clash-subscription ]]; then
        log_error "rebuild-clash-subscription 脚本未安装！"
        return 1
    fi

    if ! /usr/local/sbin/rebuild-clash-subscription; then
        log_error "初始订阅构建失败！"
        log_error "排障: /usr/local/sbin/rebuild-clash-subscription 查看详细日志"
        return 1
    fi

    local published_file="${US_PUBLISH_DIR:-/opt/clash-sub/published}/clash.yaml"
    if [[ ! -f "${published_file}" ]]; then
        log_error "订阅文件未生成: ${published_file}"
        return 1
    fi

    log_success "[11/13] 初始订阅快照发布完成"
}

_us_verify_subscription() {
    if [[ "${DRY_RUN:-false}" == "true" ]]; then
        log_info "[DRY-RUN] mihomo -t 校验订阅"
        return 0
    fi

    local published_file="${US_PUBLISH_DIR:-/opt/clash-sub/published}/clash.yaml"
    local mihomo_bin="/usr/local/bin/mihomo"

    if [[ ! -x "${mihomo_bin}" ]]; then
        log_warn "Mihomo 未安装，跳过内核校验（仅用 python-yaml 校验语法）"
        python3 -c "import yaml; yaml.safe_load(open('${published_file}'))" || {
            log_error "订阅文件 YAML 语法无效！"
            return 1
        }
        return 0
    fi

    local test_dir
    test_dir=$(mktemp -d /tmp/mihomo-verify.XXXXXX)
    trap "rm -rf '${test_dir}'" RETURN

    cp "${published_file}" "${test_dir}/config.yaml"
    if ! "${mihomo_bin}" -t -d "${test_dir}" 2>&1 | grep -v "^$"; then
        log_error "Mihomo 内核校验失败！订阅配置存在逻辑错误。"
        return 1
    fi

    log_success "[12/13] 订阅 Mihomo 内核校验通过"
}

_us_print_summary() {
    local state_file="$1"
    local skip_proxy="$2"
    local proxy_only="$3"
    local skip_web="$4"
    local skip_nginx="$5"
    local no_certbot="$6"

    log_info ""
    log_info "================================================================"
    log_info "  美国服务器部署摘要"
    log_info "================================================================"

    log_info ""
    log_info "【已自动完成】"
    [[ "${skip_proxy}" != "true" ]] && log_success "  ✓ Xray 代理安装（固定版本 ${XRAY_VERSION:-?}）"
    log_success "  ✓ Clash 原始配置生成"
    log_success "  ✓ Mihomo 订阅构建器"
    [[ "${skip_web}" != "true" ]] && log_success "  ✓ Flask Web 面板（vpn-web 专用用户，gunicorn）"
    [[ "${skip_web}" != "true" ]] && log_success "  ✓ Telegram & QQ 机器人（代码部署与服务配置）"
    [[ "${skip_nginx}" != "true" ]] && log_success "  ✓ Nginx HTTP 配置"
    [[ "${no_certbot}" != "true" && "${skip_nginx}" != "true" ]] && log_success "  ✓ TLS 证书（Let's Encrypt）"
    log_success "  ✓ 初始订阅发布"
    log_success "  ✓ UFW 防火墙（SSH + 代理端口）"

    log_info ""
    log_info "【需要人工完成】"
    log_warn "  ⊡ 交换荷兰副机 SSH 公钥（subpush 双机互信）"
    log_warn "  ⊡ 将 NL 节点配置首次推送到本机触发合并"
    log_warn "  ⊡ 将订阅 URL 分发给客户端"
    if [[ "${ENABLE_BOTS:-false}" == "true" ]]; then
        log_warn "  ⊡ 运行 /usr/local/vpn-web/venv/bin/python /usr/local/tg_bot/login_userbot.py 登录授权 Telegram 账号"
        log_warn "  ⊡ 启动 NapCat QQ 容器（已自动生成 /opt/napcat/config/onebot11.json 配置）："
        log_warn "    sudo docker run -d --name napcat --restart=always --network host -v /opt/napcat/qq:/app/.config/QQ -v /opt/napcat/config:/app/napcat/config mlikiowa/napcat-docker:latest"
    fi

    log_info ""
    log_info "【访问地址】"
    log_info "  Web 面板:   https://${US_SUB_DOMAIN}/"
    log_info "  订阅地址:   https://${US_SUB_DOMAIN}/<TOKEN>/clash.yaml"

    log_info ""
    log_info "【排障命令】"
    log_info "  systemctl status xray vpn-web nginx"
    log_info "  journalctl -u vpn-web -n 50 --no-pager"
    log_info "  sudo ./deploy/verify.sh us --env <env-file>"

    # 更新部署状态文件时间戳
    if [[ -f "${state_file}" && "${DRY_RUN:-false}" != "true" ]]; then
        local verified_at
        verified_at=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
        sed -i "s|\"verified_at\": null|\"verified_at\": \"${verified_at}\"|" "${state_file}" 2>/dev/null || true
    fi
}

# =============================================================================
# 辅助函数：更新部署状态文件（不含秘密）
# =============================================================================
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
