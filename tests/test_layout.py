"""验证分类后的脚本调用路径，防止移动文件后构建入口失效。"""
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

class LayoutTests(unittest.TestCase):
    def test_workflow_patch_paths_exist(self):
        text = (ROOT / '.github/workflows/main.yml').read_text(encoding='utf-8')
        names = re.findall(r'\$PATCH_DIR/([\w.-]+)', text)
        self.assertGreater(len(names), 8)
        for name in names:
            self.assertTrue((ROOT / 'patch' / name).is_file(), name)
        self.assertLess(text.index('tools/install toolchain/install'), text.index('$PATCH_DIR/60-bbr3.sh'))
        self.assertLess(text.index('$PATCH_DIR/70-verify.py'), text.index('uses: actions/upload-artifact'))

    def test_specialist_helpers_exist(self):
        text = (ROOT / 'patch/21-daed.py').read_text(encoding='utf-8')
        self.assertIn('patch/daed-lock.py', text)
        text = (ROOT / 'patch/70-verify.py').read_text(encoding='utf-8')
        self.assertIn('patch/openwrt-bbr3.py', text)
