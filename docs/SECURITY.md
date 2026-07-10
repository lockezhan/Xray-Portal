# 🛡️ 系统安全体系与访问控制规范 (`docs/SECURITY.md`)

本订阅分发系统在设计和运行上严格遵循**“防御性运维”**与**“最小特权”**原则，以最大程度保护用户隐私，并隔离潜在的安全风险。

---

## 1. 订阅 Token 的绝对敏感性

*   **威胁模型**：订阅链接中包含的 `SUB_TOKEN` 直接指向包含了您所有节点服务器 IP、端口和密码的 Clash YAML。**如果此 Token 泄露，等同于代理节点的全部访问控制权向外泄露**。
*   **安全防护策略**：
    1.  `SUB_TOKEN` 至少应为 32 字节高强度随机字串。
    2.  Token 不得直接写入公开代码仓库。仓库中仅提交 `.env.example` 占位符。
    3.  生产环境上，Token 仅保存在服务器本地受限目录（`/opt/clash-sub/scripts/config.env`，文件所有者为 `root:subpush`，权限严格设定为 `600` 或 `640`），防止越权读取。
    4.  Nginx 必须添加 `X-Robots-Tag: noindex, nofollow` 报头，并明确禁止目录索引 (`autoindex off`)，防止搜索引擎爬虫意外爬取并建立索引。

---

## 2. 单向 SSH 密钥隔离与权限收紧

为了避免任何一台服务器失陷导致跨站越权，我们对 SSH 互信关系做出了物理级单向隔离设计：

### 2.1 荷兰向美国上传节点 (subpush)
*   **私钥存放**：私钥仅存放在荷兰服务器的 `/opt/clash-sub-mirror/subpush_key`。
*   **公钥限制**：美国端在 `/opt/clash-sub/.ssh/authorized_keys` 中对该公钥绑定了如下安全限制：
    *   `restrict`：完全禁用 TTY 分配、禁止任何端口转发和 Agent 转发。
    *   `command="/opt/clash-sub/scripts/subpush-cmd-wrapper"`：强制接管所有操作。该 wrapper 脚本仅允许接收来自荷兰的 `clash.yaml` 上传，或者执行无参数 `rebuild` 重新构建订阅，拒绝任何 shell 操作。

### 2.2 美国向荷兰同步订阅 (submirror)
*   **私钥存放**：私钥仅存放在美国服务器的 `/opt/clash-sub/scripts/submirror_key`。
*   **公钥限制**：荷兰端在 `/home/submirror/.ssh/authorized_keys` 中对其添加 `restrict` 前缀限制，使其仅能被用于向荷兰只读备用目录传输 `clash.yaml`。

---

## 3. 标准物理文件与目录权限表

为保证美国 `subpush` 和荷兰 `submirror` 系统账户在后台正常读写文件，同时防止其他普通用户或恶意进程越权访问，生产环境上的目录和文件必须严格遵循以下权限模型。**严禁直接使用 `chmod -R 777` 这样具有极大安全隐患的命令。**

| 目录/文件路径 | 推荐所有者 (Owner) | 推荐群组 (Group) | 推荐权限 (Permissions) | 职能与安全目的说明 |
| :--- | :--- | :--- | :--- | :--- |
| `/opt/clash-sub` | `root` | `root` | `755` | 订阅系统主目录，禁止其他用户写入 |
| `/opt/clash-sub/.ssh` | `subpush` | `subpush` | `700` | SSHD 强制要求，防范密钥窃取 |
| `/opt/clash-sub/.ssh/authorized_keys` | `subpush` | `subpush` | `600` | SSHD 强制要求，防止恶意篡改公钥 |
| `/opt/clash-sub/incoming` | `subpush` | `subpush` | `770` | 荷兰节点上传目录，仅限 subpush 读写 |
| `/opt/clash-sub/published` | `subpush` | `subpush` | `770` | 订阅发布目录，允许 www-data 读 |
| `/opt/clash-sub/published/clash.yaml`| `subpush` | `subpush` | `644` | 最终订阅物理文件，Nginx 可直接读取 |
| `/opt/clash-sub/scripts/config.env` | `root` | `subpush` | `640` | 环境密码配置文件，防非系统账户窃听 |
| `/opt/clash-sub/scripts/submirror_key` | `subpush` | `subpush` | `600` | SSHD 强制要求，美国推送私钥 |
| `/opt/clash-sub/scripts/subpush_key` | `subpush` | `subpush` | `600` | SSHD 强制要求，美国上传备份私钥 |

---

## 4. 防范敏感数据外泄与日志脱敏

1.  **Git 防泄露**：
    *   在本地配置了严苛的 `.gitignore` 规则，自动拦截 `.env`、`config.env`、私钥文件 `*_key`、真实 `clash.yaml` 以及运行时日志。
    *   提倡在提交前使用 `./scripts/check-secrets.sh` 扫描。
2.  **日志脱敏原则**：
    *   在 `extract_merge.py` 和 `rebuild-clash-subscription.sh` 中，任何涉及节点密码、Token 密钥的具体字串，**坚决不输出到任何标准日志文件**中，防止恶意用户通过读取 `/var/log` 窃取凭据。
