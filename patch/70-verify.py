#!/usr/bin/env python3
"""产物验证：核对内核、BBRv3、镜像、软件包清单和校验和。"""
import json
import difflib
import re
import shutil
import subprocess
import sys
from pathlib import Path
from common import PROJECT, write, require, symbols, kernel_version

def kernel_check():
    kernels = list(Path("build_dir").glob("target-*/linux-*/linux-*/.config"))
    require(len(kernels) == 1, f"Expected one compiled kernel, found {kernels}")
    config = symbols(kernels[0])
    for key in ("TCP_CONG_BBR", "NET_SCH_FQ"):
        require(config.get("CONFIG_" + key) in {"y", "m"}, f"Missing kernel {key}")
    if symbols(".config").get("CONFIG_PACKAGE_luci-app-daed") == "y":
        for key in ("DEBUG_INFO_BTF", "CGROUP_BPF", "BPF_EVENTS", "XDP_SOCKETS"):
            require(config.get("CONFIG_" + key) == "y", f"DAED kernel requirement absent: {key}")
    require((kernels[0].parent / "vmlinux").is_file(), "Kernel did not compile")
    shutil.copyfile(kernels[0], "build-info/kernel.config")

def artifacts():
    root = Path("bin/targets/rockchip/armv8")
    images = [p for p in root.glob("*hinlink_h68k*") if p.name.endswith((".img.gz", ".img", ".bin", ".itb"))]
    require(images, "No H68K firmware image")
    subprocess.run([sys.executable, str(PROJECT / 'patch/openwrt-bbr3.py'),
                    '--verify-only'], check=True)
    manifests = list(root.glob("*.manifest"))
    require(manifests, "No firmware manifest")
    require((root / "sha256sums").is_file(), "No sha256sums")
    subprocess.run(["sha256sum", "-c", "sha256sums"], cwd=root, check=True)
    packages = {line.split()[0] for path in manifests for line in path.read_text().splitlines() if line.strip()}
    for key,value in symbols(PROJECT / "config/h68k.txt").items():
        if key.startswith("CONFIG_PACKAGE_luci-app-") and value == "y":
            require(key.removeprefix("CONFIG_PACKAGE_") in packages, f"Firmware missing {key}")
    dest = Path("../release-assets")
    dest.mkdir(exist_ok=True)
    for path in root.iterdir():
        if path.is_file():
            shutil.copyfile(path, dest / path.name)
    shutil.copytree("build-info", dest / "build-info", dirs_exist_ok=True)
    write(dest / "BUILD-SUCCESS.txt", "H68K images, manifests and SHA256 verified. Hardware boot testing remains required.\n")

if __name__ == '__main__':
    {'kernel-check': kernel_check, 'artifacts': artifacts}[sys.argv[1]]()
