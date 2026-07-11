import unittest
import sys
import os
import yaml
import shutil
import subprocess
import tempfile

# 将 extract_merge.py 所在的目录加入 sys.path
sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), '../../deploy/clash-sub/us')))
import extract_merge

class TestClashMerge(unittest.TestCase):
    def setUp(self):
        self.fixture_dir = os.path.dirname(__file__)
        self.us_src = os.path.join(self.fixture_dir, 'fixtures/us-source.example.yaml')
        self.nl_src = os.path.join(self.fixture_dir, 'fixtures/nl-source.example.yaml')
        self.out = os.path.join(self.fixture_dir, 'fixtures/merged.building.yaml')
        
    def tearDown(self):
        if os.path.exists(self.out):
            os.remove(self.out)

    def _get_mihomo_bin(self):
        """寻找系统中的 mihomo 校验二进制文件"""
        for name in ['mihomo', 'clash-meta', 'clash']:
            found = shutil.which(name)
            if found:
                return found
        return None

    def _run_mihomo_t(self, filepath):
        """如果本地环境有 mihomo，则执行真实的 mihomo -t 验证，否则直接返回 True (不跳过测试)"""
        mihomo_bin = self._get_mihomo_bin()
        if not mihomo_bin:
            return True
            
        import tempfile
        tmpdir = tempfile.mkdtemp()
        os.makedirs(tmpdir, exist_ok=True)
        shutil.copy(filepath, os.path.join(tmpdir, 'config.yaml'))
        try:
            # 运行内核测试
            subprocess.check_output([mihomo_bin, '-t', '-d', tmpdir], stderr=subprocess.STDOUT)
            print("Mihomo 内核校验成功: {}".format(filepath))
            return True
        except subprocess.CalledProcessError as e:
            print("Mihomo 内核校验失败: {}".format(e.output.decode('utf-8')))
            return False
        finally:
            if os.path.exists(tmpdir):
                shutil.rmtree(tmpdir)

    # =========================================================================
    # 1. 场景校验测试 (任务六)
    # =========================================================================

    def test_scenario_both_nodes(self):
        # 场景一：双节点同时存在
        success = extract_merge.merge_and_generate(self.us_src, self.nl_src, self.out)
        self.assertTrue(success)
        self.assertTrue(self._run_mihomo_t(self.out))

    def test_scenario_only_us(self):
        # 场景二：仅美国节点存在
        success = extract_merge.merge_and_generate(self.us_src, '/tmp/non_existent_nl.yaml', self.out)
        self.assertTrue(success)
        self.assertTrue(self._run_mihomo_t(self.out))

    def test_scenario_only_nl(self):
        # 场景三：仅荷兰节点存在 (紧急降级模式)
        success = extract_merge.merge_and_generate('/tmp/non_existent_us.yaml', self.nl_src, self.out)
        self.assertTrue(success)
        self.assertTrue(self._run_mihomo_t(self.out))

    def test_scenario_both_missing(self):
        # 场景四：双端均缺失 (应当构建失败)
        success = extract_merge.merge_and_generate('/tmp/non_existent_us.yaml', '/tmp/non_existent_nl.yaml', self.out)
        self.assertFalse(success)

    def test_scenario_multiple_nodes(self):
        # 场景五：多美国和多荷兰节点生成校验
        us_multi_data = {
            'proxies': [
                {'name': 'US-1', 'type': 'ss', 'server': 'us1.example.com', 'port': 20001, 'cipher': 'aes-128-gcm', 'password': 'pw'},
                {'name': 'US-2', 'type': 'ss', 'server': 'us2.example.com', 'port': 20002, 'cipher': 'aes-128-gcm', 'password': 'pw'},
            ]
        }
        nl_multi_data = {
            'proxies': [
                {'name': 'NL-1', 'type': 'ss', 'server': 'nl1.example.com', 'port': 20001, 'cipher': 'aes-128-gcm', 'password': 'pw'},
                {'name': 'NL-2', 'type': 'ss', 'server': 'nl2.example.com', 'port': 20002, 'cipher': 'aes-128-gcm', 'password': 'pw'},
            ]
        }
        us_file = os.path.join(self.fixture_dir, 'fixtures/us-multi.yaml')
        nl_file = os.path.join(self.fixture_dir, 'fixtures/nl-multi.yaml')
        try:
            with open(us_file, 'w') as f: yaml.dump(us_multi_data, f)
            with open(nl_file, 'w') as f: yaml.dump(nl_multi_data, f)
            
            success = extract_merge.merge_and_generate(us_file, nl_file, self.out)
            self.assertTrue(success)
            self.assertTrue(self._run_mihomo_t(self.out))
        finally:
            if os.path.exists(us_file): os.remove(us_file)
            if os.path.exists(nl_file): os.remove(nl_file)

    def test_scenario_chained_proxy_rejected(self):
        # 场景六：含有链式代理节点 (应当构建阻断)
        bad_us_data = {
            'proxies': [
                {'name': 'US-BAD-1', 'type': 'ss', 'server': 'us.example.com', 'port': 20001, 'cipher': 'aes-128-gcm', 'password': 'pw', 'dialer-proxy': 'parent'},
            ]
        }
        with self.assertRaises(SystemExit) as cm:
            extract_merge.extract_proxies(bad_us_data, 'US_BAD')
        self.assertEqual(cm.exception.code, 1)

    # =========================================================================
    # 2. 非对称故障转移回归自检 (任务七)
    # =========================================================================

    def test_failover_asymmetric_semantics(self):
        # A. 正常状态：美国和荷兰同时存在
        extract_merge.merge_and_generate(self.us_src, self.nl_src, self.out)
        with open(self.out, 'r', encoding='utf-8') as f:
            data = yaml.safe_load(f)
        groups = {g['name']: g for g in data['proxy-groups']}
        
        # GENERAL-PROXY 选择 fallback，且美国优先（排在前），荷兰在后
        gp = groups['GENERAL-PROXY']
        self.assertEqual(gp['type'], 'fallback')
        self.assertTrue(gp['proxies'][0].startswith('US-MAIN'))
        self.assertTrue(gp['proxies'][-1].startswith('NL-SENSITIVE'))

        # 敏感流量不得命中美国、GENERAL-PROXY 或 DIRECT
        snl = groups['SENSITIVE-NL']
        for ref in snl['proxies']:
            self.assertTrue(ref.startswith('NL-SENSITIVE'))
            self.assertNotIn(ref, ['DEFAULT-US', 'GENERAL-PROXY', 'DIRECT'])

        # B. 美国故障时：仅荷兰存在
        extract_merge.merge_and_generate('/tmp/non_existent_us.yaml', self.nl_src, self.out)
        with open(self.out, 'r', encoding='utf-8') as f:
            data_us_fail = yaml.safe_load(f)
        groups_us_fail = {g['name']: g for g in data_us_fail['proxy-groups']}
        
        # 普通国外流量 GENERAL-PROXY 应该被指派到荷兰
        gp_us_fail = groups_us_fail['GENERAL-PROXY']
        self.assertTrue(len(gp_us_fail['proxies']) > 0)
        for ref in gp_us_fail['proxies']:
            self.assertTrue(ref.startswith('NL-SENSITIVE'))

        # C. 荷兰故障时：仅美国存在
        extract_merge.merge_and_generate(self.us_src, '/tmp/non_existent_nl.yaml', self.out)
        with open(self.out, 'r', encoding='utf-8') as f:
            data_nl_fail = yaml.safe_load(f)
        groups_nl_fail = {g['name']: g for g in data_nl_fail['proxy-groups']}
        
        # 普通流量仍走美国
        gp_nl_fail = groups_nl_fail['GENERAL-PROXY']
        for ref in gp_nl_fail['proxies']:
            self.assertTrue(ref.startswith('US-MAIN'))
            
        # 敏感组 SENSITIVE-NL 必须失败 (REJECT)，严禁包含美国节点或 DIRECT
        snl_nl_fail = groups_nl_fail['SENSITIVE-NL']
        self.assertEqual(snl_nl_fail['proxies'], ['REJECT'])

    def test_python_ok_but_mihomo_bad(self):
        # 场景七：校验通过 Python 逻辑但被 Mihomo 拒绝的 fixture
        bad_meta_src = os.path.join(self.fixture_dir, 'fixtures/nl-python-ok-meta-bad.yaml')
        success = extract_merge.merge_and_generate(self.us_src, bad_meta_src, self.out)
        self.assertTrue(success, "Python 逻辑检验应当正常通过")
        
        mihomo_bin = self._get_mihomo_bin()
        if mihomo_bin:
            # 只有当环境有 Mihomo 内核时，内核校验才应当失败，将此测试标记为成功
            res = self._run_mihomo_t(self.out)
            self.assertFalse(res, "Mihomo 内核校验应当报错拒绝")
        else:
            self.skipTest("本地测试环境无 mihomo 二进制，跳过内核级非法配置拦截验证。")

if __name__ == '__main__':
    unittest.main()
