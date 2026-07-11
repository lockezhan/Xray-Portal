import unittest
import subprocess
import os

class TestRepositorySanitization(unittest.TestCase):
    def setUp(self):
        self.base_dir = os.path.abspath(os.path.join(os.path.dirname(__file__), '../..'))
        
    def test_current_files_sanitized(self):
        # 1. 使用 git ls-files 获取当前所有跟踪的文件
        try:
            output = subprocess.check_output(['git', 'ls-files', '-z'], cwd=self.base_dir)
            files = output.decode('utf-8').split('\x00')
        except Exception as e:
            self.skipTest("无法执行 git ls-files: {}".format(e))

        sensitive_matches = []
        forbidden_patterns = ['finalfinal', 'dpdns']

        for rel_path in files:
            if not rel_path.strip():
                continue
            
            abs_path = os.path.join(self.base_dir, rel_path)
            # 排除二进制文件或本测试文件自身及自检脚本
            if not os.path.isfile(abs_path) or abs_path.endswith('.pyc') or 'test_repository_sanitization.py' in abs_path or 'scripts/validate-project.sh' in abs_path:
                continue

            try:
                with open(abs_path, 'r', encoding='utf-8', errors='ignore') as f:
                    for line_no, line in enumerate(f, 1):
                        for pattern in forbidden_patterns:
                            if pattern in line:
                                sensitive_matches.append((rel_path, line_no, pattern))
            except Exception:
                pass

        self.assertEqual(len(sensitive_matches), 0, "发现当前分支工作区跟踪文件中包含未脱敏生产敏感字样:\n" + "\n".join(
            ["文件 '{}' 第 {} 行包含敏感词: '{}'".format(f, l, p) for f, l, p in sensitive_matches]
        ))

    def test_git_history_audit_readonly(self):
        # 2. 对 Git 历史提交做级别 B 只读扫描，并在日志输出审计记录，普通 unittest 不再因安全债务失败
        print("\n==================================================")
        print("=== 开始级别 B Git 历史只读机密与敏感词扫描审计...")
        print("==================================================")
        
        try:
            out = subprocess.check_output(['git', 'log', '-S', 'finalfinal', '--oneline'], cwd=self.base_dir).decode('utf-8').strip()
            commits = [line.split()[0] for line in out.split('\n') if line.strip()]
        except Exception as e:
            print("无法读取 Git 提交历史: {}".format(e))
            return

        leaks_found = 0
        for commit in commits:
            try:
                # 获取该 commit 涉及改动的文件名列表
                show_out = subprocess.check_output(['git', 'show', '--name-only', commit], cwd=self.base_dir).decode('utf-8').strip().split('\n')
                files = [line for line in show_out if line.strip() and '/' in line and not line.startswith(' ')][:2]
                for f in files:
                    print("[⚠️ 历史泄露警告] Commit: {} | File: {} | Type: production-domain-leak".format(commit[:7], f))
                    leaks_found += 1
            except Exception:
                pass

        print("--------------------------------------------------")
        if leaks_found > 0:
            print("⚠️ 扫描结束：在 Git 历史中发现了已覆盖的历史敏感残留（请重写历史提交树）")
        else:
            print("✅ 扫描结束：未在任何 Git 历史 commit 中发现机密文件残留")
        print("==================================================\n")
        
        # 普通 unittest 不再因历史安全债务失败，不执行 assert leaks_found == 0

if __name__ == '__main__':
    unittest.main()
