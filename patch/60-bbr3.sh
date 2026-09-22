#!/usr/bin/env bash
# BBRv3 专属入口：必须在 feeds、最终配置和交叉工具链完成后执行。
set -euo pipefail
source "$(dirname "$0")/common.sh"
python3 "$PROJECT_DIR/patch/openwrt-bbr3.py" --openwrt . --jobs "$(nproc)"
python3 "$PROJECT_DIR/patch/70-verify.py" kernel-check
