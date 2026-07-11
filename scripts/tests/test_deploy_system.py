#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
基于角色与环境变量一键部署系统回归测试套件 (scripts/tests/test_deploy_system.py)
"""

import os
import subprocess
import unittest

ROOT_DIR = os.path.abspath(os.path.join(os.path.dirname(__file__), "../.."))
DEPLOY_DIR = os.path.join(ROOT_DIR, "deploy")


class TestDeploySystem(unittest.TestCase):

    def test_env_templates_exist_and_isolated(self):
        """测试角色专属 .env.example 模板存在性及敏感信息隔离性"""
        us_env = os.path.join(DEPLOY_DIR, "env", "us.env.example")
        nl_env = os.path.join(DEPLOY_DIR, "env", "nl.env.example")

        self.assertTrue(os.path.exists(us_env), "us.env.example 模板不存在")
        self.assertTrue(os.path.exists(nl_env), "nl.env.example 模板不存在")

        with open(us_env, "r", encoding="utf-8") as f:
            us_content = f.read()
        with open(nl_env, "r", encoding="utf-8") as f:
            nl_content = f.read()

        # 美国模板应包含面板与机器人凭据
        self.assertIn("PORTAL_PASSWORD=", us_content)
        self.assertIn("FLASK_SECRET_KEY=", us_content)

        # 荷兰模板绝对不能包含 Flask 口令或 Bot Token 等美国专属凭证
        forbidden_in_nl = ["PORTAL_PASSWORD=", "FLASK_SECRET_KEY=", "BRIDGE_BOT_TOKEN=", "CHANNEL_BOT_TOKEN="]
        for key in forbidden_in_nl:
            self.assertNotIn(key, nl_content, f"荷兰环境模板中违规包含了 {key}")

    def test_shell_syntax_validation(self):
        """校验所有 shell 脚本语法 (bash -n)"""
        scripts = [
            os.path.join(DEPLOY_DIR, "install.sh"),
            os.path.join(DEPLOY_DIR, "verify.sh"),
            os.path.join(DEPLOY_DIR, "install-peer-key.sh"),
            os.path.join(DEPLOY_DIR, "remote-deploy.sh"),
            os.path.join(DEPLOY_DIR, "lib", "common.sh"),
            os.path.join(DEPLOY_DIR, "lib", "env.sh"),
            os.path.join(DEPLOY_DIR, "lib", "ssh-keys.sh"),
            os.path.join(DEPLOY_DIR, "lib", "install-us.sh"),
            os.path.join(DEPLOY_DIR, "lib", "install-nl.sh"),
        ]
        for script in scripts:
            self.assertTrue(os.path.exists(script), f"目标脚本未找到: {script}")
            res = subprocess.run(["bash", "-n", script], capture_output=True, text=True)
            self.assertEqual(res.returncode, 0, f"脚本语法检查失败 {script}: {res.stderr}")

    def test_dry_run_install_us(self):
        """测试美国角色一键部署 Dry-Run 模式运行"""
        import tempfile
        with tempfile.NamedTemporaryFile(mode="w", suffix=".env", delete=False) as f:
            f.write(
                "US_SERVER_IP=1.1.1.1\n"
                "NL_SERVER_IP=2.2.2.2\n"
                "US_SUB_DOMAIN=us.example.com\n"
                "NL_SUB_DOMAIN=nl.example.com\n"
                "SUB_TOKEN=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef\n"
                "PORTAL_PASSWORD=secret_pass\n"
                "FLASK_SECRET_KEY=secret_flask\n"
            )
            tmp_env = f.name
        try:
            os.chmod(tmp_env, 0o600)
            cmd = [
                os.path.join(DEPLOY_DIR, "install.sh"),
                "us",
                "--env",
                tmp_env,
                "--dry-run"
            ]
            res = subprocess.run(cmd, capture_output=True, text=True)
            self.assertEqual(res.returncode, 0, f"US dry-run 执行异常:\nSTDOUT:{res.stdout}\nSTDERR:{res.stderr}")
            self.assertIn("美国主控端 (US Role) 环境初始化", res.stdout)
        finally:
            if os.path.exists(tmp_env):
                os.unlink(tmp_env)

    def test_dry_run_install_nl(self):
        """测试荷兰角色一键部署 Dry-Run 模式运行与安全隔离过滤"""
        import tempfile
        with tempfile.NamedTemporaryFile(mode="w", suffix=".env", delete=False) as f:
            f.write(
                "NL_SERVER_IP=2.2.2.2\n"
                "US_SERVER_IP=1.1.1.1\n"
                "NL_SUB_DOMAIN=nl.example.com\n"
                "SUB_TOKEN=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef\n"
                "PORTAL_PASSWORD=should_be_stripped\n"
            )
            tmp_env = f.name
        try:
            os.chmod(tmp_env, 0o600)
            cmd = [
                os.path.join(DEPLOY_DIR, "install.sh"),
                "nl",
                "--env",
                tmp_env,
                "--dry-run"
            ]
            res = subprocess.run(cmd, capture_output=True, text=True)
            self.assertEqual(res.returncode, 0, f"NL dry-run 执行异常:\nSTDOUT:{res.stdout}\nSTDERR:{res.stderr}")
            self.assertIn("荷兰副服务器 (NL Role) 环境初始化", res.stdout)
            self.assertIn("检测到荷兰环境变量中包含无关的 Flask/Bot 凭据", res.stderr)
        finally:
            if os.path.exists(tmp_env):
                os.unlink(tmp_env)


if __name__ == "__main__":
    unittest.main()
