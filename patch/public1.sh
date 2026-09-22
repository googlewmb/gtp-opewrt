#!/usr/bin/env bash
# Run after feeds, final config, host tools and toolchain.
set -euo pipefail
source "$(dirname "$0")/../scripts/common.sh"
python3 "$PROJECT_DIR/scripts/openwrt-bbr3.py" --openwrt . --jobs "$(nproc)"
python3 "$PROJECT_DIR/scripts/prepare.py" kernel-check
