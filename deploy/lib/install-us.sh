#!/usr/bin/env bash
# =============================================================================
# Xray_portal 美国主控端一键自动化部署逻辑 (deploy/lib/install-us.sh)
# =============================================================================

set -euo pipefail

install_us() {
    log_info "开始执行美国主控端 (US Role) 环境初始化与脚本部署..."

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

    # 3. 原子安全部署核心业务脚本 (使用 safe_install，禁止强行覆盖)
    local root_dir
    root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

    safe_install "${root_dir}/deploy/clash-sub/us/extract_merge.py" \
                 "${US_INSTALL_DIR}/scripts/extract_merge.py" 0750 "root:${SUBPUSH_GROUP}"

    safe_install "${root_dir}/deploy/clash-sub/us/upload_validator.py" \
                 "${US_INSTALL_DIR}/scripts/upload_validator.py" 0750 "root:${SUBPUSH_GROUP}"

    safe_install "${root_dir}/deploy/clash-sub/us/subpush-cmd-wrapper" \
                 "${US_INSTALL_DIR}/scripts/subpush-cmd-wrapper" 0750 "root:${SUBPUSH_GROUP}"

    safe_install "${root_dir}/deploy/clash-sub/us/rebuild-clash-subscription.sh" \
                 "/usr/local/sbin/rebuild-clash-subscription" 0755 "root:root"

    # 4. 生成运行时安全配置文件 (0600 权限防止泄露)
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

    # 5. 渲染并部署 Nginx 站点配置
    local tpl="${root_dir}/deploy/nginx/us-subscription.conf.template"
    if [[ -f "${tpl}" ]]; then
        if [[ "${DRY_RUN}" == "true" ]]; then
            log_info "[DRY-RUN] 渲染 Nginx 模板 ${tpl} 至 /etc/nginx/sites-available/us-subscription.conf"
        else
            mkdir -p /etc/nginx/sites-available
            local tmp_conf
            tmp_conf="$(mktemp "/etc/nginx/sites-available/.us-subscription.conf.XXXXXX")"
            # 使用环境变量精确替换 US_SUB_DOMAIN 和 SUB_TOKEN
            sed -e "s|\${US_SUB_DOMAIN}|${US_SUB_DOMAIN}|g" \
                -e "s|\${SUB_TOKEN}|${SUB_TOKEN}|g" "${tpl}" > "${tmp_conf}"
            chmod 644 "${tmp_conf}"
            mv -f "${tmp_conf}" /etc/nginx/sites-available/us-subscription.conf

            if [[ -d /etc/nginx/sites-enabled ]]; then
                ln -sf /etc/nginx/sites-available/us-subscription.conf /etc/nginx/sites-enabled/us-subscription.conf
            fi
            log_success "美国端 Nginx 配置渲染部署完成。"
        fi
    fi

    log_success "美国主服务器 (US Role) 一键部署处理完成。"
}
