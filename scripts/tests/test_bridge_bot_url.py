import unittest
import sys
import os

sys.path.append(os.path.abspath(os.path.join(os.path.dirname(__file__), '../../apps/tg_bot')))
import url_config

class TestBridgeBotURL(unittest.TestCase):
    def test_only_base_url_valid(self):
        res = url_config.get_webhook_url('https://bot.example.com', '', '8083')
        self.assertEqual(res, 'https://bot.example.com')

    def test_base_url_missing_scheme(self):
        res = url_config.get_webhook_url('bot.example.com', '', '8083')
        self.assertEqual(res, 'https://bot.example.com')

    def test_base_url_with_port_and_trailing_slash(self):
        res = url_config.get_webhook_url('http://bot.example.com:8083/', '', '8083')
        self.assertEqual(res, 'http://bot.example.com:8083')

    def test_legacy_ip_only(self):
        res = url_config.get_webhook_url('', '192.168.1.1', '8083')
        self.assertEqual(res, 'https://192.168.1.1:8083')

    def test_conflict_fail_closed(self):
        with self.assertRaises(ValueError) as context:
            url_config.get_webhook_url('https://bot.example.com', '192.168.1.1', '8083')
        self.assertIn('发现互斥配置', str(context.exception))

    def test_conflict_matches_safely(self):
        res = url_config.get_webhook_url('https://192.168.1.1:8083', '192.168.1.1', '8083')
        self.assertEqual(res, 'https://192.168.1.1:8083')

    def test_no_url_configured(self):
        with self.assertRaises(ValueError) as context:
            url_config.get_webhook_url('', '', '8083')
        self.assertIn('未配置 BRIDGE_PUBLIC_BASE_URL', str(context.exception))

    def test_custom_port(self):
        res = url_config.get_webhook_url('', '1.1.1.1', '8443')
        self.assertEqual(res, 'https://1.1.1.1:8443')

if __name__ == '__main__':
    unittest.main()
