import unittest
import os

class TestUploadProtocol(unittest.TestCase):
    def setUp(self):
        self.base_dir = os.path.abspath(os.path.join(os.path.dirname(__file__), '../..'))
        self.secondary_push = os.path.join(self.base_dir, 'deploy/clash-sub/secondary/push-clash-subscription-secondary.sh')
        self.primary_wrapper = os.path.join(self.base_dir, 'deploy/clash-sub/primary/subpush-cmd-wrapper')
        self.primary_rebuild = os.path.join(self.base_dir, 'deploy/clash-sub/primary/rebuild-clash-subscription.sh')

    def test_file_names_match(self):
        # 1. 验证 Secondary 推送脚本使用规范指令 upload-secondary
        self.assertTrue(os.path.isfile(self.secondary_push))
        with open(self.secondary_push, 'r', encoding='utf-8') as f:
            content = f.read()
        self.assertIn('upload-secondary', content)

        # 2. Primary wrapper 使用规范文件名，并暂时兼容 legacy upload-nl
        self.assertTrue(os.path.isfile(self.primary_wrapper))
        with open(self.primary_wrapper, 'r', encoding='utf-8') as f:
            content = f.read()
        self.assertIn('upload-secondary', content)
        self.assertIn('upload-nl', content)
        self.assertIn('secondary-full.yaml.ready', content)

    def test_secondary_push_key_paths_match_runtime(self):
        install_secondary = os.path.join(self.base_dir, 'deploy/lib/install-secondary.sh')
        deployment_doc = os.path.join(self.base_dir, 'docs/DEPLOYMENT.md')
        for path in (self.secondary_push, install_secondary, deployment_doc):
            with open(path, 'r', encoding='utf-8') as f:
                content = f.read()
            self.assertIn('/opt/clash-sub-mirror/subpush_key', content)
            self.assertNotIn('/home/subpush/.ssh/subpush_key', content)

        with open(install_secondary, 'r', encoding='utf-8') as f:
            install_content = f.read()
        self.assertIn('PRIMARY_IP=${PRIMARY_SERVER_IP}', install_content)

        # 3. 验证Primary rebuild 脚本包含 .ready 消费逻辑
        self.assertTrue(os.path.isfile(self.primary_rebuild))
        with open(self.primary_rebuild, 'r', encoding='utf-8') as f:
            content = f.read()
        self.assertIn('secondary-full.yaml.ready', content)

if __name__ == '__main__':
    unittest.main()
