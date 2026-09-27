import os
import json
import math
import datetime
from typing import Dict, Any, List

STORAGE_FILE = "/var/lib/xray-portal/rewards_store.json"
LOCAL_FALLBACK = os.path.join(os.path.dirname(__file__), "rewards_store.json")

def _get_storage_path() -> str:
    primary_dir = os.path.dirname(STORAGE_FILE)
    if os.path.exists(primary_dir) and os.access(primary_dir, os.W_OK):
        return STORAGE_FILE
    return LOCAL_FALLBACK

def _default_store() -> Dict[str, Any]:
    return {
        "settings": {
            "target_points": 20000,
            "reward_name": "微软大额官方礼品卡"
        },
        "accounts": {
            "impwkn47922e@outlook.com": {
                "email": "impwkn47922e@outlook.com",
                "display_name": "主账号 (impwkn)",
                "current_points": 2356,
                "today_earned": 87,
                "streak_days": 14,
                "last_updated": datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S"),
                "status": "success",
                "history": []
            },
            "TiffanyHill9854@outlook.com": {
                "email": "TiffanyHill9854@outlook.com",
                "display_name": "副账号 (Tiffany)",
                "current_points": 520,
                "today_earned": 42,
                "streak_days": 12,
                "last_updated": datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S"),
                "status": "success",
                "history": []
            }
        },
        "logs": []
    }

def load_rewards_store() -> Dict[str, Any]:
    path = _get_storage_path()
    if not os.path.exists(path):
        data = _default_store()
        save_rewards_store(data)
        return data
    try:
        with open(path, "r", encoding="utf-8") as f:
            data = json.load(f)
            # 补齐默认结构
            if "settings" not in data:
                data["settings"] = {"target_points": 20000, "reward_name": "微软大额官方礼品卡"}
            if "accounts" not in data:
                data["accounts"] = {}
            if "logs" not in data:
                data["logs"] = []
            return data
    except Exception:
        return _default_store()

def save_rewards_store(data: Dict[str, Any]) -> bool:
    path = _get_storage_path()
    try:
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w", encoding="utf-8") as f:
            json.dump(data, f, ensure_ascii=False, indent=2)
        return True
    except Exception as e:
        print(f"Failed to save rewards store: {e}")
        return False

def calculate_account_metrics(acc_data: Dict[str, Any], target_points: int) -> Dict[str, Any]:
    """计算单个账号的连签周数、兑换剩余天数及达成预测"""
    current_pts = int(acc_data.get("current_points", 0))
    today_earned = int(acc_data.get("today_earned", 0))
    streak_days = int(acc_data.get("streak_days", 0))

    # 1. 连签天数与周数分析
    streak_weeks = streak_days // 7
    cycle_days = streak_days % 7  # 当前周内的进度 (0~6)
    days_to_next_week_bonus = 7 - cycle_days if cycle_days > 0 else 7

    # 2. 速度与预计达成测算
    history = acc_data.get("history", [])
    recent_earned = []
    # 提取最近 7 条记录中的非零增量
    for h in history[-7:]:
        e = h.get("earned", 0)
        if e > 0:
            recent_earned.append(e)
    
    if recent_earned:
        avg_speed = round(sum(recent_earned) / len(recent_earned), 1)
    else:
        avg_speed = 85.0  # 默认平均每天约 85~100 分

    remaining_pts = max(0, target_points - current_pts)
    progress_pct = min(100.0, round((current_pts / max(1, target_points)) * 100, 1))

    if remaining_pts > 0 and avg_speed > 0:
        est_days = math.ceil(remaining_pts / avg_speed)
        est_date = (datetime.date.today() + datetime.timedelta(days=est_days)).strftime("%Y-%m-%d")
    else:
        est_days = 0
        est_date = datetime.date.today().strftime("%Y-%m-%d")

    return {
        **acc_data,
        "current_points": current_pts,
        "today_earned": today_earned,
        "streak_days": streak_days,
        "streak_weeks": streak_weeks,
        "cycle_days": cycle_days,
        "days_to_next_week_bonus": days_to_next_week_bonus,
        "avg_speed": avg_speed,
        "remaining_pts": remaining_pts,
        "progress_pct": progress_pct,
        "est_days": est_days,
        "est_date": est_date
    }

def get_dashboard_summary() -> Dict[str, Any]:
    """生成看板完整汇总及图表数据"""
    store = load_rewards_store()
    target_pts = store.get("settings", {}).get("target_points", 20000)
    reward_name = store.get("settings", {}).get("reward_name", "微软大额官方礼品卡")

    accounts_list = []
    total_combined_pts = 0
    total_today_earned = 0

    # 收集日期集合生成 ECharts 统一 X 轴
    date_set = set()
    for email, acc in store.get("accounts", {}).items():
        for h in acc.get("history", []):
            if "date" in h:
                date_set.add(h["date"])
    
    sorted_dates = sorted(list(date_set))
    if not sorted_dates:
        sorted_dates = [(datetime.date.today() - datetime.timedelta(days=i)).strftime("%Y-%m-%d") for i in range(7, -1, -1)]

    chart_series_points = []
    chart_series_earned = []

    for email, acc in store.get("accounts", {}).items():
        metrics = calculate_account_metrics(acc, target_pts)
        accounts_list.append(metrics)
        total_combined_pts += metrics["current_points"]
        total_today_earned += metrics["today_earned"]

        # 构建图表历史数据
        hist_map = {h["date"]: h for h in acc.get("history", [])}
        pts_line = []
        earned_bar = []
        last_known = 0
        for d in sorted_dates:
            if d in hist_map:
                last_known = hist_map[d].get("points", last_known)
                pts_line.append(last_known)
                earned_bar.append(hist_map[d].get("earned", 0))
            else:
                pts_line.append(last_known)
                earned_bar.append(0)

        chart_series_points.append({
            "name": metrics.get("display_name", email.split("@")[0]),
            "email": email,
            "data": pts_line
        })
        chart_series_earned.append({
            "name": metrics.get("display_name", email.split("@")[0]),
            "email": email,
            "data": earned_bar
        })

    # 合计目标进度
    combined_target = target_pts * len(accounts_list) if accounts_list else target_pts
    combined_progress_pct = round((total_combined_pts / max(1, combined_target)) * 100, 1)

    return {
        "status": "success",
        "settings": {
            "target_points": target_pts,
            "reward_name": reward_name,
            "combined_target": combined_target
        },
        "kpis": {
            "total_combined_pts": total_combined_pts,
            "total_today_earned": total_today_earned,
            "combined_progress_pct": combined_progress_pct,
            "account_count": len(accounts_list)
        },
        "accounts": accounts_list,
        "charts": {
            "dates": sorted_dates,
            "series_points": chart_series_points,
            "series_earned": chart_series_earned
        },
        "logs": store.get("logs", [])[:30]
    }

def update_account_report(report_data: Dict[str, Any]) -> bool:
    """接收来自 HK-VPS 的单次或批量执行汇报"""
    store = load_rewards_store()
    items = report_data if isinstance(report_data, list) else report_data.get("accounts", [report_data])

    today_str = datetime.date.today().strftime("%Y-%m-%d")
    now_str = datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")

    for item in items:
        email = item.get("email")
        if not email:
            continue

        end_points = int(item.get("end_points") or item.get("points") or 0)
        earned_today = int(item.get("earned_today") or item.get("earned") or 0)
        status = item.get("status", "success")
        msg = item.get("message", "")
        streak = item.get("streak_days")

        if email not in store["accounts"]:
            store["accounts"][email] = {
                "email": email,
                "display_name": email.split("@")[0],
                "current_points": end_points,
                "today_earned": earned_today,
                "streak_days": 1,
                "last_updated": now_str,
                "status": status,
                "history": []
            }

        acc = store["accounts"][email]
        old_points = acc.get("current_points", 0)
        if end_points > 0:
            acc["current_points"] = end_points
            if earned_today == 0 and old_points > 0 and end_points > old_points:
                earned_today = end_points - old_points

        acc["today_earned"] = earned_today
        acc["status"] = status
        acc["last_updated"] = now_str

        if streak is not None:
            acc["streak_days"] = int(streak)
        else:
            # 若今日打卡成功，连签天数自增
            if status == "success" and acc.get("last_updated", "")[:10] != today_str:
                acc["streak_days"] = acc.get("streak_days", 0) + 1

        # 更新历史记录
        history = acc.setdefault("history", [])
        found_today = False
        for h in history:
            if h.get("date") == today_str:
                if end_points > 0:
                    h["points"] = end_points
                if earned_today > 0:
                    h["earned"] = earned_today
                found_today = True
                break
        if not found_today and end_points > 0:
            history.append({
                "date": today_str,
                "points": end_points,
                "earned": earned_today
            })

        # 记录日志流水
        store.setdefault("logs", []).insert(0, {
            "timestamp": now_str,
            "email": email,
            "status": status,
            "points": end_points,
            "earned": earned_today,
            "message": msg
        })

    # 保留最近 100 条日志
    store["logs"] = store["logs"][:100]
    return save_rewards_store(store)
