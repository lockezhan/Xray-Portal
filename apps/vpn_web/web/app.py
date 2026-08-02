import os
import sys
import uuid
import json
import time
import threading
import subprocess
import requests
from flask import Flask, request, render_template, Response, abort, session, redirect, jsonify
from flask import stream_with_context
from urllib.parse import quote as url_quote
import utils
import config

# 全局任务状态字典 {job_id: {status, url, msg, start_time, end_time}}
_TG_JOBS: dict = {}
_TG_JOBS_LOCK = threading.Lock()

def _run_tg_job(job_id: str, cmd: list):
    """在后台线程中执行 fetch_link.py 并更新任务状态"""
    with _TG_JOBS_LOCK:
        _TG_JOBS[job_id]['status'] = 'running'
    proc = None
    try:
        proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        stdout, stderr = proc.communicate(timeout=600)  # 最长等 10 分钟
        out_text = stdout.decode('utf-8', errors='ignore').strip()
        err_text = stderr.decode('utf-8', errors='ignore').strip()
        # 尝试解析 JSON 输出
        try:
            result = json.loads(out_text)
            if result.get('success'):
                files = result.get('files', [])
                # 统计已下载及解压的文件
                total = len(files)
                unzip_errs = [f.get('unzip_error') for f in files if f.get('unzip_error')]
                if unzip_errs:
                    msg = f"✅ 已下载 {total} 个文件，但解压出错：{unzip_errs[0][:120]}"
                    status = 'warning'
                else:
                    msg = f"✅ 下载并解压完成，共 {total} 个文件已存入网盘！"
                    status = 'done'
            else:
                msg = f"❌ 拉取失败：{result.get('error', '未知错误')}"
                status = 'error'
        except Exception:
            if proc.returncode == 0:
                msg = "✅ 任务完成（无结构化输出）"
                status = 'done'
            else:
                msg = f"❌ 脚本报错：{(err_text or out_text)[:200]}"
                status = 'error'
    except subprocess.TimeoutExpired:
        if proc is not None:
            proc.kill()
        msg = "⚠️ 任务超时（>10 分钟），进程已被强制终止"
        status = 'error'
    except Exception as e:
        msg = f"❌ 内部异常：{e}"
        status = 'error'
    with _TG_JOBS_LOCK:
        _TG_JOBS[job_id]['status'] = status
        _TG_JOBS[job_id]['msg'] = msg
        _TG_JOBS[job_id]['end_time'] = time.time()
    # 任务结束后 10 秒自动从列表移除，前端轮询时自然消失
    def _auto_remove():
        time.sleep(10)
        with _TG_JOBS_LOCK:
            _TG_JOBS.pop(job_id, None)
    threading.Thread(target=_auto_remove, daemon=True).start()

def load_env():
    # 测试模式下不读取磁盘上的真实 .env 文件，以防污染和数据混淆
    if os.environ.get("TESTING") == "true":
        return
        
    cur_dir = os.path.dirname(os.path.abspath(__file__))
    for _ in range(3):
        env_path = os.path.join(cur_dir, ".env")
        if os.path.exists(env_path):
            with open(env_path, "r", encoding="utf-8") as f:
                for line in f:
                    line = line.strip()
                    if not line or line.startswith("#"):
                        continue
                    if "=" in line:
                        key, val = line.split("=", 1)
                        os.environ[key.strip()] = val.strip()
            break
        cur_dir = os.path.dirname(cur_dir)

# 自动载入环境变量
load_env()

# 安全红线：必须获取有效的订阅 Token 与分发域名基准
SUB_TOKEN = os.environ.get("SUB_TOKEN")
SUB_PUBLIC_URL = os.environ.get("SUB_PUBLIC_URL")
SUB_PUBLIC_BASE_URL = os.environ.get("SUB_PUBLIC_BASE_URL")

# 严苛机制：若缺少 SUB_TOKEN，立即失败关闭，拒绝回落生成无保护的链接
if not SUB_TOKEN:
    print("[CRITICAL] SUB_TOKEN 环境变量缺失！系统被迫关闭。", file=sys.stderr)
    sys.exit(1)

# 根据环境变量安全构造订阅 URL，不依赖于 request.host 注入
if SUB_PUBLIC_URL:
    FINAL_SUB_URL = SUB_PUBLIC_URL
else:
    if not SUB_PUBLIC_BASE_URL:
        print("[CRITICAL] 缺少 SUB_PUBLIC_URL 或 SUB_PUBLIC_BASE_URL 域名配置！系统被迫关闭。", file=sys.stderr)
        sys.exit(1)
    # 去除斜杠拼接
    base_url = SUB_PUBLIC_BASE_URL.rstrip('/')
    FINAL_SUB_URL = f"{base_url}/{SUB_TOKEN}/clash.yaml"

app = Flask(__name__)
app.secret_key = config.SECRET_KEY

app.jinja_env.filters['url_quote'] = url_quote

# 只允许代理下载的仓库列表
_ALLOWED_REPO_LABELS = frozenset({'ClashVergeRev', 'FlClash'})

@app.route('/', methods=['GET'])
def index():
    wallpapers = utils.get_random_wallpapers()
    downloads = utils.get_clash_releases()
    
    if not session.get('logged_in'):
        return render_template('index.html', logged_in=False, wallpapers=wallpapers, downloads=downloads)

    # 脱敏打印最终订阅链接到系统控制台
    # SUB_TOKEN 已在启动时验证非 None（见上方 sys.exit(1) 守护）
    assert SUB_TOKEN is not None  # 满足 Pyright 类型检查
    safe_token = SUB_TOKEN[:6] + "..." + SUB_TOKEN[-6:] if len(SUB_TOKEN) > 12 else "..."
    safe_sub_url = FINAL_SUB_URL.replace(SUB_TOKEN, safe_token)
    print(f"[INFO] 登录用户请求了面板首页，展示脱敏订阅 URL: {safe_sub_url}")

    return render_template('index.html', 
                            logged_in=True,
                            sub_url=FINAL_SUB_URL,
                            wallpapers=wallpapers, 
                            downloads=downloads)

@app.route('/login', methods=['POST'])
def login():
    password = request.form.get('password')
    if password == config.PORTAL_PASSWORD:
        session['logged_in'] = True
        return redirect('/')
    else:
        return render_template('index.html', logged_in=False, error="密码错误。",
                               wallpapers=utils.get_random_wallpapers(),
                               downloads=utils.get_clash_releases())

@app.route('/logout')
def logout():
    session.pop('logged_in', None)
    return redirect('/')

# ==========================================
# 🏥 健康检查端点（不泄露任何秘密信息）
# ==========================================
@app.route('/health')
def health():
    """
    健康检查端点：供 install.sh 在启用 Nginx 前验证后端存活。
    - 不需要认证
    - 不包含订阅 URL、Token、密码等任何配置信息
    - 仅返回服务运行状态
    """
    return jsonify({"status": "ok"}), 200

# ==========================================
# 🛡️ 订阅文件安全分发路由 (公网安全加锁)
# ==========================================

# 1. 拦截无 Token 路径的下载请求，直接返回 410 Gone / 404 Not Found，杜绝暴露真实节点配置
@app.route('/clash.yaml', methods=['GET'])
def serve_clash_yaml_unprotected():
    return abort(410, "Subscription URL is deprecated or missing authorization token.")

# 2. 只有匹配正确 Token 路径的请求才允许下载最终合并订阅配置
@app.route('/<token>/clash.yaml', methods=['GET'])
def serve_clash_yaml_protected(token):
    if token != SUB_TOKEN:
        return abort(404, "Invalid subscription token.")
        
    file_path = '/opt/clash-sub/published/clash.yaml'
    if not os.path.exists(file_path):
        # 兼容备用本地生成目录
        file_path = '/var/www/clash/clash.yaml'
        if not os.path.exists(file_path):
            return abort(404, "Subscription configuration file not found.")

    with open(file_path, 'r', encoding='utf-8') as f:
        content = f.read()
    return Response(content, mimetype='text/yaml')

@app.route('/api/proxy-releases')
def api_releases():
    releases = utils.get_clash_releases()
    return jsonify(releases)

# ==========================================
# 📊 流量与安全监控及私有云网盘面板 (需登录)
# ==========================================
@app.route('/cloud', methods=['GET'])
def cloud_page():
    if not session.get('logged_in'):
        return redirect('/')
    return render_template('cloud.html', logged_in=True, wallpapers=utils.get_random_wallpapers())

@app.route('/traffic', methods=['GET'])
def traffic():
    if not session.get('logged_in'):
        return redirect('/')
    return render_template('traffic.html', logged_in=True, wallpapers=utils.get_random_wallpapers())

@app.route('/api/traffic', methods=['GET'])
def api_traffic():
    if not session.get('logged_in'):
        return abort(401)
    
    import subprocess
    import json
    
    # 获取 vnstat json 数据
    vnstat_data = {}
    try:
        res = subprocess.run(["vnstat", "--json"], capture_output=True, text=True, check=True)
        vnstat_data = json.loads(res.stdout)
    except Exception as e:
        vnstat_data = {"error": str(e)}

    # 获取最后一次安全检查日志
    parsed_log = {}
    try:
        with open("/var/log/traffic-watch.log", "r", encoding="utf-8") as f:
            content = f.read()
            last_idx = content.rfind("============================================================")
            if last_idx != -1:
                log_content = content[last_idx:]
            else:
                log_content = content
            
            # 简单解析逻辑
            import re
            
            # 基本信息
            m_time = re.search(r"检查时间：(.*?)\n", log_content)
            m_tcp = re.search(r"已建立 TCP 连接：(\d+)", log_content)
            m_syn = re.search(r"等待建立的出站连接：(\d+)", log_content)
            
            parsed_log["time"] = m_time.group(1).strip() if m_time else "未知"
            parsed_log["tcp_est"] = m_tcp.group(1).strip() if m_tcp else "0"
            parsed_log["tcp_syn"] = m_syn.group(1).strip() if m_syn else "0"
            
            # 提取各个板块
            sections = [
                ("listen_ports", "对外监听端口"),
                ("top_ips", "连接最多的目标 IP"),
                ("syn_sent", "尚未建立成功的出站连接"),
                ("top_cpu", "CPU 占用最高的进程"),
                ("top_mem", "内存占用最高的进程"),
                ("ssh_fail", "最近一小时 SSH 失败记录"),
                ("ufw_block", "最近一小时 UFW 拦截记录")
            ]
            
            for key, title in sections:
                pattern = f"----- {title} -----\\n(.*?)(?=\\n----- |\\Z)"
                m = re.search(pattern, log_content, re.DOTALL)
                if m:
                    val = m.group(1).strip()
                    parsed_log[key] = val if val else "无记录"
                else:
                    parsed_log[key] = "无记录"
    except Exception as e:
        parsed_log["error"] = f"无法读取或解析日志: {e}"

    return jsonify({
        "vnstat": vnstat_data,
        "log": parsed_log
    })

@app.route('/proxy-download')
def proxy_download():
    repo_label = request.args.get('repo', '').strip()
    filename = request.args.get('filename', '').strip()

    filename = os.path.basename(filename)

    if not repo_label or not filename or repo_label not in _ALLOWED_REPO_LABELS:
        abort(400)

    releases = utils.get_clash_releases()
    download_url = None
    for repo in releases:
        if repo.get('label') == repo_label:
            for asset in repo.get('assets', []):
                if asset.get('name') == filename:
                    download_url = asset.get('url')
                    break
        if download_url:
            break

    if not download_url:
        abort(404)

    # 仅放行特定仓库
    if not download_url.startswith('https://github.com/clash-verge-rev/') and \
       not download_url.startswith('https://github.com/chen08209/FlClash/'):
        abort(403)

    try:
        upstream = requests.get(download_url, stream=True, timeout=(30, 300))
        upstream.raise_for_status()

        def generate():
            for chunk in upstream.iter_content(chunk_size=65536):
                if chunk:
                    yield chunk

        resp_headers = {
            'Content-Disposition': f'attachment; filename="{filename}"',
            'Content-Type': upstream.headers.get('Content-Type', 'application/octet-stream'),
        }
        if 'Content-Length' in upstream.headers:
            resp_headers['Content-Length'] = upstream.headers['Content-Length']

        return Response(stream_with_context(generate()), headers=resp_headers)
    except requests.exceptions.RequestException as e:
        print(f"Proxy download failed: {e}", file=sys.stderr)
        abort(502)

@app.route('/api/tg_download', methods=['POST'])
def api_tg_download():
    if not session.get('logged_in'):
        return abort(401)
    
    data = request.get_json(silent=True) or request.form
    tg_url = data.get('url', '').strip()
    password = data.get('password', '').strip()
    
    if not tg_url or not ('t.me/' in tg_url or 'telegram' in tg_url):
        return jsonify({"status": "error", "message": "请输入有效的 Telegram 消息链接 (例如 https://t.me/c/xxx/123)"}), 400
        
    cmd = ["/usr/local/tg_bot/venv/bin/python3", "/usr/local/tg_bot/fetch_link.py", tg_url, "--unzip"]
    if password:
        cmd.extend(["--password", password])
    
    job_id = uuid.uuid4().hex[:12]
    with _TG_JOBS_LOCK:
        _TG_JOBS[job_id] = {
            'status': 'pending',
            'url': tg_url,
            'msg': '⏳ 任务已排队，正在启动多线程拉取引擎…',
            'start_time': time.time(),
            'end_time': None,
        }
    thread = threading.Thread(target=_run_tg_job, args=(job_id, cmd), daemon=True)
    thread.start()
    return jsonify({
        "status": "success",
        "job_id": job_id,
        "message": "🚀 任务已提交！可在下方实时进度面板中查看状态。"
    })

@app.route('/api/tg_jobs', methods=['GET'])
def api_tg_jobs():
    if not session.get('logged_in'):
        return abort(401)
    with _TG_JOBS_LOCK:
        # 返回最近 10 个，按开始时间倒序
        jobs = sorted(_TG_JOBS.items(), key=lambda x: x[1]['start_time'], reverse=True)[:10]
        result = []
        for jid, jinfo in jobs:
            elapsed = int(time.time() - jinfo['start_time'])
            result.append({
                'id': jid,
                'status': jinfo['status'],
                'url': jinfo['url'][-60:],  # 截断 URL
                'msg': jinfo['msg'],
                'elapsed': elapsed,
            })
    return jsonify(result)

if __name__ == '__main__':
    port = 8080
    if len(sys.argv) > 1:
        try:
            port = int(sys.argv[1])
        except ValueError:
            pass
    app.run(host='0.0.0.0', port=port, debug=False)
