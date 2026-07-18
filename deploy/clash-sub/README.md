# ⚙️ 订阅合成与单向安全分发模块 (`clash-sub`)

本模块包含了“一主一副”多服务器代理节点合并、校验、分发的核心逻辑及部署模板。

## 1. 核心职能分工
*   **Primary主控端 (`primary/`)**：
    *   `extract_merge.py`：使用安全 `pyyaml` 对两端节点全自动提取。将节点分别规范化重命名为 `PRIMARY-NODE-x` 和 `SECONDARY-NODE-x`，与基础配置和分流规则结合，输出最终的完整配置。
    *   `rebuild-clash-subscription.sh`：主控构建脚本。在接收到更新信号后拉起，执行 YAML 解析校验、Mihomo 配置诊断，自动创建带有时间戳的历史版本物理备份，原子替换发布。最后通过专用 `submirror_key` rsync 同步回Secondary只读站。
*   **Secondary只读镜像端 (`secondary/`)**：
    *   `push-clash-subscription-secondary.sh`：Secondary配置主动上传与触发重建脚本。验证本地 Shadowsocks 节点合法后，通过 `scp -O` 安全送入Primary主控服务器，并通过 ssh wrapper 单向安全触发Primary的重新构建。
    *   `secondary_init.sh`：Secondary副站初始化配置脚本。用于一键建立受限同步账号并写入Primary的 `submirror_key.pub` 凭证。

---

## 2. 核心工作流图解
1.  **Secondary节点更新** ➡️ 触发 `push-clash-subscription-secondary.sh`。
2.  **网络同步** ➡️ Secondary端通过专用 `subpush_key` 使用 `scp -O` 单向上传至Primary `/opt/clash-sub/incoming/clash.yaml`。
3.  **触发构建** ➡️ Secondary端通过 SSH 强制参数 `rebuild` 唤醒Primary主控构建。
4.  **读取与提取** ➡️ Primary端 `rebuild-clash-subscription` 将新节点移动到 sources，运行 `extract_merge.py` 完成物理合并。
5.  **校验与发布** ➡️ 通过 Mihomo 内核校验 ➡️ 写入 `/opt/clash-sub/published/clash.yaml`。
6.  **安全回传** ➡️ Primary主控使用 `submirror_key` 将合并后的订阅强制推回Secondary备用镜像站，供故障时用户备用。

---

## 3. SSH 单向安全凭证约束
为规避 root 互信导致的一台服务器沦陷波及全局：
*   **`subpush` (Secondary ➡️ Primary)**：Primary端的公钥配有强制命令过滤器 wrapper。只允许写入 incoming 目录和唤醒 rebuild，禁止开启 shell。
*   **`submirror` (Primary ➡️ Secondary)**：Secondary端的公钥配有 restrict 限制。只允许接收Primary回传的 clash.yaml 文件。
*   **注意**：私钥不交叉持有。即：Secondary只持有 `subpush_key` 私钥，Primary只持有 `submirror_key` 私钥。Git 仓库中不提交任何真实私钥。
