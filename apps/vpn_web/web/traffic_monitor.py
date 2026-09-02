# -*- coding: utf-8 -*-
"""
纯原生 Linux 内核物理网卡流量监控与持久化统计模块
- 数据源: /proc/net/dev 与 /proc/net/route
- 存储: SQLite3 (/var/lib/traffic_stats.db)
- 零外部依赖、零系统负担，精准锁定对外真实物理网卡 (排除 Docker/虚拟网卡)
"""

import os
import time
import sqlite3
import threading
import datetime
import logging

logger = logging.getLogger(__name__)

DB_PATH = "/var/lib/traffic_stats.db"
FALLBACK_DB_PATH = os.path.expanduser("~/.traffic_stats.db")

def get_db_path():
    try:
        os.makedirs(os.path.dirname(DB_PATH), exist_ok=True)
        # 尝试测试写权限
        test_file = f"{DB_PATH}.test"
        with open(test_file, 'w') as f:
            f.write('1')
        os.remove(test_file)
        return DB_PATH
    except Exception:
        return FALLBACK_DB_PATH

def get_default_interface() -> str:
    """从内核路由表中精确查找默认出网物理网卡"""
    try:
        with open('/proc/net/route', 'r') as f:
            for line in f.readlines()[1:]:
                fields = line.strip().split()
                # 目标地址为 00000000 表示默认路由
                if len(fields) >= 2 and fields[1] == '00000000':
                    return fields[0]
    except Exception as e:
        logger.warning(f"Error reading /proc/net/route: {e}")
    
    # 兜底查找非 lo/docker 的第一个活跃网卡
    try:
        with open('/proc/net/dev', 'r') as f:
            for line in f.readlines()[2:]:
                name = line.strip().split(':')[0].strip()
                if name != 'lo' and not name.startswith(('docker', 'veth', 'br-')):
                    return name
    except Exception:
        pass
    return 'eth0'


def read_interface_bytes(iface: str) -> tuple:
    """读取指定网卡的 (rx_bytes, tx_bytes)"""
    try:
        with open('/proc/net/dev', 'r') as f:
            for line in f.readlines()[2:]:
                parts = line.strip().split(':')
                if len(parts) == 2 and parts[0].strip() == iface:
                    vals = parts[1].split()
                    rx = int(vals[0])
                    tx = int(vals[8])
                    return rx, tx
    except Exception as e:
        logger.error(f"Error reading /proc/net/dev: {e}")
    return 0, 0


class TrafficMonitor:
    def __init__(self, db_path: str = None):
        self.db_path = db_path or get_db_path()
        self.running = False
        self.thread = None
        self._lock = threading.Lock()
        self.last_sample = None  # (timestamp, rx, tx)
        self.current_speed = {'rx_bps': 0, 'tx_bps': 0}
        self.init_db()

    def get_conn(self):
        os.makedirs(os.path.dirname(self.db_path), exist_ok=True)
        conn = sqlite3.connect(self.db_path, timeout=10)
        conn.row_factory = sqlite3.Row
        return conn

    def init_db(self):
        try:
            with self.get_conn() as conn:
                conn.execute("""
                    CREATE TABLE IF NOT EXISTS traffic_samples (
                        id INTEGER PRIMARY KEY AUTOINCREMENT,
                        iface TEXT NOT NULL,
                        timestamp INTEGER NOT NULL,
                        rx_raw INTEGER NOT NULL,
                        tx_raw INTEGER NOT NULL,
                        rx_diff INTEGER NOT NULL,
                        tx_diff INTEGER NOT NULL
                    )
                """)
                conn.execute("CREATE INDEX IF NOT EXISTS idx_ts ON traffic_samples(timestamp)")
                conn.execute("CREATE INDEX IF NOT EXISTS idx_iface ON traffic_samples(iface)")
                conn.commit()
        except Exception as e:
            logger.error(f"TrafficMonitor init_db failed: {e}")

    def sample_once(self):
        iface = get_default_interface()
        rx, tx = read_interface_bytes(iface)
        now = int(time.time())

        rx_diff = 0
        tx_diff = 0

        with self._lock:
            if self.last_sample is not None:
                last_time, last_rx, last_tx = self.last_sample
                time_delta = max(1, now - last_time)
                
                # 如果计数器没有发生溢出/重启重置
                if rx >= last_rx and tx >= last_tx:
                    rx_diff = rx - last_rx
                    tx_diff = tx - last_tx
                    self.current_speed = {
                        'rx_bps': int((rx_diff * 8) / time_delta),
                        'tx_bps': int((tx_diff * 8) / time_delta)
                    }
                else:
                    rx_diff = rx
                    tx_diff = tx
            else:
                # 首次启动，从数据库获取最新一条记录对比
                try:
                    with self.get_conn() as conn:
                        row = conn.execute(
                            "SELECT timestamp, rx_raw, tx_raw FROM traffic_samples WHERE iface=? ORDER BY id DESC LIMIT 1",
                            (iface,)
                        ).fetchone()
                        if row and rx >= row['rx_raw'] and tx >= row['tx_raw']:
                            rx_diff = rx - row['rx_raw']
                            tx_diff = tx - row['tx_raw']
                except Exception:
                    pass

            self.last_sample = (now, rx, tx)

        try:
            with self.get_conn() as conn:
                conn.execute(
                    "INSERT INTO traffic_samples (iface, timestamp, rx_raw, tx_raw, rx_diff, tx_diff) VALUES (?, ?, ?, ?, ?, ?)",
                    (iface, now, rx, tx, rx_diff, tx_diff)
                )
                
                # 保留最近 60 天的数据（清理超期数据保持轻量）
                cutoff = now - (60 * 86400)
                conn.execute("DELETE FROM traffic_samples WHERE timestamp < ?", (cutoff,))
                conn.commit()
        except Exception as e:
            logger.error(f"Save traffic sample failed: {e}")

    def start(self):
        if self.running:
            return
        self.running = True
        # 先执行一次采样
        self.sample_once()

        def _loop():
            while self.running:
                time.sleep(60)
                if not self.running:
                    break
                try:
                    self.sample_once()
                except Exception as e:
                    logger.error(f"Traffic loop error: {e}")

        self.thread = threading.Thread(target=_loop, daemon=True, name="TrafficMonitorThread")
        self.thread.start()
        logger.info("TrafficMonitor thread started.")

    def stop(self):
        self.running = False

    def get_summary(self) -> dict:
        """获取全套格式化汇总统计数据，与 ECharts 前端无缝对接"""
        iface = get_default_interface()
        now = int(time.time())
        rx_raw, tx_raw = read_interface_bytes(iface)

        # 获取今日 0 点时间戳
        today_start = int(datetime.datetime.now().replace(hour=0, minute=0, second=0, microsecond=0).timestamp())
        # 获取本月 1 日 0 点时间戳
        month_start = int(datetime.datetime.now().replace(day=1, hour=0, minute=0, second=0, microsecond=0).timestamp())

        today_rx = 0
        today_tx = 0
        month_rx = 0
        month_tx = 0
        hourly_data = []
        daily_data = []

        try:
            with self.get_conn() as conn:
                # 1. 今日累计
                r_today = conn.execute(
                    "SELECT SUM(rx_diff) as s_rx, SUM(tx_diff) as s_tx FROM traffic_samples WHERE iface=? AND timestamp >= ?",
                    (iface, today_start)
                ).fetchone()
                if r_today and r_today['s_rx'] is not None:
                    today_rx = int(r_today['s_rx'])
                    today_tx = int(r_today['s_tx'])

                # 2. 本月累计
                r_month = conn.execute(
                    "SELECT SUM(rx_diff) as s_rx, SUM(tx_diff) as s_tx FROM traffic_samples WHERE iface=? AND timestamp >= ?",
                    (iface, month_start)
                ).fetchone()
                if r_month and r_month['s_rx'] is not None:
                    month_rx = int(r_month['s_rx'])
                    month_tx = int(r_month['s_tx'])

                # 3. 最近 24 小时小时级分布
                # 按每小时聚合
                past_24h = now - (24 * 3600)
                rows_h = conn.execute("""
                    SELECT 
                        strftime('%H:00', datetime(timestamp, 'unixepoch', 'localtime')) as hour_str,
                        CAST(strftime('%H', datetime(timestamp, 'unixepoch', 'localtime')) as INTEGER) as h_val,
                        SUM(rx_diff) as sum_rx,
                        SUM(tx_diff) as sum_tx
                    FROM traffic_samples
                    WHERE iface=? AND timestamp >= ?
                    GROUP BY hour_str
                    ORDER BY timestamp ASC
                """, (iface, past_24h)).fetchall()

                for row in rows_h:
                    hourly_data.append({
                        'time': {'hour': row['h_val']},
                        'rx': int(row['sum_rx'] or 0),
                        'tx': int(row['sum_tx'] or 0)
                    })

                # 4. 最近 30 天天级分布
                past_30d = now - (30 * 86400)
                rows_d = conn.execute("""
                    SELECT 
                        strftime('%m', datetime(timestamp, 'unixepoch', 'localtime')) as m_str,
                        strftime('%d', datetime(timestamp, 'unixepoch', 'localtime')) as d_str,
                        SUM(rx_diff) as sum_rx,
                        SUM(tx_diff) as sum_tx
                    FROM traffic_samples
                    WHERE iface=? AND timestamp >= ?
                    GROUP BY m_str, d_str
                    ORDER BY timestamp ASC
                """, (iface, past_30d)).fetchall()

                for row in rows_d:
                    daily_data.append({
                        'date': {'month': int(row['m_str']), 'day': int(row['d_str'])},
                        'rx': int(row['sum_rx'] or 0),
                        'tx': int(row['sum_tx'] or 0)
                    })

        except Exception as e:
            logger.error(f"Get traffic summary error: {e}")

        # 若刚启动暂无采样累积，将今日/本月流量与当前 raw 字节做平滑兜底
        if today_rx == 0 and today_tx == 0:
            today_rx = rx_raw
            today_tx = tx_raw
        if month_rx == 0 and month_tx == 0:
            month_rx = rx_raw
            month_tx = tx_raw

        # 若小时数据为空，生成当前的占位数据
        if not hourly_data:
            current_h = datetime.datetime.now().hour
            hourly_data.append({
                'time': {'hour': current_h},
                'rx': today_rx,
                'tx': today_tx
            })

        # 若天数据为空，生成今天的占位数据
        if not daily_data:
            dt = datetime.datetime.now()
            daily_data.append({
                'date': {'month': dt.month, 'day': dt.day},
                'rx': today_rx,
                'tx': today_tx
            })

        return {
            'iface': iface,
            'speed': self.current_speed,
            'today': {'rx': today_rx, 'tx': today_tx},
            'month': {'rx': month_rx, 'tx': month_tx},
            'total': {'rx': rx_raw, 'tx': tx_raw},
            'hour': hourly_data,
            'day': daily_data
        }


# 全局单例
traffic_monitor = TrafficMonitor()
