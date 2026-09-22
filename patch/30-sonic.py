#!/usr/bin/env python3
"""SONiC 专属补丁：内核、nftables、firewall4、LuCI 和中文翻译。"""
import json
import difflib
import re
import shutil
import subprocess
import sys
from pathlib import Path
from common import PROJECT, write, require, symbols, kernel_version

def normalize_patch(text):
    """重新计算上游手写补丁的行数，并修正空白上下文。"""
    lines = text.splitlines(True)
    result = []
    i = 0
    while i < len(lines):
        match = re.match(r"@@ -(\d+)(?:,\d+)? \+(\d+)(?:,\d+)? @@(.*)", lines[i])
        if not match:
            result.append(lines[i])
            i += 1
            continue
        i += 1
        body = []
        while i < len(lines) and not lines[i].startswith(('@@ ', '--- a/', 'diff --git ', '-- \n')):
            line = lines[i]
            if line == '\n':
                line = ' \n'
            require(line.startswith((' ', '+', '-', '\\')), 'Unexpected patch hunk content')
            body.append(line)
            i += 1
        old = sum(line[0] in ' -' for line in body)
        new = sum(line[0] in ' +' for line in body)
        result.append(f'@@ -{match[1]},{old} +{match[2]},{new} @@{match[3]}\n')
        result.extend(body)
    return ''.join(result)

def sonic():
    src = Path(".sources/sonic")
    version = kernel_version()
    # 上游共用补丁仅覆盖这些已检查过的内核接口。
    # 未知内核系列明确失败，避免套用无关补丁。
    require(version in {"6.6", "6.12", "6.18"}, f"SONiC upstream has not validated kernel {version}")
    kernel = Path(f"target/linux/generic/hack-{version}")
    require(kernel.is_dir(), f"Missing kernel patch directory: {kernel}")
    mapping = {"kernel": kernel,
               "patches/libnftnl": Path("package/libs/libnftnl/patches"),
               "patches/nftables": Path("package/network/utils/nftables/patches"),
               "firewall/firewall4": Path("package/network/config/firewall4/patches"),
               "patches/luci-app-firewall": Path("feeds/luci/applications/luci-app-firewall/patches")}
    for origin, dest in mapping.items():
        require(dest.parent.is_dir(), f"Required SONiC component absent: {dest.parent}")
        patches = list((src / origin).glob("*.patch"))
        require(patches, f"Missing upstream SONiC patches: {origin}")
        dest.mkdir(exist_ok=True)
        for patch in patches:
            content = patch.read_text()
            if patch.name == "984-add-sonic-fullcone-support.patch":
                # 6.18 稳定版在 synchronize_net() 后增加清理调用，
                # 因此把此处补丁的上下文锚点调整到 kvfree。
                content = content.replace(" \t\tsynchronize_net();\n", "")
                content = content.replace("\n\n \tsynchronize_net();\n \tkvfree(nf_nat_bysource);",
                                          "\n \tkvfree(nf_nat_bysource);")
            write(dest / patch.name, normalize_patch(content))
    # LuCI 主线已调整翻译上下文及 masq_allow_invalid 所在行。
    # 将上游三组纯新增内容重定位到唯一的当前源码锚点。
    luci_patch = src / "patches/luci-app-firewall/001-add-fullcone-options.patch"
    hunks = re.split(r"^@@.*@@.*$", luci_patch.read_text(), flags=re.M)[1:]
    require(len(hunks) == 3, "SONiC LuCI patch layout changed; review required")
    blocks = []
    for hunk in hunks:
        require(not any(line.startswith('-') for line in hunk.splitlines()),
                "SONiC LuCI patch now removes code; review required")
        blocks.append("\n".join(line[1:] for line in hunk.splitlines() if line.startswith('+')) + "\n")
    relative = "htdocs/luci-static/resources/view/firewall/zones.js"
    zone_file = Path("feeds/luci/applications/luci-app-firewall") / relative
    original = zone_file.read_text()
    changed = original
    for token, block, after in zip(("'drop_invalid'", "'mtu_fix'", "'masq_allow_invalid'"), blocks, (True, False, False)):
        lines = [line for line in changed.splitlines(True) if token in line and 's.' in line]
        require(len(lines) == 1, f"Cannot locate unique LuCI anchor {token}")
        line = lines[0]
        changed = changed.replace(line, line + "\n" + block if after else block + "\n" + line, 1)
    patch = "".join(difflib.unified_diff(original.splitlines(True), changed.splitlines(True),
                                       fromfile="a/" + relative, tofile="b/" + relative))
    write(mapping["patches/luci-app-firewall"] / luci_patch.name, patch)
    nftnl = Path("package/libs/libnftnl/Makefile")
    text = nftnl.read_text()
    if not re.search(r"^PKG_FIXUP\s*[:+?]?=.*autoreconf", text, re.M):
        text = text.replace("include $(INCLUDE_DIR)/package.mk", "PKG_FIXUP+=autoreconf\n\ninclude $(INCLUDE_DIR)/package.mk")
        write(nftnl, text)
    po = Path("feeds/luci/applications/luci-app-firewall/po/zh_Hans/firewall.po")
    require(po.exists(), "Missing LuCI Chinese translation file")
    text = po.read_text()
    if 'msgid "Fullcone NAT"' not in text:
        write(po, text + "\n" + (src / "translations/zh_Hans.po").read_text())
    write("build-info/sonic.json", json.dumps({"kernel": version, "components": list(mapping)}, indent=2))

if __name__ == '__main__':
    sonic()
