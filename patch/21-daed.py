#!/usr/bin/env python3
"""DAED 专属补丁：Go 参数、pnpm 版本和固定源码锁文件修复。"""
import re
import shutil
from pathlib import Path
from common import PROJECT, write

def patch_daed():
    daed = Path(".sources/daed/daed/Makefile")
    if daed.exists():
        text = daed.read_text()
        # 为子 Shell 开启错误退出，避免 pnpm 或 Go 失败后继续。
        text = text.replace("\t( \\\n", "\t( set -eu; \\\n")
        # 移除非必要的实验性 Go 参数，使用官方 feed 的 Go 工具链。
        text = re.sub(r"GOEXPERIMENT=[^\n]+", "GOEXPERIMENT=", text)
        # 固定源码 f045ecd 的 package.json 指定 pnpm 10.24.0。
        text = text.replace("npm install -g pnpm ;", "npm install -g pnpm@10.24.0 ;")
        text = text.replace("pnpm install ;", "pnpm install --frozen-lockfile ;")
        # 仅为已核对的固定源码提交应用锁文件修复。
        if "PKG_SOURCE_VERSION:=f045ecdd76cecce4e887a123dd45a9c25260f773" in text:
            shutil.copyfile(PROJECT / "patch/daed-lock.py", daed.parent / "fix-lock.py")
            before = "\t\tpnpm install --frozen-lockfile ;"
            text = text.replace(before, "\t\tpython3 $(CURDIR)/fix-lock.py . ; \\\n" + before)
        write(daed, text)

if __name__ == "__main__":
    patch_daed()
