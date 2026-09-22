#!/usr/bin/env python3
"""目标与配置检查：识别 H68K、补齐中文包、检查选项是否丢失。"""
import json
import difflib
import re
import shutil
import subprocess
import sys
from pathlib import Path
from common import PROJECT, write, require, symbols, kernel_version

def target():
    images = "\n".join(p.read_text() for p in Path("target/linux/rockchip/image").glob("*.mk"))
    for token in ("define Device/hinlink_h68k", "rk3568-hinlink-h68k", "hinlink-h68k-rk3568"):
        require(token in images, f"Official H68K definition missing: {token}")
    write("build-info/kernel-series.txt", kernel_version() + "\n")

def translations():
    config = Path(".config").read_text()
    metadata = Path("tmp/.packageinfo").read_text()
    available = set(re.findall(r"^Package: (.+)$", metadata, re.M))
    for app in re.findall(r"^CONFIG_PACKAGE_luci-app-(.+)=y$", config, re.M):
        pkg = f"luci-i18n-{app}-zh-cn"
        if pkg in available and f"CONFIG_PACKAGE_{pkg}=y" not in config:
            config += f"\nCONFIG_PACKAGE_{pkg}=y\n"
    write(".config", config)

def config_check():
    actual = symbols(".config")
    requested = symbols(PROJECT / "config/h68k.txt")
    missing = [f"{k}={v}" for k, v in requested.items() if v != "n" and actual.get(k) != v]
    require(not missing, "Requested options disappeared after defconfig:\n" + "\n".join(missing))
    require(actual.get("CONFIG_KERNEL_DEBUG_INFO_REDUCED") != "y", "BTF requires full debug information")
    require(not any(actual.get("CONFIG_PACKAGE_" + p) == "y" for p in
                    ("luci-app-turboacc", "kmod-nft-fullcone", "kmod-ipt-fullconenat")), "Conflicting Full Cone implementation")
    chosen = [k for k,v in actual.items() if k.startswith("CONFIG_TARGET_DEVICE_") and v == "y"]
    require(chosen == ["CONFIG_TARGET_DEVICE_rockchip_armv8_DEVICE_hinlink_h68k"], f"Unexpected profiles: {chosen}")
    shutil.copyfile(".config", "build-info/final.config")

if __name__ == '__main__':
    {'target': target, 'translations': translations, 'config-check': config_check}[sys.argv[1]]()
