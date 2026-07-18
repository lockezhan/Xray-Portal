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
        primary_env = os.path.join(DEPLOY_DIR, "env", "primary.env.example")
        secondary_env = os.path.join(DEPLOY_DIR, "env", "secondary.env.example")

        self.assertTrue(os.path.exists(primary_env), "primary.env.example 模板不存在")
        self.assertTrue(os.path.exists(secondary_env), "secondary.env.example 模板不存在")

        with open(primary_env, "r", encoding="utf-8") as f:
            us_content = f.read()
        with open(secondary_env, "r", encoding="utf-8") as f:
            nl_content = f.read()

        # Primary模板应包含面板与机器人凭据
        self.assertIn("PORTAL_PASSWORD=", us_content)
        self.assertIn("FLASK_SECRET_KEY=", us_content)

        # Secondary模板绝对不能包含 Flask 口令或 Bot Token 等Primary专属凭证
        forbidden_in_nl = ["PORTAL_PASSWORD=", "FLASK_SECRET_KEY=", "BRIDGE_BOT_TOKEN=", "CHANNEL_BOT_TOKEN="]
        for key in forbidden_in_nl:
            self.assertNotIn(key, nl_content, f"Secondary环境模板中违规包含了 {key}")

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
            os.path.join(DEPLOY_DIR, "lib", "install-primary.sh"),
            os.path.join(DEPLOY_DIR, "lib", "install-secondary.sh"),
        ]
        for script in scripts:
            self.assertTrue(os.path.exists(script), f"目标脚本未找到: {script}")
            res = subprocess.run(["bash", "-n", script], capture_output=True, text=True)
            self.assertEqual(res.returncode, 0, f"脚本语法检查失败 {script}: {res.stderr}")

    def test_dry_run_install_primary(self):
        """测试Primary角色一键部署 Dry-Run 模式运行"""
        import tempfile
        with tempfile.NamedTemporaryFile(mode="w", suffix=".env", delete=False) as f:
            f.write(
                "PRIMARY_SERVER_IP=1.1.1.1\n"
                "SECONDARY_SERVER_IP=2.2.2.2\n"
                "PRIMARY_SUB_DOMAIN=primary.example.com\n"
                "SECONDARY_SUB_DOMAIN=secondary.example.com\n"
                "SUB_TOKEN=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef\n"
                "PORTAL_PASSWORD=secret_pass\n"
                "FLASK_SECRET_KEY=secret_flask\n"
            )
            tmp_env = f.name
        try:
            os.chmod(tmp_env, 0o600)
            cmd = [
                os.path.join(DEPLOY_DIR, "install.sh"),
                "primary",
                "--env",
                tmp_env,
                "--dry-run"
            ]
            env = os.environ.copy()
            for key in ["PRIMARY_SERVER_IP", "SECONDARY_SERVER_IP", "PRIMARY_SUB_DOMAIN", "SECONDARY_SUB_DOMAIN", "PRIMARY_PUBLISH_DIR", "SECONDARY_MIRROR_DIR", "US_SERVER_IP", "NL_SERVER_IP", "US_SUB_DOMAIN", "NL_SUB_DOMAIN"]:
                env.pop(key, None)
            res = subprocess.run(cmd, capture_output=True, text=True, env=env)
            self.assertEqual(res.returncode, 0, f"Primary dry-run 执行异常:\nSTDOUT:{res.stdout}\nSTDERR:{res.stderr}")
            self.assertIn("Primary 主服务器", res.stdout)
        finally:
            if os.path.exists(tmp_env):
                os.unlink(tmp_env)

    def test_dry_run_install_secondary(self):
        """测试Secondary角色一键部署 Dry-Run 模式运行与安全隔离过滤"""
        import tempfile
        with tempfile.NamedTemporaryFile(mode="w", suffix=".env", delete=False) as f:
            f.write(
                "SECONDARY_SERVER_IP=2.2.2.2\n"
                "PRIMARY_SERVER_IP=1.1.1.1\n"
                "SECONDARY_SUB_DOMAIN=secondary.example.com\n"
                "SUB_TOKEN=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef\n"
                "PORTAL_PASSWORD=should_be_stripped\n"
            )
            tmp_env = f.name
        try:
            os.chmod(tmp_env, 0o600)
            cmd = [
                os.path.join(DEPLOY_DIR, "install.sh"),
                "secondary",
                "--env",
                tmp_env,
                "--dry-run"
            ]
            env = os.environ.copy()
            for key in ["PRIMARY_SERVER_IP", "SECONDARY_SERVER_IP", "PRIMARY_SUB_DOMAIN", "SECONDARY_SUB_DOMAIN", "PRIMARY_PUBLISH_DIR", "SECONDARY_MIRROR_DIR", "US_SERVER_IP", "NL_SERVER_IP", "US_SUB_DOMAIN", "NL_SUB_DOMAIN"]:
                env.pop(key, None)
            res = subprocess.run(cmd, capture_output=True, text=True, env=env)
            self.assertEqual(res.returncode, 0, f"Secondary dry-run 执行异常:\nSTDOUT:{res.stdout}\nSTDERR:{res.stderr}")
            self.assertIn("Secondary副服务器", res.stdout)
            self.assertIn("检测到 Secondary 环境变量中包含 Primary 专有凭据", res.stderr)
        finally:
            if os.path.exists(tmp_env):
                os.unlink(tmp_env)


if __name__ == "__main__":
    unittest.main()
