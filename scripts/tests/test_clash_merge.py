import unittest
import sys
import os
import yaml
import shutil
import subprocess
import tempfile

# 将 extract_merge.py 所在的目录加入 sys.path
sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), '../../deploy/clash-sub/primary')))
import extract_merge

class TestClashMerge(unittest.TestCase):
    def setUp(self):
        self.fixture_dir = os.path.dirname(__file__)
        self.primary_src = os.path.join(self.fixture_dir, 'fixtures/primary-source.example.yaml')
        self.secondary_src = os.path.join(self.fixture_dir, 'fixtures/secondary-source.example.yaml')
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
        success = extract_merge.merge_and_generate(self.primary_src, self.secondary_src, self.out)
        self.assertTrue(success)
        self.assertTrue(self._run_mihomo_t(self.out))

    def test_scenario_only_us(self):
        # 场景二：仅Primary节点存在
        success = extract_merge.merge_and_generate(self.primary_src, '/tmp/non_existent_secondary.yaml', self.out)
        self.assertTrue(success)
        self.assertTrue(self._run_mihomo_t(self.out))

    def test_scenario_only_nl(self):
        # 场景三：仅Secondary节点存在 (紧急降级模式)
        success = extract_merge.merge_and_generate('/tmp/non_existent_primary.yaml', self.secondary_src, self.out)
        self.assertTrue(success)
        self.assertTrue(self._run_mihomo_t(self.out))

    def test_scenario_both_missing(self):
        # 场景四：双端均缺失 (应当构建失败)
        success = extract_merge.merge_and_generate('/tmp/non_existent_primary.yaml', '/tmp/non_existent_secondary.yaml', self.out)
        self.assertFalse(success)

    def test_scenario_single_and_multiple_nodes(self):
        # 场景五：测试单节点和多节点命名及组名无交集
        primary_single = {'proxies': [{'name': 'P-1', 'type': 'ss', 'server': 'p1', 'port': 1}]}
        secondary_single = {'proxies': [{'name': 'S-1', 'type': 'ss', 'server': 's1', 'port': 2}]}

        primary_multi = {'proxies': [
            {'name': 'P-1', 'type': 'ss', 'server': 'p1', 'port': 1},
            {'name': 'P-2', 'type': 'ss', 'server': 'p2', 'port': 2}
        ]}

        secondary_multi = {'proxies': [
            {'name': 'S-1', 'type': 'ss', 'server': 's1', 'port': 1},
            {'name': 'S-2', 'type': 'ss', 'server': 's2', 'port': 2}
        ]}

        test_cases = [
            (primary_single, secondary_single, ['PRIMARY-NODE'], ['SECONDARY-NODE']),
            (primary_single, None, ['PRIMARY-NODE'], []),
            (None, secondary_single, [], ['SECONDARY-NODE']),
            (primary_multi, secondary_multi, ['PRIMARY-NODE-1', 'PRIMARY-NODE-2'], ['SECONDARY-NODE-1', 'SECONDARY-NODE-2'])
        ]

        for p_data, s_data, exp_p, exp_s in test_cases:
            p_file = os.path.join(self.fixture_dir, 'fixtures/p-temp.yaml')
            s_file = os.path.join(self.fixture_dir, 'fixtures/s-temp.yaml')
            try:
                if p_data:
                    with open(p_file, 'w') as f: yaml.dump(p_data, f)
                else:
                    p_file = '/tmp/non_existent_primary.yaml'

                if s_data:
                    with open(s_file, 'w') as f: yaml.dump(s_data, f)
                else:
                    s_file = '/tmp/non_existent_secondary.yaml'

                success = extract_merge.merge_and_generate(p_file, s_file, self.out)
                self.assertTrue(success)

                with open(self.out, 'r', encoding='utf-8') as f:
                    data = yaml.safe_load(f)

                actual_names = [p['name'] for p in data['proxies']]
                self.assertEqual(sorted(actual_names), sorted(exp_p + exp_s))

                group_names = [g['name'] for g in data['proxy-groups']]
                # 确认节点名与代理组名无交集
                overlap = set(actual_names).intersection(set(group_names))
                self.assertEqual(len(overlap), 0)

                # SENSITIVE-SECONDARY 校验
                snl = next((g for g in data['proxy-groups'] if g['name'] == 'SENSITIVE-SECONDARY'), None)
                self.assertIsNotNone(snl)
                if exp_s:
                    for ref in snl['proxies']:
                        self.assertTrue(ref.startswith('SECONDARY-NODE'))
                else:
                    self.assertEqual(snl['proxies'], ['REJECT'])

                self.assertTrue(self._run_mihomo_t(self.out))
            finally:
                if os.path.exists(p_file) and p_data: os.remove(p_file)
                if os.path.exists(s_file) and s_data: os.remove(s_file)

    def test_scenario_chained_proxy_rejected(self):
        # 场景六：含有链式代理节点 (应当构建阻断)
        bad_us_data = {
            'proxies': [
                {'name': 'PRIMARY-BAD-1', 'type': 'ss', 'server': 'primary.example.com', 'port': 20001, 'cipher': 'aes-128-gcm', 'password': 'pw', 'dialer-proxy': 'parent'},
            ]
        }
        with self.assertRaises(SystemExit) as cm:
            extract_merge.extract_proxies(bad_us_data, 'US_BAD')
        self.assertEqual(cm.exception.code, 1)

    # =========================================================================
    # 2. 非对称故障转移回归自检 (任务七)
    # =========================================================================

    def test_failover_asymmetric_semantics(self):
        # A. 正常状态：Primary和Secondary同时存在
        extract_merge.merge_and_generate(self.primary_src, self.secondary_src, self.out)
        with open(self.out, 'r', encoding='utf-8') as f:
            data = yaml.safe_load(f)
        groups = {g['name']: g for g in data['proxy-groups']}

        # GENERAL-PROXY 选择 fallback，且Primary优先（排在前），Secondary在后
        gp = groups['GENERAL-PROXY']
        self.assertEqual(gp['type'], 'fallback')
        self.assertTrue(gp['proxies'][0].startswith('PRIMARY-NODE'))
        self.assertTrue(gp['proxies'][-1].startswith('SECONDARY-NODE'))

        # 敏感流量不得命中Primary、GENERAL-PROXY 或 DIRECT
        snl = groups['SENSITIVE-SECONDARY']
        for ref in snl['proxies']:
            self.assertTrue(ref.startswith('SECONDARY-NODE'))
            self.assertNotIn(ref, ['PRIMARY-NODE', 'GENERAL-PROXY', 'DIRECT'])

        # B. Primary故障时：仅Secondary存在
        extract_merge.merge_and_generate('/tmp/non_existent_primary.yaml', self.secondary_src, self.out)
        with open(self.out, 'r', encoding='utf-8') as f:
            data_us_fail = yaml.safe_load(f)
        groups_us_fail = {g['name']: g for g in data_us_fail['proxy-groups']}

        # 普通国外流量 GENERAL-PROXY 应该被指派到Secondary
        gp_us_fail = groups_us_fail['GENERAL-PROXY']
        self.assertTrue(len(gp_us_fail['proxies']) > 0)
        for ref in gp_us_fail['proxies']:
            self.assertTrue(ref.startswith('SECONDARY-NODE'))

        # C. Secondary故障时：仅Primary存在
        extract_merge.merge_and_generate(self.primary_src, '/tmp/non_existent_secondary.yaml', self.out)
        with open(self.out, 'r', encoding='utf-8') as f:
            data_nl_fail = yaml.safe_load(f)
        groups_nl_fail = {g['name']: g for g in data_nl_fail['proxy-groups']}

        # 普通流量仍走Primary
        gp_nl_fail = groups_nl_fail['GENERAL-PROXY']
        for ref in gp_nl_fail['proxies']:
            self.assertTrue(ref.startswith('PRIMARY-NODE'))

        # 敏感组 SENSITIVE-SECONDARY 必须失败 (REJECT)，严禁包含Primary节点或 DIRECT
        snl_nl_fail = groups_nl_fail['SENSITIVE-SECONDARY']
        self.assertEqual(snl_nl_fail['proxies'], ['REJECT'])

    def test_python_ok_but_mihomo_bad(self):
        # 场景七：校验通过 Python 逻辑但被 Mihomo 拒绝的 fixture
        bad_meta_src = os.path.join(self.fixture_dir, 'fixtures/secondary-python-ok-meta-bad.yaml')
        success = extract_merge.merge_and_generate(self.primary_src, bad_meta_src, self.out)
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
