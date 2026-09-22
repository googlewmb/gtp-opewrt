"""公共函数：文件写入、失败检查、配置读取和内核系列识别。"""
import json
import difflib
import re
import shutil
import subprocess
import sys
from pathlib import Path

PROJECT = Path(__file__).resolve().parents[1]

def write(path, text):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8", newline="\n")

def require(condition, message):
    if not condition:
        raise SystemExit(message)

def symbols(path):
    result = {}
    for line in Path(path).read_text().splitlines():
        if line.startswith("CONFIG_") and "=" in line:
            key, value = line.split("=", 1)
            result[key] = value
    return result

def kernel_version():
    match = re.search(r"^KERNEL_PATCHVER\s*:?=\s*(\d+\.\d+)",
                      Path("target/linux/rockchip/Makefile").read_text(), re.M)
    require(match, "Cannot detect Rockchip KERNEL_PATCHVER")
    return match[1]
