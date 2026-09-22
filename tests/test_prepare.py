import importlib.util
import json
import os
import tempfile
import unittest
from pathlib import Path
# 从分类后的补丁模块导入被测函数，避免依赖旧脚本路径。
import types
from load_patch import load
common = load('common')
packages = load('20-packages')
sonic = load('30-sonic')
config = load('50-config')
verify = load('70-verify')
prepare = types.SimpleNamespace(write=common.write, customize=packages.customize,
    sonic=sonic.sonic, normalize_patch=sonic.normalize_patch,
    config_check=config.config_check, artifacts=verify.artifacts)


class PreparationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.before = Path.cwd()
        os.chdir(self.temp.name)

    def tearDown(self):
        os.chdir(self.before)
        self.temp.cleanup()

    def test_ninja_fix_is_idempotent_and_version_scoped(self):
        path = Path('tools/ninja/Makefile')
        original = 'PKG_VERSION:=1.13.2\n\t\t\t--no-rebuild \\\n\t\t\t--verbose\n'
        prepare.write(path, original)
        prepare.customize()
        first = path.read_text()
        self.assertNotIn('--no-rebuild', first)
        prepare.customize()
        self.assertEqual(first, path.read_text())
        prepare.write(path, original.replace('1.13.2', '2.0'))
        prepare.customize()
        self.assertIn('--no-rebuild', path.read_text())

    def test_missing_requested_config_is_not_silently_accepted(self):
        prepare.write('.config', 'CONFIG_TARGET_rockchip=y\n')
        with self.assertRaises(SystemExit) as exc:
            prepare.config_check()
        self.assertIn('disappeared', str(exc.exception))

    def test_empty_output_directory_is_not_a_firmware(self):
        Path('bin/targets/rockchip/armv8').mkdir(parents=True)
        with self.assertRaises(SystemExit) as exc:
            prepare.artifacts()
        self.assertIn('No H68K', str(exc.exception))

    def test_future_sonic_kernel_is_rejected(self):
        prepare.write('target/linux/rockchip/Makefile', 'KERNEL_PATCHVER:=99.1\n')
        with self.assertRaises(SystemExit) as exc:
            prepare.sonic()
        self.assertIn('not validated', str(exc.exception))

    def test_patch_recount_preserves_file_boundaries(self):
        patch = ('--- a/one\n+++ b/one\n@@ -1,90 +1,90 @@\n\n+a\n'
                 '--- a/two\n+++ b/two\n@@ -1,90 +1,90 @@\n old\n+new\n')
        fixed = prepare.normalize_patch(patch)
        self.assertIn('@@ -1,1 +1,2 @@\n \n+a', fixed)
        self.assertIn('--- a/two\n+++ b/two\n@@ -1,1 +1,2 @@', fixed)


if __name__ == '__main__':
    unittest.main()
