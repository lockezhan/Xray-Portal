#!/usr/bin/env bash
# =============================================================================
# Xray_portal 部署系统 SSH 互信私钥及 authorized_keys 强制限制辅助库 (deploy/lib/ssh-keys.sh)
# =============================================================================

set -euo pipefail

# =============================================================================
# 幂等安全生成 Ed25519 密钥对: generate_ssh_keypair <key_path> <comment> <owner:group>
# =============================================================================
generate_ssh_keypair() {
    local key_path="$1"
    local comment="$2"
    local owner="${3:-}"

    if [[ -f "${key_path}" ]]; then
        log_info "密钥文件已存在，保留现存密钥: ${key_path}"
        return 0
    fi

    if [[ "${DRY_RUN}" == "true" ]]; then
        log_info "[DRY-RUN] 生成 Ed25519 密钥对: ${key_path} (备注: ${comment})"
        return 0
    fi

    local key_dir
    key_dir="$(dirname "${key_path}")"
    mkdir -p "${key_dir}"

    ssh-keygen -t ed25519 -f "${key_path}" -N "" -C "${comment}" >/dev/null 2>&1
    chmod 600 "${key_path}"
    chmod 644 "${key_path}.pub"

    if [[ -n "${owner}" ]]; then
        chown "${owner}" "${key_path}" "${key_path}.pub"
    fi
    log_success "生成 SSH 互信密钥完成。"
}

# =============================================================================
# 安全注册受限 authorized_keys: install_authorized_key <pubkey_str> <auth_file> <cmd> <owner:group>
# =============================================================================
install_authorized_key() {
    local pubkey="$1"
    local auth_file="$2"
    local cmd="${3:-none}"
    local owner="${4:-}"

    if [[ -z "${pubkey}" ]]; then
        log_error "提供的公钥内容为空，无法写入受限 authorized_keys。"
        return 1
    fi

    local ssh_dir
    ssh_dir="$(dirname "${auth_file}")"

    if [[ "${DRY_RUN:-false}" == "true" ]]; then
        log_info "[DRY-RUN] 注册 SSH 受限访问公钥至 ${auth_file} (强行绑定命令: ${cmd})"
        return 0
    fi

    mkdir -p "${ssh_dir}"
    chmod 700 "${ssh_dir}"

    local line
    if [[ "${cmd}" != "none" && -n "${cmd}" ]]; then
        # 修复引号格式：command= 后的值必须用双引号包裹，
        # 且整个 key 选项行不能再有外层引号
        # 正确格式: restrict,...,command="<cmd>" <keytype> <key> [comment]
        line="restrict,no-agent-forwarding,no-port-forwarding,no-X11-forwarding,no-pty,command=\"${cmd}\" ${pubkey}"
    else
        line="restrict,no-agent-forwarding,no-port-forwarding,no-X11-forwarding,no-pty ${pubkey}"
    fi

    touch "${auth_file}"
    # 避免重复写入相同公钥（按公钥内容去重，不含 options）
    local pubkey_content
    pubkey_content=$(echo "${pubkey}" | awk '{print $2}' 2>/dev/null || echo "${pubkey}")
    if ! grep -q "${pubkey_content}" "${auth_file}" 2>/dev/null; then
        printf '%s\n' "${line}" >> "${auth_file}"
    else
        log_info "公钥已存在于 ${auth_file}，跳过重复写入。"
    fi

    chmod 600 "${auth_file}"
    if [[ -n "${owner}" ]]; then
        chown -R "${owner}" "${ssh_dir}"
    fi
    log_success "受限 authorized_keys 配置完毕。"
}

# =============================================================================
# submirror 专用强制命令授权（P6 要求）
# 限制 Secondary 端只能执行特定 rsync 命令，禁止交互式 Shell
#
# 用法: install_submirror_authorized_key <pubkey_str> <target_path> <sub_token>
# =============================================================================
install_submirror_authorized_key() {
    local pubkey="$1"
    local auth_file="$2"
    local sub_token="${3:-}"
    local mirror_path="/var/www/sub/${sub_token}/clash.yaml"

    if [[ -z "${sub_token}" ]]; then
        log_error "install_submirror_authorized_key: SUB_TOKEN 为空！"
        return 1
    fi

    # 强制命令：仅允许执行 rsync server-side（接收文件写入 mirror_path）
    # rsync 通过 SSH 调用时，sshd 会设置 SSH_ORIGINAL_COMMAND 为 rsync 协议命令
    # 使用 rrsync 包装器更安全，但此处使用精确路径限制
    local forced_cmd="rsync --server -vlogDtprze.iLsfxC . ${mirror_path}"

    log_info "注册 submirror 受限公钥（强制命令: rsync 写入 ${mirror_path}）..."
    install_authorized_key "${pubkey}" "${auth_file}" "${forced_cmd}" \
        "${SUBMIRROR_USER:-submirror}:${SUBMIRROR_GROUP:-submirror}"
}

