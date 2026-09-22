import importlib.util
import json
import os
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch
from load_patch import load
bbr = load("bbr")

auto = load("openwrt-bbr3")


class BBRTests(unittest.TestCase):
    def test_modified_patch_is_never_deleted(self):
        before = Path.cwd()
        with tempfile.TemporaryDirectory() as temp:
            try:
                os.chdir(temp)
                p = Path('target/linux/rockchip/patches-6.18/999-google-bbrv3.patch')
                p.parent.mkdir(parents=True)
                p.write_text(bbr.MARKER + 'edited')
                auto.save({'patch': str(p), 'patch_sha256': bbr.digest(b'original')})
                with self.assertRaisesRegex(RuntimeError, 'unmanaged or modified'):
                    auto.remove_managed_patch('rockchip')
                self.assertTrue(p.exists())
            finally:
                os.chdir(before)

    def test_actual_kernel_series(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            (root / 'Makefile').write_text('VERSION = 7\nPATCHLEVEL = 1\nSUBLEVEL = 9\n')
            self.assertEqual(auto.kernel_series(root), '7.1')

    def test_source_drift_rejected_before_success(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            (root / 'tcp.c').write_text('changed')
            with self.assertRaisesRegex(RuntimeError, 'source differs'):
                auto.verify(root, {'source_sha256': {'tcp.c': bbr.digest(b'original')}})

    def test_v1_module_rejected(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            (root / '.config').write_text('CONFIG_TCP_CONG_BBR=m\nCONFIG_NET_SCH_FQ=m\n')
            (root / 'net/ipv4').mkdir(parents=True)
            (root / 'net/ipv4/tcp_bbr.ko').write_bytes(b'\x7fELFversion=1\0')
            with self.assertRaisesRegex(RuntimeError, 'does not identify'):
                auto.verify(root, {'source_sha256': {}})

    def test_invalid_output_target_rejected(self):
        with self.assertRaises(ValueError):
            bbr.main('.', '6.18', '../escape')

    def test_compiled_report_does_not_claim_runtime_test(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            (root / '.config').write_text('CONFIG_TCP_CONG_BBR=m\nCONFIG_NET_SCH_FQ=y\n')
            (root / 'net/ipv4').mkdir(parents=True)
            (root / 'net/ipv4/tcp_bbr.ko').write_bytes(b'\x7fELFversion=3\0')
            (root / 'vmlinux').touch()
            record = {'source_sha256': {}}
            with patch.object(auto, 'save'), patch.object(auto.shutil, 'copyfile'):
                auto.verify(root, record)
            self.assertEqual(record['status'], 'compiled')
            self.assertFalse(record['runtime_verified'])
