import os
import sys
import uuid
import json
import time
import threading
import subprocess
import requests
from flask import Flask, request, render_template, Response, abort, session, redirect, jsonify, send_file
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
app.config['TEMPLATES_AUTO_RELOAD'] = True
app.jinja_env.auto_reload = True

app.jinja_env.filters['url_quote'] = url_quote

@app.after_request
def add_no_cache_header(response):
    if request.path.startswith('/api/') or request.path in ['/', '/traffic', '/notes', '/cloud', '/2fa']:
        response.headers['Cache-Control'] = 'no-store, no-cache, must-revalidate, max-age=0'
        response.headers['Pragma'] = 'no-cache'
        response.headers['Expires'] = '0'
    return response

# 启动 Linux 内核物理网卡原生流量监控线程
try:
    from traffic_monitor import traffic_monitor
    traffic_monitor.start()
except Exception as e:
    app.logger.error(f"Failed to start traffic_monitor: {e}")

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

# ------------------------------------------
# 🔑 2FA / TOTP 服务端 AES-256-GCM 透明加密存储
# ------------------------------------------
_2FA_STORAGE_FILE = "/var/lib/2fa_secrets.json"

def _get_2fa_cipher_key():
    """根据面板私密凭证派生 256 位 AES-GCM 强密钥"""
    import hashlib
    seed = (str(config.PORTAL_PASSWORD) + str(app.config.get('SECRET_KEY', 'xray-portal-default-salt'))).encode('utf-8')
    return hashlib.sha256(seed).digest()

def _encrypt_2fa_data(data_obj):
    """将数据对象序列化并进行 AES-GCM-256 加密"""
    from cryptography.hazmat.primitives.ciphers.aead import AESGCM
    import secrets, base64
    key = _get_2fa_cipher_key()
    aesgcm = AESGCM(key)
    nonce = secrets.token_bytes(12)
    plaintext = json.dumps(data_obj, ensure_ascii=False).encode('utf-8')
    ciphertext = aesgcm.encrypt(nonce, plaintext, None)
    return {
        "_encrypted": True,
        "_version": 1,
        "algorithm": "AES-256-GCM",
        "updated_at": __import__('datetime').datetime.now().isoformat(),
        "nonce": base64.b64encode(nonce).decode('utf-8'),
        "data": base64.b64encode(ciphertext).decode('utf-8')
    }

def _decrypt_2fa_data(cipher_payload):
    """解密数据对象，兼容旧版明文格式并支持平滑升级"""
    if isinstance(cipher_payload, list):
        return cipher_payload
    if not isinstance(cipher_payload, dict) or not cipher_payload.get('_encrypted'):
        return cipher_payload

    from cryptography.hazmat.primitives.ciphers.aead import AESGCM
    import base64
    key = _get_2fa_cipher_key()
    aesgcm = AESGCM(key)
    nonce = base64.b64decode(cipher_payload['nonce'])
    ciphertext = base64.b64decode(cipher_payload['data'])
    decrypted_bytes = aesgcm.decrypt(nonce, ciphertext, None)
    return json.loads(decrypted_bytes.decode('utf-8'))

@app.route('/2fa', methods=['GET'])
def page_2fa():
    if not session.get('logged_in'):
        return redirect('/')
    return send_file('/var/www/2fa/index.html')

@app.route('/api/2fa/accounts', methods=['GET'])
def get_2fa_accounts():
    if not session.get('logged_in'):
        return abort(401)
    if not os.path.exists(_2FA_STORAGE_FILE):
        return jsonify([])
    try:
        with open(_2FA_STORAGE_FILE, 'r', encoding='utf-8') as f:
            raw = json.load(f)
            decrypted = _decrypt_2fa_data(raw)
            return jsonify(decrypted)
    except Exception as e:
        app.logger.error(f"Failed to read/decrypt 2fa accounts: {e}")
        return jsonify([])

@app.route('/api/2fa/accounts', methods=['POST'])
def save_2fa_accounts():
    if not session.get('logged_in'):
        return abort(401)
    data = request.get_json(silent=True)
    if data is None:
        return jsonify({"status": "error", "message": "Invalid payload"}), 400
    try:
        os.makedirs(os.path.dirname(_2FA_STORAGE_FILE), exist_ok=True)
        backup_dir = "/var/lib/2fa_backups"
        os.makedirs(backup_dir, exist_ok=True)

        # 自动轮转备份最近 20 份历史快照
        if os.path.exists(_2FA_STORAGE_FILE) and os.path.getsize(_2FA_STORAGE_FILE) > 0:
            import time
            bak_file = os.path.join(backup_dir, f"2fa_{int(time.time())}.json")
            shutil.copy2(_2FA_STORAGE_FILE, bak_file)
            shutil.copy2(_2FA_STORAGE_FILE, f"{_2FA_STORAGE_FILE}.bak")

        # 磁盘上以 AES-256-GCM 密文存储
        encrypted_dict = _encrypt_2fa_data(data)
        tmp_file = f"{_2FA_STORAGE_FILE}.tmp"
        with open(tmp_file, 'w', encoding='utf-8') as f:
            json.dump(encrypted_dict, f, ensure_ascii=False, indent=2)
        os.replace(tmp_file, _2FA_STORAGE_FILE)
        try:
            os.chmod(_2FA_STORAGE_FILE, 0o600)
        except Exception:
            pass
        return jsonify({"status": "success"})
    except Exception as e:
        return jsonify({"status": "error", "message": str(e)}), 500

# ------------------------------------------
# 📝 Markdown 在线渲染与编辑中心 API & 路由
# ------------------------------------------
NOTES_DIR = "/var/lib/markdown_notes"

def init_notes_dir():
    os.makedirs(NOTES_DIR, exist_ok=True)
    welcome_file = os.path.join(NOTES_DIR, "欢迎使用 Markdown 云笔记.md")
    if not os.path.exists(welcome_file):
        welcome_content = r"""# 📝 欢迎使用 VPS Markdown 云端编辑器与阅读器

这是一个运行在 VPS 云端的私有 Markdown 笔记管理系统，支持**实时双栏对比编辑**、**单栏沉浸阅读**和**云端持久化存储**。

---

## ✨ 核心特性

- **⚡ 实时解析**：高效率渲染 Markdown、代码高亮与表格
- **🖼️ 截图直接粘贴**：支持 `Ctrl+V` 剪贴板截图直接粘贴或图片拖拽，自动上传 VPS 并插入图片
- **📖 段落折叠**：阅读模式下点击任意标题 (H1-H4) 可直接折叠/展开后续段落
- **🔍 文档管理**：支持在线新建、重命名、搜索与一键删除

---

<details>
<summary>▶️ 点击展开/折叠 Notion 风格高级折叠块示例</summary>

这是一个 Notion 风格的折叠块示例，可以隐藏收纳长段落、代码或参考资料。

- 支持**任意 Markdown** 格式
- 可以内嵌代码块、列表与图片

</details>

---

## 💻 代码高亮示例

```python
def hello_vps():
    print("Hello, Markdown Notes on VPS!")
    
if __name__ == "__main__":
    hello_vps()
```

---

## 🧮 LaTeX 数学公式渲染示例

- 行内公式：$d_{\text{init}} \approx 2d \text{ or } 3d$
- 块级公式：
$$E = mc^2 \quad \text{and} \quad \int_{0}^{\infty} e^{-x^2} dx = \frac{\sqrt{\pi}}{2}$$

---

## 📊 表格渲染示例

| 功能模块 | 存储方式 | 安全级别 | 适用场景 |
| :--- | :--- | :--- | :--- |
| **Markdown 笔记** | VPS 磁盘存储 | 🔒 仅管理员鉴权可读 | 随手记、技术文档、待办列表 |
| **2FA 密钥** | VPS 磁盘 + 本地缓存 | 🛡️ Session 安全守护 | 动态验证码管理 |

---

## ⌨️ 快捷键说明
* `Ctrl + S` / `Cmd + S`：立即保存当前文档至 VPS 云端
"""
        try:
            with open(welcome_file, 'w', encoding='utf-8') as f:
                f.write(welcome_content)
        except Exception:
            pass

def _sanitize_filename(name):
    base = os.path.basename(name.strip())
    if not base.endswith('.md'):
        base += '.md'
    return base

@app.route('/notes', methods=['GET'])
@app.route('/markdown', methods=['GET'])
def notes_page():
    if not session.get('logged_in'):
        return redirect('/')
    init_notes_dir()
    return render_template('notes.html', logged_in=True, wallpapers=utils.get_random_wallpapers())

@app.route('/api/notes/list', methods=['GET'])
def api_notes_list():
    if not session.get('logged_in'):
        return abort(401)
    init_notes_dir()
    files = []
    for entry in os.scandir(NOTES_DIR):
        if entry.is_file() and entry.name.endswith('.md'):
            stat = entry.stat()
            files.append({
                'name': entry.name,
                'size': stat.st_size,
                'mtime': int(stat.st_mtime)
            })
    files.sort(key=lambda x: x['mtime'], reverse=True)
    return jsonify(files)

@app.route('/api/notes/read', methods=['GET'])
def api_notes_read():
    if not session.get('logged_in'):
        return abort(401)
    filename = request.args.get('filename', '')
    if not filename:
        return jsonify({'error': 'Filename required'}), 400
    safe_name = _sanitize_filename(filename)
    filepath = os.path.join(NOTES_DIR, safe_name)
    if not os.path.exists(filepath):
        return jsonify({'error': 'File not found'}), 404
    try:
        with open(filepath, 'r', encoding='utf-8') as f:
            content = f.read()
        return jsonify({'name': safe_name, 'content': content})
    except Exception as e:
        return jsonify({'error': str(e)}), 500

@app.route('/api/notes/save', methods=['POST'])
def api_notes_save():
    if not session.get('logged_in'):
        return abort(401)
    data = request.get_json(silent=True) or {}
    filename = data.get('filename', '')
    content = data.get('content', '')
    if not filename:
        return jsonify({'error': 'Filename required'}), 400
    safe_name = _sanitize_filename(filename)
    filepath = os.path.join(NOTES_DIR, safe_name)
    try:
        tmp_file = f"{filepath}.tmp"
        with open(tmp_file, 'w', encoding='utf-8') as f:
            f.write(content)
        os.replace(tmp_file, filepath)
        return jsonify({'status': 'success', 'name': safe_name})
    except Exception as e:
        return jsonify({'error': str(e)}), 500

@app.route('/api/notes/delete', methods=['POST'])
def api_notes_delete():
    if not session.get('logged_in'):
        return abort(401)
    data = request.get_json(silent=True) or {}
    filename = data.get('filename', '')
    if not filename:
        return jsonify({'error': 'Filename required'}), 400
    safe_name = _sanitize_filename(filename)
    filepath = os.path.join(NOTES_DIR, safe_name)
    if os.path.exists(filepath):
        try:
            os.remove(filepath)
            return jsonify({'status': 'success'})
        except Exception as e:
            return jsonify({'error': str(e)}), 500
    return jsonify({'error': 'File not found'}), 404

@app.route('/api/notes/rename', methods=['POST'])
def api_notes_rename():
    if not session.get('logged_in'):
        return abort(401)
    data = request.get_json(silent=True) or {}
    old_name = data.get('old_filename', '')
    new_name = data.get('new_filename', '')
    if not old_name or not new_name:
        return jsonify({'error': 'Old and new filenames required'}), 400
    safe_old = _sanitize_filename(old_name)
    safe_new = _sanitize_filename(new_name)
    old_path = os.path.join(NOTES_DIR, safe_old)
    new_path = os.path.join(NOTES_DIR, safe_new)
    if not os.path.exists(old_path):
        return jsonify({'error': 'Source file not found'}), 404
    try:
        os.rename(old_path, new_path)
        return jsonify({'status': 'success', 'new_name': safe_new})
    except Exception as e:
        return jsonify({'error': str(e)}), 500

# ------------------------------------------
# 🖼️ Markdown 截图粘贴与图片上传 API
# ------------------------------------------
NOTES_IMAGES_DIR = "/var/lib/markdown_notes/images"

@app.route('/api/notes/upload_image', methods=['POST'])
def api_notes_upload_image():
    if not session.get('logged_in'):
        return abort(401)
    os.makedirs(NOTES_IMAGES_DIR, exist_ok=True)
    if 'image' not in request.files:
        return jsonify({'error': 'No image file uploaded'}), 400
    file = request.files['image']
    if not file or not file.filename:
        return jsonify({'error': 'Empty image file'}), 400
    
    ext = os.path.splitext(file.filename)[1].lower()
    if ext not in ['.png', '.jpg', '.jpeg', '.gif', '.webp', '.svg', '.bmp']:
        ext = '.png'
    
    filename = f"img_{time.strftime('%Y%m%d_%H%M%S')}_{uuid.uuid4().hex[:8]}{ext}"
    filepath = os.path.join(NOTES_IMAGES_DIR, filename)
    try:
        file.save(filepath)
        try:
            os.chmod(filepath, 0o666)
        except Exception:
            pass
        return jsonify({
            'status': 'success',
            'filename': filename,
            'url': f'/api/notes/images/{filename}'
        })
    except Exception as e:
        return jsonify({'error': str(e)}), 500

@app.route('/api/notes/images/<filename>', methods=['GET'])
def api_notes_serve_image(filename):
    if not session.get('logged_in'):
        return abort(401)
    safe_name = os.path.basename(filename.strip())
    filepath = os.path.join(NOTES_IMAGES_DIR, safe_name)
    if not os.path.exists(filepath):
        return abort(404)
    return send_file(filepath)

@app.route('/api/notes/images/list', methods=['GET'])
def api_notes_images_list():
    if not session.get('logged_in'):
        return abort(401)
    os.makedirs(NOTES_IMAGES_DIR, exist_ok=True)
    images = []
    try:
        for fname in os.listdir(NOTES_IMAGES_DIR):
            fpath = os.path.join(NOTES_IMAGES_DIR, fname)
            if os.path.isfile(fpath) and fname.lower().endswith(('.png', '.jpg', '.jpeg', '.gif', '.webp', '.svg', '.bmp')):
                stat = os.stat(fpath)
                images.append({
                    'name': fname,
                    'url': f'/api/notes/images/{fname}',
                    'size': stat.st_size,
                    'mtime': stat.st_mtime
                })
        images.sort(key=lambda x: x['mtime'], reverse=True)
        return jsonify(images)
    except Exception as e:
        return jsonify({'error': str(e)}), 500

@app.route('/api/notes/images/delete', methods=['POST'])
def api_notes_images_delete():
    if not session.get('logged_in'):
        return abort(401)
    data = request.get_json(silent=True) or {}
    filename = data.get('filename', '')
    if not filename:
        return jsonify({'error': 'Filename required'}), 400
    safe_name = os.path.basename(filename.strip())
    filepath = os.path.join(NOTES_IMAGES_DIR, safe_name)
    if os.path.exists(filepath):
        try:
            os.remove(filepath)
            return jsonify({'status': 'success'})
        except Exception as e:
            return jsonify({'error': str(e)}), 500
    return jsonify({'error': 'Image file not found'}), 404

@app.route('/api/notes/images/clean_orphans', methods=['POST'])
def api_notes_images_clean_orphans():
    if not session.get('logged_in'):
        return abort(401)
    os.makedirs(NOTES_IMAGES_DIR, exist_ok=True)
    os.makedirs(NOTES_DIR, exist_ok=True)
    
    referenced_images = set()
    try:
        all_imgs = set(os.listdir(NOTES_IMAGES_DIR))
        for nfile in os.listdir(NOTES_DIR):
            if nfile.endswith('.md'):
                npath = os.path.join(NOTES_DIR, nfile)
                try:
                    with open(npath, 'r', encoding='utf-8') as f:
                        content = f.read()
                        for img in all_imgs:
                            if img in content:
                                referenced_images.add(img)
                except Exception:
                    pass
        
        deleted_count = 0
        deleted_size = 0
        for img in all_imgs:
            fpath = os.path.join(NOTES_IMAGES_DIR, img)
            if os.path.isfile(fpath) and img not in referenced_images:
                try:
                    deleted_size += os.path.getsize(fpath)
                    os.remove(fpath)
                    deleted_count += 1
                except Exception:
                    pass
        return jsonify({
            'status': 'success',
            'deleted_count': deleted_count,
            'deleted_size_kb': round(deleted_size / 1024, 1)
        })
    except Exception as e:
        return jsonify({'error': str(e)}), 500

@app.route('/api/traffic', methods=['GET'])
def api_traffic():
    if not session.get('logged_in'):
        return abort(401)
    
    # 纯原生 /proc/net/dev 物理网卡流量监控数据
    from traffic_monitor import traffic_monitor
    summary = traffic_monitor.get_summary()

    # 封装为前端 ECharts 完全兼容的结构
    vnstat_compatible_data = {
        "interfaces": [
            {
                "name": summary['iface'],
                "speed": summary['speed'],
                "traffic": {
                    "total": summary['total'],
                    "day": summary['day'] if summary['day'] else [{'rx': summary['today']['rx'], 'tx': summary['today']['tx']}],
                    "month": [{'rx': summary['month']['rx'], 'tx': summary['month']['tx']}],
                    "hour": summary['hour']
                }
            }
        ]
    }

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
            
            import re
            
            # 基本信息
            m_time = re.search(r"检查时间：(.*?)\n", log_content)
            m_tcp = re.search(r"已建立 TCP 连接：(\d+)", log_content)
            m_syn = re.search(r"等待建立的出站连接：(\d+)", log_content)
            
            parsed_log["time"] = m_time.group(1).strip() if m_time else "未知"
            parsed_log["tcp_est"] = m_tcp.group(1).strip() if m_tcp else "0"
            parsed_log["tcp_syn"] = m_syn.group(1).strip() if m_syn else "0"
            
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
        "vnstat": vnstat_compatible_data,
        "summary": summary,
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
