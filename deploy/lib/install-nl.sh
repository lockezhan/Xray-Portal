#!/usr/bin/env bash
# =============================================================================
# Xray_portal 荷兰副机端一键自动化部署逻辑 (deploy/lib/install-nl.sh)
# =============================================================================

set -euo pipefail

install_nl() {
    log_info "开始执行荷兰副服务器 (NL Role) 环境初始化与脚本部署..."

    # 1. 注册专有受限服务账户 submirror
    if [[ "${DRY_RUN}" == "true" ]]; then
        log_info "[DRY-RUN] 创建或检查受限服务用户: ${SUBMIRROR_USER}"
    else
        if ! id -u "${SUBMIRROR_USER}" >/dev/null 2>&1; then
            useradd --system --shell /bin/bash --home-dir /home/submirror --create-home "${SUBMIRROR_USER}"
            log_success "建立专有账户 ${SUBMIRROR_USER} 成功。"
        else
            log_info "系统用户 ${SUBMIRROR_USER} 已存在，继续部署。"
        fi
    fi

    # 2. 建立备用镜像输出根目录 (权限与组限定)
    safe_mkdir "${NL_MIRROR_DIR}/${SUB_TOKEN}" 0775 "root:${SUBMIRROR_GROUP}"
    safe_mkdir "/home/${SUBMIRROR_USER}/.ssh" 0700 "${SUBMIRROR_USER}:${SUBMIRROR_GROUP}"

    # 3. 原子部署荷兰推送与初始化管理脚本
    local root_dir
    root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

    safe_install "${root_dir}/deploy/clash-sub/nl/push-clash-subscription-nl.sh" \
                 "/usr/local/sbin/push-clash-subscription-nl" 0755 "root:root"

    safe_install "${root_dir}/deploy/clash-sub/nl/nl_init.sh" \
                 "/usr/local/sbin/nl_init" 0755 "root:root"

    # 4. 渲染并部署荷兰精简镜像站 Nginx 模板
    local tpl="${root_dir}/deploy/nginx/nl-subscription.conf.template"
    if [[ -f "${tpl}" ]]; then
        if [[ "${DRY_RUN}" == "true" ]]; then
            log_info "[DRY-RUN] 渲染 Nginx 模板 ${tpl} 至 /etc/nginx/sites-available/nl-subscription.conf"
        else
            mkdir -p /etc/nginx/sites-available
            local tmp_conf
            tmp_conf="$(mktemp "/etc/nginx/sites-available/.nl-subscription.conf.XXXXXX")"
            sed -e "s|\${NL_SUB_DOMAIN}|${NL_SUB_DOMAIN}|g" \
                -e "s|\${SUB_TOKEN}|${SUB_TOKEN}|g" "${tpl}" > "${tmp_conf}"
            chmod 644 "${tmp_conf}"
            mv -f "${tmp_conf}" /etc/nginx/sites-available/nl-subscription.conf

            if [[ -d /etc/nginx/sites-enabled ]]; then
                ln -sf /etc/nginx/sites-available/nl-subscription.conf /etc/nginx/sites-enabled/nl-subscription.conf
            fi
            log_success "荷兰端 Nginx 只读镜像站配置渲染部署完成。"
        fi
    fi

    log_success "荷兰副服务器 (NL Role) 一键部署处理完成。"
}
