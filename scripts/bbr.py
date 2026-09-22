#!/usr/bin/env python3
"""Port the pinned Google BBRv3 implementation with reviewed TCP API adapters.

Select by a complete patch dry run against the prepared kernel, not a version
guess. An unknown API is a build failure, not a silent fallback to BBRv1.
"""
import difflib
import json
import re
import subprocess
import sys
import tempfile
import urllib.request
from pathlib import Path

GOOGLE = "795544cc00f03d49cfa6802f3da32c0d0a6fb4ab"
ADAPTER_REPO = "https://github.com/sbwml/kernel-latest-centos.git"
# Both revisions contain only the BBR port when selecting the file below.
ADAPTERS = ("0aaa309d13ac8cd4d5738756278f7c2b46267dce", "47a02f240c3b99cdaa83a6ab4c297384cd207907")


def run(*args, **kwargs):
    return subprocess.run(args, check=True, **kwargs)


def main(linux_dir, series):
    kernel = Path(linux_dir).resolve()
    patch_dir = Path(f"target/linux/rockchip/patches-{series}")
    patch_dir.mkdir(exist_ok=True)
    output = patch_dir / "999-google-bbrv3.patch"
    if output.exists():
        raise SystemExit("BBRv3 already staged; use a fresh source checkout")
    repo = Path(".sources/bbr-adapters").resolve()
    if not repo.exists():
        run("git", "clone", ADAPTER_REPO, str(repo))
    request = urllib.request.Request(
        f"https://raw.githubusercontent.com/google/bbr/{GOOGLE}/net/ipv4/tcp_bbr.c",
        headers={"User-Agent": "OpenWrt-H68K-build"})
    with urllib.request.urlopen(request, timeout=120) as response:
        google = response.read().decode()
    if not re.search(r"#define\s+BBR_VERSION\s+3", google):
        raise SystemExit("Google source is not BBRv3")
    errors = []
    for ref in ADAPTERS:
        patch = subprocess.check_output(["git", "-C", str(repo), "show",
                                         f"{ref}:src/0001-backport-tcp_bbr3.patch"]).decode()
        paths = re.findall(r"^diff --git a/(\S+) b/\S+$", patch, re.M)
        if not all((kernel / path).is_file() for path in paths):
            errors.append(f"{ref}: required kernel source file missing")
            continue
        with tempfile.TemporaryDirectory(prefix="h68k-bbr-") as temp:
            temp = Path(temp)
            originals = {}
            for path in paths:
                originals[path] = (kernel / path).read_text()
                (temp / path).parent.mkdir(parents=True, exist_ok=True)
                (temp / path).write_text(originals[path])
            # tcp_bbr.c comes directly from Google; adapter supplies TCP core APIs.
            args = ["git", "apply", "--exclude=net/ipv4/tcp_bbr.c"]
            check = subprocess.run(args + ["--check", "-"], input=patch, text=True,
                                   cwd=temp, capture_output=True)
            if check.returncode:
                errors.append(f"{ref}: {check.stderr}")
                continue
            subprocess.run(args + ["-"], input=patch, text=True, cwd=temp, check=True)
            adapted = google
            headers = (temp / "include/net/tcp.h").read_text()
            if "#define TCP_ECN_OK" not in headers and "tcp_ecn_mode_any" in headers:
                adapted = adapted.replace("(tcp_sk(sk)->ecn_flags & TCP_ECN_OK)",
                                          "tcp_ecn_mode_any(tcp_sk(sk))")
            # bytes is u64; use the kernel helper, including 32-bit portability.
            adapted = adapted.replace("max_t(u32, bytes / mss_now,", "max_t(u32, div_u64(bytes, mss_now),")
            (temp / "net/ipv4/tcp_bbr.c").write_text(adapted)
            generated = ""
            for path in paths:
                generated += "".join(difflib.unified_diff(
                    originals[path].splitlines(True), (temp / path).read_text().splitlines(True),
                    fromfile="a/" + path, tofile="b/" + path))
            output.write_text(generated, encoding="utf-8", newline="\n")
            Path("build-info/bbr.json").write_text(json.dumps({
                "google_repository": "https://github.com/google/bbr", "google_commit": GOOGLE,
                "adapter_repository": ADAPTER_REPO,
                "adapter_commit": subprocess.check_output(["git", "-C", str(repo), "rev-parse", ref]).decode().strip(),
                "kernel_series": series, "files": paths,
                "validation": "TCP adapter dry-run passed; Kbuild required next"}, indent=2))
            print(f"Generated {output} against actual kernel; selected adapter {ref}")
            return
    raise SystemExit("No reviewed BBRv3 adapter matches this kernel API:\n" + "\n".join(errors))


if __name__ == "__main__":
    main(*sys.argv[1:])
