#!/usr/bin/env python3
"""Build-time BBRv3 adapter for a configured, toolchain-ready OpenWrt tree."""
import argparse
import json
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

import bbr

REPORT = Path('build-info/bbr.json')


def save(data):
    REPORT.parent.mkdir(exist_ok=True)
    REPORT.write_text(json.dumps(data, indent=2) + '\n')


def make(target, jobs=1, log=None):
    args = ['make', target, f'-j{jobs}', 'V=s']
    if log is None:
        subprocess.run(args, check=True)
    else:
        print(f"Running {' '.join(args)}; log: {log}", flush=True)
        with open(log, 'w') as stream:
            subprocess.run(args, stdout=stream, stderr=subprocess.STDOUT, check=True)


def kernel_tree():
    paths = list(Path('build_dir').glob('target-*/linux-*/linux-*/net/ipv4/tcp_bbr.c'))
    if len(paths) != 1:
        raise RuntimeError(f'Expected one prepared target kernel, found {paths}')
    return paths[0].parents[2]


def kernel_series(kernel):
    text = (kernel / 'Makefile').read_text()
    def value(key):
        match = re.search(r'^' + key + r'\s*=\s*(\d+)\s*$', text, re.M)
        if not match:
            raise RuntimeError(f'Cannot detect actual kernel {key}')
        return match[1]
    return value('VERSION') + '.' + value('PATCHLEVEL')


def remove_managed_patch(target):
    paths = list(Path(f'target/linux/{target}').glob('patches-*/999-google-bbrv3.patch'))
    if not paths:
        return
    if len(paths) != 1 or not REPORT.exists():
        raise RuntimeError('Existing BBR patch has no unambiguous ownership record; use a fresh checkout')
    record = json.loads(REPORT.read_text())
    patch = paths[0]
    if (record.get('patch') != str(patch) or
            record.get('patch_sha256') != bbr.digest(patch.read_bytes()) or
            not patch.read_text().startswith(bbr.MARKER)):
        raise RuntimeError('Existing BBR patch is unmanaged or modified; refusing to overwrite')
    patch.unlink()
    make('target/linux/clean')


def verify(kernel, record):
    for path, expected in record['source_sha256'].items():
        if bbr.digest((kernel / path).read_bytes()) != expected:
            raise RuntimeError(f'Prepared source differs from validated patch: {path}')
    config = (kernel / '.config').read_text()
    if not re.search(r'^CONFIG_TCP_CONG_BBR=m$', config, re.M):
        raise RuntimeError('Expected packaged BBR module (CONFIG_TCP_CONG_BBR=m)')
    if not re.search(r'^CONFIG_NET_SCH_FQ=[ym]$', config, re.M):
        raise RuntimeError('FQ is absent from compiled kernel configuration')
    module = kernel / 'net/ipv4/tcp_bbr.ko'
    data = module.read_bytes()
    if not data.startswith(b'\x7fELF') or b'version=3\0' not in data:
        raise RuntimeError('Built tcp_bbr.ko does not identify itself as BBRv3')
    if not (kernel / 'vmlinux').is_file():
        raise RuntimeError('Linked kernel missing')
    record.update(status='compiled', validation='Full Kbuild, source hashes and module version passed',
                  module_sha256=bbr.digest(data), runtime_verified=False)
    save(record)
    shutil.copyfile(kernel / '.config', 'build-info/bbr-kernel.config')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--openwrt', default='.', help='Configured OpenWrt source root')
    parser.add_argument('--pinned-only', action='store_true', help='Disable upstream adapter discovery')
    parser.add_argument('--verify-only', action='store_true', help='Recheck final compiled source and module')
    parser.add_argument('--jobs', type=int, default=os.cpu_count() or 1)
    args = parser.parse_args()
    if args.jobs < 1:
        parser.error('--jobs must be positive')
    runtime_check = Path(__file__).with_name('bbr3-check.sh').resolve()
    os.chdir(Path(args.openwrt).resolve())
    if not Path('include/toplevel.mk').is_file():
        raise RuntimeError('Not an OpenWrt source root')
    if args.verify_only:
        record = json.loads(REPORT.read_text())
        verify(kernel_tree(), record)
        return
    config = Path('.config').read_text()
    match = re.search(r'^CONFIG_TARGET_BOARD="([a-zA-Z0-9_-]+)"$', config, re.M)
    if not match:
        raise RuntimeError('Run make defconfig before BBR adaptation')
    target = match[1]
    for package in ('kmod-tcp-bbr', 'kmod-sched'):
        if f'CONFIG_PACKAGE_{package}=y' not in config.splitlines():
            raise RuntimeError(f'Enable CONFIG_PACKAGE_{package}=y and rebuild defconfig first')
    # Never erase a foreign or edited patch, even on a repeated invocation.
    remove_managed_patch(target)
    save({'status': 'discovering', 'runtime_verified': False})
    attempts = []
    refs = bbr.candidates(refresh=not args.pinned_only)
    for index, ref in enumerate(refs, 1):
        log = f'build-info/bbr-attempt-{index}.log'
        print(f'BBRv3 candidate {index}/{len(refs)}: {ref}', flush=True)
        try:
            make('target/linux/prepare')
            kernel = kernel_tree()
            bbr.main(kernel, kernel_series(kernel), target, (ref,))
            record = json.loads(REPORT.read_text())
            make('target/linux/clean')
            make('target/linux/prepare')
            kernel = kernel_tree()
            make('target/linux/compile', args.jobs, log)
            verify(kernel, record)
            record['attempts'] = attempts + [{'adapter': ref, 'result': 'compiled', 'log': log}]
            save(record)
            destination = Path('files/usr/sbin/bbr3-check')
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(runtime_check, destination)
            destination.chmod(0o755)
            manifest = Path('files/etc/bbr3-build.json')
            manifest.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(REPORT, manifest)
            sysctl = Path('files/etc/sysctl.d/99-bbr3.conf')
            sysctl.parent.mkdir(parents=True, exist_ok=True)
            sysctl.write_text('net.core.default_qdisc=fq\nnet.ipv4.tcp_congestion_control=bbr\n')
            print('BBRv3 Kbuild passed. Run bbr3-check on the flashed device; runtime remains unverified.')
            return
        except (Exception, SystemExit) as error:
            attempts.append({'adapter': ref, 'result': 'failed', 'error': str(error), 'log': log})
            print(f'Candidate rejected: {error}', file=sys.stderr, flush=True)
            remove_managed_patch(target)
            save({'status': 'retrying', 'attempts': attempts, 'runtime_verified': False})
    save({'status': 'failed', 'attempts': attempts, 'runtime_verified': False})
    raise RuntimeError('No candidate passed full validation. See build-info/bbr.json and attempt logs; no BBRv1 fallback.')


if __name__ == '__main__':
    try:
        main()
    except Exception as error:
        print(f'BBRv3 adaptation failed: {error}', file=sys.stderr)
        sys.exit(1)
