#!/usr/bin/env python3
"""Build preparation and assertions; run from the OpenWrt source root."""
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


def normalize_patch(text):
    """Recount upstream hand-written hunks, including empty context lines."""
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


def kernel_version():
    match = re.search(r"^KERNEL_PATCHVER\s*:?=\s*(\d+\.\d+)",
                      Path("target/linux/rockchip/Makefile").read_text(), re.M)
    require(match, "Cannot detect Rockchip KERNEL_PATCHVER")
    return match[1]


def target():
    images = "\n".join(p.read_text() for p in Path("target/linux/rockchip/image").glob("*.mk"))
    for token in ("define Device/hinlink_h68k", "rk3568-hinlink-h68k", "hinlink-h68k-rk3568"):
        require(token in images, f"Official H68K definition missing: {token}")
    write("build-info/kernel-series.txt", kernel_version() + "\n")


def customize():
    # Fix the actual failing host configure option, retaining Ninja's bootstrap.
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
    daed = Path(".sources/daed/daed/Makefile")
    if daed.exists():
        text = daed.read_text()
        # Upstream shell groups otherwise hide failed pnpm/go commands.
        text = text.replace("\t( \\\n", "\t( set -eu; \\\n")
        # No experimental Go compiler flags required by dae; official feed Go works.
        text = re.sub(r"GOEXPERIMENT=[^\n]+", "GOEXPERIMENT=", text)
        # The pinned daed f045ecd declares pnpm@10.24.0 in package.json.
        text = text.replace("npm install -g pnpm ;", "npm install -g pnpm@10.24.0 ;")
        text = text.replace("pnpm install ;", "pnpm install --frozen-lockfile ;")
        # Apply the documented lock repair only to the inspected source commit.
        if "PKG_SOURCE_VERSION:=f045ecdd76cecce4e887a123dd45a9c25260f773" in text:
            shutil.copyfile(PROJECT / "scripts/daed-lock.py", daed.parent / "fix-lock.py")
            before = "\t\tpnpm install --frozen-lockfile ;"
            text = text.replace(before, "\t\tpython3 $(CURDIR)/fix-lock.py . ; \\\n" + before)
        write(daed, text)


def sonic():
    src = Path(".sources/sonic")
    version = kernel_version()
    # Upstream currently supplies a shared patch for these reviewed interfaces.
    # Fail for a new series rather than silently applying an unrelated version.
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
                # 6.18 stable inserts nf_ct_helper_expectfn_destroy() after
                # synchronize_net(). Anchor these additions at kvfree instead.
                content = content.replace(" \t\tsynchronize_net();\n", "")
                content = content.replace("\n\n \tsynchronize_net();\n \tkvfree(nf_nat_bysource);",
                                          "\n \tkvfree(nf_nat_bysource);")
            write(dest / patch.name, normalize_patch(content))
    # LuCI main changed translation context and the masq_allow_invalid line.
    # Rebase upstream's three addition-only blocks onto unique current anchors.
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


def symbols(path):
    result = {}
    for line in Path(path).read_text().splitlines():
        if line.startswith("CONFIG_") and "=" in line:
            key, value = line.split("=", 1)
            result[key] = value
    return result


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


def translations():
    config = Path(".config").read_text()
    metadata = Path("tmp/.packageinfo").read_text()
    available = set(re.findall(r"^Package: (.+)$", metadata, re.M))
    for app in re.findall(r"^CONFIG_PACKAGE_luci-app-(.+)=y$", config, re.M):
        pkg = f"luci-i18n-{app}-zh-cn"
        if pkg in available and f"CONFIG_PACKAGE_{pkg}=y" not in config:
            config += f"\nCONFIG_PACKAGE_{pkg}=y\n"
    write(".config", config)


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


if __name__ == "__main__":
    {"target": target, "customize": customize, "sonic": sonic,
     "config-check": config_check, "translations": translations,
     "kernel-check": kernel_check, "artifacts": artifacts}[sys.argv[1]]()
