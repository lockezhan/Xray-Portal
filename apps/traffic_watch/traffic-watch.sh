#!/usr/bin/env bash

set -u

LOG_FILE="/var/log/traffic-watch.log"
NOW="$(date --iso-8601=seconds)"

ESTABLISHED_COUNT="$(
    ss -Htn state established 2>/dev/null | wc -l
)"

SYN_SENT_COUNT="$(
    ss -Htn state syn-sent 2>/dev/null | wc -l
)"

{
    echo
    echo "============================================================"
    echo "检查时间：${NOW}"
    echo "已建立 TCP 连接：${ESTABLISHED_COUNT}"
    echo "等待建立的出站连接：${SYN_SENT_COUNT}"

    echo
    echo "----- 流量统计 -----"
    vnstat 2>/dev/null || echo "vnStat 暂无数据"

    echo
    echo "----- 对外监听端口 -----"
    ss -Hlntup 2>/dev/null

    echo
    echo "----- 连接最多的目标 IP -----"
    ss -Htn state established 2>/dev/null |
    awk '{
        peer=$5
        sub(/:[^:]*$/, "", peer)
        gsub(/^\[|\]$/, "", peer)
        print peer
    }' |
    sort |
    uniq -c |
    sort -nr |
    head -30

    echo
    echo "----- 尚未建立成功的出站连接 -----"
    ss -Htnp state syn-sent 2>/dev/null | head -100

    echo
    echo "----- CPU 占用最高的进程 -----"
    ps aux --sort=-%cpu | head -15

    echo
    echo "----- 内存占用最高的进程 -----"
    ps aux --sort=-%mem | head -15

    echo
    echo "----- 最近一小时 SSH 失败记录 -----"
    journalctl \
        -u ssh \
        -u sshd \
        --since "1 hour ago" \
        --no-pager 2>/dev/null |
    grep -E "Failed password|Invalid user|authentication failure" |
    tail -50 || true

    echo
    echo "----- 最近一小时 UFW 拦截记录 -----"
    journalctl \
        -k \
        --since "1 hour ago" \
        --no-pager 2>/dev/null |
    grep "UFW BLOCK" |
    tail -50 || true

} >> "${LOG_FILE}"

# 阈值需要根据正常使用情况调整
if [ "${ESTABLISHED_COUNT}" -gt 300 ] ||
   [ "${SYN_SENT_COUNT}" -gt 50 ]; then
    logger -p auth.warning -t traffic-watch \
        "发现异常连接数量：established=${ESTABLISHED_COUNT}, syn-sent=${SYN_SENT_COUNT}"
fi
