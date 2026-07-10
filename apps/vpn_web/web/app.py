import os
import sys
import requests
from flask import Flask, request, render_template, Response, abort, session, redirect, jsonify
from flask import stream_with_context
from urllib.parse import quote as url_quote
import utils
import config

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
       not download_url.startswith('https://github.com/chen08209/'):
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

if __name__ == '__main__':
    port = 8080
    if len(sys.argv) > 1:
        try:
            port = int(sys.argv[1])
        except ValueError:
            pass
    app.run(host='0.0.0.0', port=port, debug=False)
