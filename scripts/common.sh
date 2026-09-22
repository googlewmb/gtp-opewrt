#!/usr/bin/env bash
set -euo pipefail
PROJECT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
test -f include/toplevel.mk
test -f .config
mkdir -p .sources build-info
enabled() { grep -Eq "^CONFIG_PACKAGE_$1=(y|m)$" .config; }
source_repo() {
    local name="$1" url="$2" branch="$3"
    if [[ ! -d ".sources/$name/.git" ]]; then
        git clone --depth 1 --single-branch --branch "$branch" "$url" ".sources/$name"
    fi
    printf '%s %s %s\n' "$name" "$url" "$(git -C ".sources/$name" rev-parse HEAD)" >> build-info/sources.txt
}
kernel_version() {
    sed -nE 's/^KERNEL_PATCHVER[[:space:]]*:?=[[:space:]]*([0-9]+\.[0-9]+).*$/\1/p' target/linux/rockchip/Makefile
}