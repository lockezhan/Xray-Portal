import os
import requests
from flask import Flask, request, render_template, Response, abort, session, redirect
from flask import stream_with_context
from urllib.parse import quote as url_quote
import utils
import config

app = Flask(__name__)
app.secret_key = config.SECRET_KEY

app.jinja_env.filters['url_quote'] = url_quote

# We will proxy clash-verge-rev and FlClash
_ALLOWED_REPO_LABELS = frozenset({'ClashVergeRev', 'FlClash'})

@app.route('/', methods=['GET'])
def index():
    wallpapers = utils.get_random_wallpapers()
    downloads = utils.get_clash_releases()
    
    if not session.get('logged_in'):
        return render_template('index.html', logged_in=False, wallpapers=wallpapers, downloads=downloads)

    current_host = request.host
    sub_url = f"http://{current_host}/clash.yaml"

    return render_template('index.html', 
                           logged_in=True,
                           sub_url=sub_url,
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

@app.route('/clash.yaml', methods=['GET'])
def serve_clash_yaml():
    file_path = '/var/www/clash/clash.yaml'
    if not os.path.exists(file_path):
        abort(404, "Subscription file not found. Ensure gen_clash_config.sh was executed.")

    user_agent = request.headers.get('User-Agent', '').lower()
    clash_keywords = ['clash', 'verge', 'flclash', 'meta', 'mihomo']
    is_clash_client = any(k in user_agent for k in clash_keywords)

    if not is_clash_client:
        import base64
        fake_content = base64.b64encode("Please use a valid Clash client (e.g. Clash Verge, FlClash) to import this subscription.".encode('utf-8')).decode('utf-8')
        return Response(fake_content, mimetype='text/plain')

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

    # Allow Github downloads for clash-verge-rev or FlClash
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
        print(f"Proxy download failed [{download_url}]: {e}")
        abort(502)

if __name__ == '__main__':
    import sys
    port = 8080
    if len(sys.argv) > 1:
        try:
            port = int(sys.argv[1])
        except ValueError:
            pass
    # Listen on all interfaces so Cloudflare can proxy it
    app.run(host='0.0.0.0', port=port, debug=False)
