#!/bin/bash
#
# ============================================================
# OpenWrt Mainline Google BBRv3 全自动适配器
#
# 严格原则（不可违背）：
#   1. 自动检测 KERNEL_PATCHVER
#   2. 不写死 Linux 版本
#   3. 使用 Google 官方 BBRv3
#   4. 不回放历史 kernel commit
#   5. 不使用 --3way 判断 API 兼容
#   6. 只接受真实 Linux Kbuild 验证
#   7. 无法编译立即 FAIL-CLOSED
#   8. 不猜测 TCP API
#   9. 只生成当前内核对应 patch
#  10. 最终执行 OpenWrt target/linux/compile 验证
#
# Google BBRv3 官方源（禁止修改）：
#   https://raw.githubusercontent.com/google/bbr/v3/net/ipv4/tcp_bbr.c
# ============================================================

set -euo pipefail

# ============================================================
# 0. 固定非交互编译环境
# ============================================================

export TERM=xterm-256color
export LANG=C
export LC_ALL=C
export FORCE_UNSAFE_CONFIGURE=1

echo
echo "============================================================"
echo " OpenWrt Mainline Google BBRv3 全自动适配器"
echo "============================================================"

# ============================================================
# 1. 基础环境检查
# ============================================================

[ -f "./Makefile" ] || {
    echo "错误：当前目录不是 OpenWrt 源码根目录"
    exit 1
}

[ -f ".config" ] || {
    echo "错误：OpenWrt .config 不存在，请先生成配置"
    exit 1
}

for cmd in make curl diff grep sed head find tail tr awk; do
    command -v "$cmd" >/dev/null 2>&1 || {
        echo "错误：缺少必要命令 $cmd"
        exit 1
    }
done

# ============================================================
# 2. 目标设备检查（H68K）
# ============================================================

grep -q \
    '^CONFIG_TARGET_DEVICE_rockchip_armv8_DEVICE_hinlink_h68k=y$' \
    .config || {
    echo
    echo "错误：当前配置不是官方 OpenWrt H68K"
    exit 1
}

echo "目标设备          : Hinlink H68K"

# ============================================================
# 3. 自动检测 KERNEL_PATCHVER
# ============================================================

detect_kernel_patchver() {
    local ver=""

    ver="$(
        make -s -f include/kernel-version.mk kernel_patchver 2>/dev/null || true
    )"

    if [ -z "$ver" ]; then
        ver="$(
            sed -n \
                's/^[[:space:]]*KERNEL_PATCHVER[[:space:]]*[:?+]*=[[:space:]]*//p' \
                target/linux/rockchip/Makefile 2>/dev/null |
            head -n 1 || true
        )"
    fi

    printf '%s' "$ver" | tr -d '[:space:]'
}

KERNEL_PATCHVER="$(detect_kernel_patchver)"

[ -n "$KERNEL_PATCHVER" ] || {
    echo "错误：无法检测 KERNEL_PATCHVER"
    exit 1
}

echo "KERNEL_PATCHVER   : $KERNEL_PATCHVER"

# ============================================================
# 4. 自动选择 generic patch 目录
# ============================================================

GENERIC_DIR="target/linux/generic"

if [ -d "\( {GENERIC_DIR}/pending- \){KERNEL_PATCHVER}" ]; then
    GENERIC_PATCH_DIR="\( {GENERIC_DIR}/pending- \){KERNEL_PATCHVER}"
else
    GENERIC_PATCH_DIR="${GENERIC_DIR}/pending"
fi

mkdir -p "$GENERIC_PATCH_DIR"

echo "Patch directory   : $GENERIC_PATCH_DIR"

# ============================================================
# 5. 工作目录
# ============================================================

WORK_ROOT="\( {TMPDIR:-/tmp}/openwrt-bbrv3- \){KERNEL_PATCHVER}-$$"

rm -rf "$WORK_ROOT"
mkdir -p "$WORK_ROOT"

GOOGLE_BBR="$WORK_ROOT/tcp_bbr-google-v3.c"
ORIGINAL_BBR="$WORK_ROOT/tcp_bbr-original.c"

PATCH_NAME="999-bbrv3-google.patch"
PATCH_PATH="$GENERIC_PATCH_DIR/$PATCH_NAME"

cleanup() {
    rm -rf "$WORK_ROOT"
}

trap cleanup EXIT

# ============================================================
# 6. 获取 Google 官方 BBRv3（地址严禁修改）
# ============================================================

echo
echo "============================================================"
echo "Step 1 : 获取 Google 官方 BBRv3"
echo "============================================================"

GOOGLE_BBR_URL="https://raw.githubusercontent.com/google/bbr/v3/net/ipv4/tcp_bbr.c"

curl -fL \
    --retry 5 \
    --retry-delay 2 \
    --connect-timeout 20 \
    --max-time 120 \
    "$GOOGLE_BBR_URL" \
    -o "$GOOGLE_BBR"

[ -s "$GOOGLE_BBR" ] || {
    echo "错误：Google BBRv3 下载失败"
    exit 1
}

grep -Eq \
    '^[[:space:]]*#define[[:space:]]+BBR_VERSION[[:space:]]+3([[:space:]]|$)' \
    "$GOOGLE_BBR" || {
    echo "错误：下载内容不是可确认的 BBRv3"
    exit 1
}

grep -q 'struct bbr' "$GOOGLE_BBR" || {
    echo "错误：BBRv3 struct bbr 不存在"
    exit 1
}

grep -q 'bw_hi' "$GOOGLE_BBR" || {
    echo "错误：BBRv3 bw_hi 不存在"
    exit 1
}

grep -q 'inflight_hi' "$GOOGLE_BBR" || {
    echo "错误：BBRv3 inflight_hi 不存在"
    exit 1
}

echo "Google BBRv3      : PASS"

# ============================================================
# 7. OpenWrt defconfig
# ============================================================

echo
echo "============================================================"
echo "Step 2 : OpenWrt defconfig"
echo "============================================================"

make defconfig

echo "OpenWrt defconfig : PASS"

# ============================================================
# 8. OpenWrt target/linux/prepare
# ============================================================

echo
echo "============================================================"
echo "Step 3 : OpenWrt target/linux/prepare"
echo "============================================================"

make target/linux/prepare V=s

# ============================================================
# 9. 定位真实 Linux 源码目录
# ============================================================

detect_linux_dir() {
    local dir=""

    # 方法1：直接找包含 tcp_bbr.c 的内核目录（最可靠）
    dir="$(
        find build_dir \
            -type f \
            -path '*/linux-*/net/ipv4/tcp_bbr.c' \
            2>/dev/null |
        sed 's#/net/ipv4/tcp_bbr.c$##' |
        head -n 1 || true
    )"

    if [ -n "$dir" ] && [ -f "$dir/Makefile" ]; then
        printf '%s' "$dir"
        return 0
    fi

    # 方法2：扫描 linux-* 目录
    dir="$(
        find build_dir \
            -maxdepth 4 \
            -type d \
            -path '*/linux-*/linux-*' \
            2>/dev/null |
        head -n 1 || true
    )"

    if [ -n "$dir" ] && [ -f "$dir/Makefile" ] && [ -f "$dir/net/ipv4/tcp_bbr.c" ]; then
        printf '%s' "$dir"
        return 0
    fi

    # 方法3：最终回退
    dir="$(
        find build_dir \
            -maxdepth 6 \
            -type f \
            -path '*/linux-*/Makefile' \
            2>/dev/null |
        sed 's#/Makefile$##' |
        head -n 1 || true
    )"

    printf '%s' "$dir"
}

LINUX_DIR="$(detect_linux_dir)"

[ -n "$LINUX_DIR" ] || {
    echo "错误：无法定位真实 Linux kernel"
    exit 1
}

[ -f "$LINUX_DIR/Makefile" ] || {
    echo "错误：LINUX_DIR 无效"
    exit 1
}

[ -f "$LINUX_DIR/net/ipv4/tcp_bbr.c" ] || {
    echo "错误：当前 Linux 没有 net/ipv4/tcp_bbr.c"
    exit 1
}

echo "Linux source      : $LINUX_DIR"

# ============================================================
# 10. 获取实际 Linux 版本
# ============================================================

ACTUAL_KERNEL_VERSION="$(
    make -s -C "$LINUX_DIR" kernelversion 2>/dev/null || true
)"

[ -n "$ACTUAL_KERNEL_VERSION" ] || {
    echo "错误：无法读取 Linux kernel version"
    exit 1
}

echo "Linux version     : $ACTUAL_KERNEL_VERSION"

# ============================================================
# 11. 保存 OpenWrt 原始 BBR
# ============================================================

cp -f \
    "$LINUX_DIR/net/ipv4/tcp_bbr.c" \
    "$ORIGINAL_BBR"

# ============================================================
# 12. 如果当前内核已经是 BBRv3
# ============================================================

if grep -Eq \
    '^[[:space:]]*#define[[:space:]]+BBR_VERSION[[:space:]]+3([[:space:]]|$)' \
    "$ORIGINAL_BBR"
then
    echo
    echo "当前 Linux 已经包含 Google BBRv3"
    echo "无需生成 BBRv3 patch"
    exit 0
fi

# ============================================================
# 13. 替换为 Google 官方 BBRv3
# ============================================================

cp -f \
    "$GOOGLE_BBR" \
    "$LINUX_DIR/net/ipv4/tcp_bbr.c"

# ============================================================
# 14. 确认替换后源码确实是 BBRv3
# ============================================================

grep -Eq \
    '^[[:space:]]*#define[[:space:]]+BBR_VERSION[[:space:]]+3([[:space:]]|$)' \
    "$LINUX_DIR/net/ipv4/tcp_bbr.c" || {
    echo "错误：替换后源码不是 BBRv3"
    exit 1
}

# ============================================================
# 15. 生成干净 patch
# ============================================================

echo
echo "============================================================"
echo "Step 4 : 生成 BBRv3 patch"
echo "============================================================"

rm -f "$PATCH_PATH"

diff -u \
    --label "a/net/ipv4/tcp_bbr.c" \
    --label "b/net/ipv4/tcp_bbr.c" \
    "$ORIGINAL_BBR" \
    "$LINUX_DIR/net/ipv4/tcp_bbr.c" \
    >"$PATCH_PATH" || true

[ -s "$PATCH_PATH" ] || {
    echo "错误：BBRv3 patch 为空"
    exit 1
}

grep -q \
    '^--- a/net/ipv4/tcp_bbr.c' \
    "$PATCH_PATH" || {
    echo "错误：patch 路径异常"
    exit 1
}

grep -q \
    '^+++ b/net/ipv4/tcp_bbr.c' \
    "$PATCH_PATH" || {
    echo "错误：patch 路径异常"
    exit 1
}

echo "Patch generated   : $PATCH_PATH"

# ============================================================
# 16. 恢复原始源码
# ============================================================

cp -f \
    "$ORIGINAL_BBR" \
    "$LINUX_DIR/net/ipv4/tcp_bbr.c"

# ============================================================
# 17. OpenWrt 重新 prepare（验证 patch 回放）
# ============================================================

echo
echo "============================================================"
echo "Step 5 : OpenWrt patch 回放验证"
echo "============================================================"

make target/linux/clean V=s
make defconfig
make target/linux/prepare V=s

LINUX_DIR="$(detect_linux_dir)"

[ -n "$LINUX_DIR" ] || {
    echo "错误：重新 prepare 后无法定位 Linux"
    exit 1
}

[ -f "$LINUX_DIR/net/ipv4/tcp_bbr.c" ] || {
    echo "错误：重新 prepare 后 tcp_bbr.c 不存在"
    exit 1
}

# 确认 BBRv3 已被正确应用
grep -Eq \
    '^[[:space:]]*#define[[:space:]]+BBR_VERSION[[:space:]]+3([[:space:]]|$)' \
    "$LINUX_DIR/net/ipv4/tcp_bbr.c" || {
    echo
    echo "错误：OpenWrt prepare 后没有得到 BBRv3"
    exit 1
}

echo "OpenWrt prepare   : PASS"
echo "BBR_VERSION=3     : PASS"

# ============================================================
# 18. 最终真实验证：OpenWrt target/linux/compile
# ============================================================

echo
echo "============================================================"
echo "Step 6 : OpenWrt target/linux/compile（真实 Kbuild 验证）"
echo "============================================================"

make target/linux/compile -j"$(nproc)" V=s

# ============================================================
# 19. 最终确认
# ============================================================

echo
echo "============================================================"
echo " Google BBRv3 全自动适配完成"
echo "============================================================"
echo

echo "Target            : HINLINK H68K"
echo "KERNEL_PATCHVER   : $KERNEL_PATCHVER"
echo "Linux version     : $ACTUAL_KERNEL_VERSION"
echo "BBR               : Google BBRv3 (官方源)"
echo "OpenWrt prepare   : PASS"
echo "OpenWrt compile   : PASS"

echo
echo "生成的 Patch："
echo "  $PATCH_PATH"

echo
echo "============================================================"
echo " FAIL-CLOSED 验证全部通过"
echo "============================================================"
