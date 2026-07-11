import unittest
import os

class TestUploadProtocol(unittest.TestCase):
    def setUp(self):
        self.base_dir = os.path.abspath(os.path.join(os.path.dirname(__file__), '../..'))
        self.nl_push = os.path.join(self.base_dir, 'deploy/clash-sub/nl/push-clash-subscription-nl.sh')
        self.us_wrapper = os.path.join(self.base_dir, 'deploy/clash-sub/us/subpush-cmd-wrapper')
        self.us_rebuild = os.path.join(self.base_dir, 'deploy/clash-sub/us/rebuild-clash-subscription.sh')

    def test_file_names_match(self):
        # 1. 验证荷兰推送脚本包含自定义指令 upload-nl
        self.assertTrue(os.path.isfile(self.nl_push))
        with open(self.nl_push, 'r', encoding='utf-8') as f:
            content = f.read()
        self.assertIn('upload-nl', content, "push-clash-subscription-nl.sh must invoke 'upload-nl'")

        # 2. 验证美国 wrapper 脚本包含 upload-nl 逻辑并写入 .ready
        self.assertTrue(os.path.isfile(self.us_wrapper))
        with open(self.us_wrapper, 'r', encoding='utf-8') as f:
            content = f.read()
        self.assertIn('upload-nl', content, "subpush-cmd-wrapper must support 'upload-nl'")
        self.assertIn('nl-full.yaml.ready', content, "subpush-cmd-wrapper must output 'nl-full.yaml.ready'")

        # 3. 验证美国 rebuild 脚本包含 .ready 消费逻辑
        self.assertTrue(os.path.isfile(self.us_rebuild))
        with open(self.us_rebuild, 'r', encoding='utf-8') as f:
            content = f.read()
        self.assertIn('nl-full.yaml.ready', content, "rebuild-clash-subscription.sh must consume 'nl-full.yaml.ready'")

if __name__ == '__main__':
    unittest.main()
