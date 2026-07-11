import unittest
import os
import re

class TestDocsLinks(unittest.TestCase):
    def setUp(self):
        self.base_dir = os.path.abspath(os.path.join(os.path.dirname(__file__), '../..'))
        # 寻找所有的 Markdown 文件
        self.md_files = []
        for root, _, files in os.walk(self.base_dir):
            # 排除虚拟环境和 .git 目录
            if '.git' in root or '.test_venv' in root or '.venv' in root:
                continue
            for f in files:
                if f.endswith('.md'):
                    self.md_files.append(os.path.join(root, f))

    def test_markdown_relative_links(self):
        # 正则提取 markdown 相对链接
        # 匹配形式：[label](relative_path)，排除 http/https/mailto 以及 html 锚点标签
        link_pattern = re.compile(r'\[[^\]]+\]\(([^:\)]+)\)')

        broken_links = []
        for md_file in self.md_files:
            with open(md_file, 'r', encoding='utf-8') as f:
                content = f.read()
                
            matches = link_pattern.findall(content)
            for path in matches:
                # 过滤锚点与远程 URL
                if path.startswith('#') or path.startswith('http') or path.startswith('mailto'):
                    continue
                    
                # 提取带锚点的文件路径
                clean_path = path.split('#')[0].strip()
                if not clean_path:
                    continue
                
                # 计算绝对路径
                abs_path = os.path.abspath(os.path.join(os.path.dirname(md_file), clean_path))
                
                # 检查该文件或目录是否存在
                if not os.path.exists(abs_path):
                    broken_links.append((os.path.basename(md_file), path, abs_path))

        self.assertEqual(len(broken_links), 0, "发现失效的 Markdown 相对链接:\n" + "\n".join(
            ["文件 '{}' 中的链接 '{}' 指向的路径不存在: {}".format(f, l, p) for f, l, p in broken_links]
        ))

if __name__ == '__main__':
    unittest.main()
