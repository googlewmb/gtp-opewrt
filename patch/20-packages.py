#!/usr/bin/env python3
"""包兼容补丁：修复 Ninja、SmartDNS 和 DAED 构建规则。"""
import json
import difflib
import re
import shutil
import subprocess
import sys
from pathlib import Path
from common import PROJECT, write, require, symbols, kernel_version

def customize():
    # 修复 Ninja 已确认不支持的参数，保留 bootstrap 构建方式。
    ninja = Path("tools/ninja/Makefile")
    text = ninja.read_text()
    if "PKG_VERSION:=1.13.2" in text:
        write(ninja, text.replace("\t\t\t--no-rebuild \\\n", ""))
    for root in (Path(".sources/smartdns"),):
        if root.exists():
            for path in root.rglob("Makefile"):
                text = path.read_text()
                old = "include ../../lang/rust/rust-package.mk"
                if old in text:
                    write(path, text.replace(old, "include $(TOPDIR)/feeds/packages/lang/rust/rust-package.mk"))


if __name__ == '__main__':
    customize()
