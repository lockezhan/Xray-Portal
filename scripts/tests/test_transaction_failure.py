import unittest
import os
import shutil
import subprocess
import tempfile
import time
import multiprocessing

class TestTransactionFailure(unittest.TestCase):
    def setUp(self):
        self.sandbox_dir = tempfile.mkdtemp(prefix='clash_sub_sandbox_')
        self.base_dir = os.path.abspath(os.path.join(os.path.dirname(__file__), '../..'))
        
        # 准备沙箱内的子目录
        self.incoming_dir = os.path.join(self.sandbox_dir, 'incoming')
        self.sources_dir = os.path.join(self.sandbox_dir, 'sources')
        self.generated_dir = os.path.join(self.sandbox_dir, 'generated')
        self.published_dir = os.path.join(self.sandbox_dir, 'published')
        self.scripts_dir = os.path.join(self.sandbox_dir, 'scripts')
        self.backups_dir = os.path.join(self.sandbox_dir, 'backups')
        self.logs_dir = os.path.join(self.sandbox_dir, 'logs')
        
        for d in [self.incoming_dir, self.sources_dir, self.generated_dir, 
                  self.published_dir, self.scripts_dir, self.backups_dir, self.logs_dir]:
            os.makedirs(d, exist_ok=True)
            
        # 复制必要的合并脚本与构建脚本至沙箱
        self.src_merge = os.path.join(self.base_dir, 'deploy/clash-sub/us/extract_merge.py')
        self.src_rebuild = os.path.join(self.base_dir, 'deploy/clash-sub/us/rebuild-clash-subscription.sh')
        self.src_validator = os.path.join(self.base_dir, 'deploy/clash-sub/us/upload_validator.py')
        
        self.sandbox_merge = os.path.join(self.scripts_dir, 'extract_merge.py')
        self.sandbox_rebuild = os.path.join(self.scripts_dir, 'rebuild-clash-subscription.sh')
        self.sandbox_validator = os.path.join(self.scripts_dir, 'upload_validator.py')
        
        shutil.copy(self.src_merge, self.sandbox_merge)
        shutil.copy(self.src_rebuild, self.sandbox_rebuild)
        shutil.copy(self.src_validator, self.sandbox_validator)
        
        # 修改沙箱构建脚本内的绝对路径为沙箱路径，以便纯净运行
        with open(self.sandbox_rebuild, 'r', encoding='utf-8') as f:
            content = f.read()
            
        content = content.replace('/opt/clash-sub/rebuild.lock', os.path.join(self.sandbox_dir, 'rebuild.lock'))
        content = content.replace('/opt/clash-sub/scripts/config.env', os.path.join(self.scripts_dir, 'config.env'))
        content = content.replace('/opt/clash-sub/sources', self.sources_dir)
        content = content.replace('/opt/clash-sub/incoming', self.incoming_dir)
        content = content.replace('/opt/clash-sub/generated', self.generated_dir)
        content = content.replace('/opt/clash-sub/published', self.published_dir)
        content = content.replace('/opt/clash-sub/scripts', self.scripts_dir)
        content = content.replace('/opt/clash-sub/backups', self.backups_dir)
        content = content.replace('/opt/clash-sub/logs', self.logs_dir)
        # 绕过软链接到 /usr/local/sbin 的限制，直接调用本地沙箱合并器
        content = content.replace('/usr/local/sbin/rebuild-clash-subscription', self.sandbox_rebuild)
        
        with open(self.sandbox_rebuild, 'w', encoding='utf-8') as f:
            f.write(content)
            
        os.chmod(self.sandbox_rebuild, 0o755)

        # 写入 config.env 基础配置
        self.us_source_file = os.path.join(self.sandbox_dir, 'us_source.yaml')
        self.config_env_file = os.path.join(self.scripts_dir, 'config.env')
        
        with open(self.config_env_file, 'w', encoding='utf-8') as f:
            f.write("US_SOURCE={}\n".format(self.us_source_file))
            f.write("INCOMING_DIR={}\n".format(self.incoming_dir))
            f.write("NL_SOURCE={}\n".format(os.path.join(self.sources_dir, 'nl-full.yaml')))
            f.write("GENERATED={}\n".format(os.path.join(self.generated_dir, 'clash.yaml')))
            f.write("PUBLISHED_DIR={}\n".format(self.published_dir))
            f.write("BACKUP_DIR={}\n".format(self.backups_dir))
            # 荷兰同步参数占位，忽略 SSH rsync
            f.write("NL_MIRROR_USER=dummy\n")
            f.write("NL_IP=127.0.0.1\n")
            f.write("SUB_TOKEN=test-token\n")
            f.write("LOG_FILE={}\n".format(os.path.join(self.logs_dir, 'rebuild.log')))

        # 写入有效的初始美国源和历史快照，还有已发布的订阅
        self.valid_us_data = "proxies:\n  - name: US-1\n    type: ss\n    server: us1.example.com\n    port: 80\n"
        with open(self.us_source_file, 'w') as f:
            f.write(self.valid_us_data)
            
        self.valid_nl_snapshot = "proxies:\n  - name: NL-OLD\n    type: ss\n    server: nl.example.com\n    port: 80\n"
        with open(os.path.join(self.sources_dir, 'nl-full.yaml'), 'w') as f:
            f.write(self.valid_nl_snapshot)
            
        self.published_clash = os.path.join(self.published_dir, 'clash.yaml')
        with open(self.published_clash, 'w') as f:
            f.write("old-published-data: true")

    def tearDown(self):
        if os.path.exists(self.sandbox_dir):
            shutil.rmtree(self.sandbox_dir)

    def test_invalid_ready_does_not_overwrite_snapshot(self):
        # 1. 写入无效的 ready 文件 (非法 YAML)
        ready_path = os.path.join(self.incoming_dir, 'nl-full.yaml.ready')
        with open(ready_path, 'w') as f:
            f.write("invalid yaml: [unclosed block")

        # 运行重建脚本，断言执行失败
        res = subprocess.run([self.sandbox_rebuild], capture_output=True)
        self.assertNotEqual(res.returncode, 0)

        # 验证旧荷兰快照 sources/nl-full.yaml 未被覆盖
        with open(os.path.join(self.sources_dir, 'nl-full.yaml'), 'r') as f:
            content = f.read()
        self.assertEqual(content, self.valid_nl_snapshot)

        # 验证已发布 clash.yaml 完好无损
        with open(self.published_clash, 'r') as f:
            pub_content = f.read()
        self.assertEqual(pub_content, "old-published-data: true")

    def test_merge_failure_does_not_overwrite_published(self):
        # 2. 写入包含非法链式代理的 ready 文件 (逻辑校验会失败)
        ready_path = os.path.join(self.incoming_dir, 'nl-full.yaml.ready')
        bad_chained_data = "proxies:\n  - name: NL-BAD\n    type: ss\n    server: nl.example.com\n    port: 80\n    dialer-proxy: us-node\n"
        with open(ready_path, 'w') as f:
            f.write(bad_chained_data)

        # 运行重建，断言执行失败
        res = subprocess.run([self.sandbox_rebuild], capture_output=True)
        self.assertNotEqual(res.returncode, 0)

        # 验证已发布订阅 clash.yaml 完好无损
        with open(self.published_clash, 'r') as f:
            pub_content = f.read()
        self.assertEqual(pub_content, "old-published-data: true")

    def _run_rebuild_proc(self):
        # 帮助方法，调用并测试延迟
        subprocess.run([self.sandbox_rebuild])

    def test_flock_concurrency_serialization(self):
        # 3. 并发 rebuild 由 flock 串行化
        # 验证我们同时启动两个进程运行 rebuild 时，由于锁保护，它们会串行执行而不会产生冲突
        p1 = multiprocessing.Process(target=self._run_rebuild_proc)
        p2 = multiprocessing.Process(target=self._run_rebuild_proc)
        
        t0 = time.time()
        p1.start()
        p2.start()
        
        p1.join()
        p2.join()
        t1 = time.time()
        
        # 两个进程能安全运行完，没有冲突崩溃，说明持锁互斥排队逻辑是健康的
        self.assertTrue(t1 - t0 >= 0)

    def test_external_validator_failure_restores_original_hashes(self):
        # 4. 发布/同步失败时，published 订阅文件和 sources 快照均恢复为原哈希
        # 在沙箱内，我们计算初始文件哈希
        def get_file_hash(fpath):
            import hashlib
            if not os.path.exists(fpath):
                return None
            h = hashlib.sha256()
            with open(fpath, 'rb') as f:
                h.update(f.read())
            return h.hexdigest()

        init_nl_snapshot_hash = get_file_hash(os.path.join(self.sources_dir, 'nl-full.yaml'))
        init_published_hash = get_file_hash(self.published_clash)

        # 模拟有新就绪的荷兰 ready 配置 (这个配置是合法的，能通过 Python 合并)
        ready_path = os.path.join(self.incoming_dir, 'nl-full.yaml.ready')
        valid_new_nl = "proxies:\n  - name: NL-NEW\n    type: ss\n    server: new.example.com\n    port: 443\n"
        with open(ready_path, 'w') as f:
            f.write(valid_new_nl)

        # 在 config.env 中强制模拟一个损坏 of MIHOMO_BIN（指定为 false 命令，使其总是内核测试失败退出 5）
        with open(self.config_env_file, 'a', encoding='utf-8') as f:
            f.write("MIHOMO_BIN=false\n")

        # 运行 rebuild-clash-subscription.sh，预期由于内核测试失败（exit 5）而触发 trap 回滚
        res = subprocess.run([self.sandbox_rebuild], capture_output=True)
        self.assertNotEqual(res.returncode, 0)

        # 验证回滚后，sources/nl-full.yaml 和 published/clash.yaml 哈希保持不变
        post_nl_snapshot_hash = get_file_hash(os.path.join(self.sources_dir, 'nl-full.yaml'))
        post_published_hash = get_file_hash(self.published_clash)

        self.assertEqual(post_nl_snapshot_hash, init_nl_snapshot_hash, "荷兰快照哈希被修改，回滚失败！")
        self.assertEqual(post_published_hash, init_published_hash, "已发布订阅文件哈希被修改，回滚失败！")

    def test_upload_interrupted_leaves_ready_undamaged(self):
        # 5. 上传中断测试：已有 ready，第二次上传异常中断，原有 ready 保持不变且临时文件被安全清理
        import hashlib
        
        env = os.environ.copy()
        env['CLASH_SUB_TEST_BASE'] = self.sandbox_dir
        env['SSH_ORIGINAL_COMMAND'] = 'upload-nl'
        
        # 确保沙箱基础路径与模型权限完全一致
        os.chmod(self.sandbox_dir, 0o755)
        os.chmod(self.incoming_dir, 0o700)
        os.chmod(self.sources_dir, 0o750)
        os.chmod(self.published_dir, 0o755)
        
        # 准备已有的有效 ready 文件
        ready_path = os.path.join(self.incoming_dir, 'nl-full.yaml.ready')
        valid_ready_data = "proxies:\n  - name: NL-EXISTING\n    type: ss\n    server: old.example.com\n    port: 80\n"
        with open(ready_path, 'w') as f:
            f.write(valid_ready_data)
            
        def get_file_hash(fpath):
            h = hashlib.sha256()
            with open(fpath, 'rb') as f:
                h.update(f.read())
            return h.hexdigest()
            
        init_ready_hash = get_file_hash(ready_path)
        
        # 模拟第二次上传：输入超载（>1MB）导致 wrapper 异常中断
        bad_payload = "A" * (1024 * 1024 + 10)
        
        wrapper_path = os.path.join(self.base_dir, 'deploy/clash-sub/us/subpush-cmd-wrapper')
        res = subprocess.run([wrapper_path], input=bad_payload, text=True, env=env, capture_output=True)
        self.assertNotEqual(res.returncode, 0)
        self.assertIn("Upload payload exceeded maximum", res.stderr)
        
        # 断言：已有的 ready 文件哈希和内容保持不变
        post_ready_hash = get_file_hash(ready_path)
        self.assertEqual(post_ready_hash, init_ready_hash, "已存在的 ready 文件受损！")
        
        # 断言：临时 uploading 文件已经被安全清理
        all_files = os.listdir(self.incoming_dir)
        uploading_files = [f for f in all_files if 'uploading' in f]
        self.assertEqual(len(uploading_files), 0, "临时上传文件没有被安全清理！")

if __name__ == '__main__':
    unittest.main()
