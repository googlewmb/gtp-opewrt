#!/bin/bash
#
# ============================================================
# OpenWrt Mainline Google BBRv3 自动适配器
#
# 严格原则：
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
# ============================================================

set -euo pipefail

# ============================================================
# 0. 固定非交互编译环境
# ============================================================

export TERM=xterm-256color
export LANG=C
export LC_ALL=C

echo
echo "============================================================"
echo " OpenWrt Mainline Google BBRv3 自动适配器"
echo "============================================================"

# ============================================================
# 1. 基础检查
# ============================================================

[ -f "./Makefile" ] || {
    echo "错误：当前目录不是 OpenWrt 源码根目录"
    exit 1
}

[ -f ".config" ] || {
    echo "错误：OpenWrt .config 不存在"
    exit 1
}

command -v make >/dev/null 2>&1 || {
    echo "错误：make 不存在"
    exit 1
}

command -v curl >/dev/null 2>&1 || {
    echo "错误：curl 不存在"
    exit 1
}

command -v diff >/dev/null 2>&1 || {
    echo "错误：diff 不存在"
    exit 1
}

# ============================================================
# 2. H68K 检查
# ============================================================

grep -q \
    '^CONFIG_TARGET_DEVICE_rockchip_armv8_DEVICE_hinlink_h68k=y$' \
    .config || {
    echo
    echo "错误：当前配置不是官方 OpenWrt H68K"
    exit 1
}

echo "目标设备 : Hinlink H68K"

# ============================================================
# 3. 检测 KERNEL_PATCHVER
# ============================================================

detect_kernel_patchver() {
    local ver=""

    ver="$(
        make -s -f include/kernel-version.mk \
            kernel_patchver 2>/dev/null || true
    )"

    if [ -z "$ver" ]; then
        ver="$(
            sed -n \
                's/^[[:space:]]*KERNEL_PATCHVER[[:space:]]*[:?+]*=[[:space:]]*//p' \
                target/linux/rockchip/Makefile 2>/dev/null |
            head -n 1
        )"
    fi

    printf '%s' "$ver" | tr -d '[:space:]'
}

KERNEL_PATCHVER="$(detect_kernel_patchver)"

[ -n "$KERNEL_PATCHVER" ] || {
    echo "错误：无法检测 KERNEL_PATCHVER"
    exit 1
}

echo "KERNEL_PATCHVER : $KERNEL_PATCHVER"

# ============================================================
# 4. 自动选择 OpenWrt generic patch 目录
# ============================================================

GENERIC_DIR="target/linux/generic"

if [ -d "${GENERIC_DIR}/pending-${KERNEL_PATCHVER}" ]; then
    GENERIC_PATCH_DIR="${GENERIC_DIR}/pending-${KERNEL_PATCHVER}"
else
    GENERIC_PATCH_DIR="${GENERIC_DIR}/pending"
fi

mkdir -p "$GENERIC_PATCH_DIR"

echo "Patch directory : $GENERIC_PATCH_DIR"

# ============================================================
# 5. 工作目录
# ============================================================

WORK_ROOT="${TMPDIR:-/tmp}/openwrt-bbrv3-${KERNEL_PATCHVER}"

rm -rf "$WORK_ROOT"
mkdir -p "$WORK_ROOT"

GOOGLE_BBR="$WORK_ROOT/tcp_bbr-google-v3.c"
ORIGINAL_BBR="$WORK_ROOT/tcp_bbr-original.c"
FINAL_BBR="$WORK_ROOT/tcp_bbr-final.c"
BUILD_LOG="$WORK_ROOT/kbuild.log"
FINAL_BUILD_LOG="$WORK_ROOT/final-kbuild.log"

# ============================================================
# 6. 获取 Google 官方 BBRv3
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

echo "Google BBRv3 : PASS"

# ============================================================
# 7. 先让 OpenWrt 自己完成配置
#
# 防止 target/linux/prepare 进入 menuconfig，
# 修复 GitHub Actions 的 Error opening terminal: unknown
# ============================================================

echo
echo "============================================================"
echo "Step 2 : OpenWrt defconfig"
echo "============================================================"

make defconfig

grep -q \
    '^CONFIG_TARGET_DEVICE_rockchip_armv8_DEVICE_hinlink_h68k=y$' \
    .config || {
    echo "错误：defconfig 后 H68K 配置丢失"
    exit 1
}

# ============================================================
# 8. OpenWrt target/linux/prepare
# ============================================================

echo
echo "============================================================"
echo "Step 3 : OpenWrt target/linux/prepare"
echo "============================================================"

make target/linux/prepare V=s

# ============================================================
# 9. 定位真实 Linux kernel
# ============================================================

detect_linux_dir() {
    local dir=""

    dir="$(
        make -s -pn 2>/dev/null |
        sed -n 's/^LINUX_DIR := //p' |
        head -n 1
    )"

    if [ -n "$dir" ] && [ -f "$dir/Makefile" ]; then
        printf '%s' "$dir"
        return 0
    fi

    find build_dir \
        -maxdepth 5 \
        -type f \
        -path '*/linux-*/Makefile' \
        2>/dev/null |
    sed 's#/Makefile$##' |
    head -n 1
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

echo "Linux source : $LINUX_DIR"

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

echo "Linux version : $ACTUAL_KERNEL_VERSION"

# ============================================================
# 11. 保存 OpenWrt 原始 BBR
# ============================================================

cp -f \
    "$LINUX_DIR/net/ipv4/tcp_bbr.c" \
    "$ORIGINAL_BBR"

# ============================================================
# 12. 如果当前 kernel 已经是 BBRv3
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
# 13. 保存 Google BBRv3
# ============================================================

cp -f \
    "$GOOGLE_BBR" \
    "$FINAL_BBR"

# ============================================================
# 14. 替换 tcp_bbr.c
#
# 注意：
#
# 不自动修改任何其它 TCP 文件。
# 如果当前 kernel 缺少 BBRv3 所需 API，
# 后面的真实 Kbuild 会失败。
#
# 失败 = FAIL-CLOSED。
# ============================================================

cp -f \
    "$FINAL_BBR" \
    "$LINUX_DIR/net/ipv4/tcp_bbr.c"

# ============================================================
# 15. kernel olddefconfig
# ============================================================

make -C "$LINUX_DIR" olddefconfig

# ============================================================
# 16. 真实 Linux Kbuild 验证
# ============================================================

echo
echo "============================================================"
echo "Step 4 : Google BBRv3 Linux Kbuild"
echo "============================================================"

set +e

make -C "$LINUX_DIR" \
    V=1 \
    M=net/ipv4 \
    tcp_bbr.o \
    >"$BUILD_LOG" 2>&1

KBUILD_RC=$?

set -e

if [ "$KBUILD_RC" -ne 0 ]; then
    echo
    echo "============================================================"
    echo "FAIL-CLOSED"
    echo "============================================================"
    echo
    echo "当前 Linux 无法直接编译 Google BBRv3"
    echo
    echo "Linux version : $ACTUAL_KERNEL_VERSION"
    echo "KERNEL_PATCHVER : $KERNEL_PATCHVER"
    echo
    echo "不会："
    echo "  - 猜测 TCP API"
    echo "  - 猜测结构体字段"
    echo "  - 猜测函数参数"
    echo "  - 回放旧 kernel commit"
    echo "  - 使用 --3way 强行合并"
    echo "  - 修改无关 TCP 子系统"
    echo
    echo "Kbuild 错误："
    tail -n 200 "$BUILD_LOG"
    exit 1
fi

[ -f "$LINUX_DIR/net/ipv4/tcp_bbr.o" ] || {
    echo "错误：Kbuild 返回成功但 tcp_bbr.o 不存在"
    exit 1
}

echo "BBRv3 Kbuild : PASS"

# ============================================================
# 17. 确认当前源码确实是 BBRv3
# ============================================================

grep -Eq \
    '^[[:space:]]*#define[[:space:]]+BBR_VERSION[[:space:]]+3([[:space:]]|$)' \
    "$LINUX_DIR/net/ipv4/tcp_bbr.c" || {
    echo "错误：Kbuild 后源码不是 BBRv3"
    exit 1
}

# ============================================================
# 18. 生成干净 patch
#
# 只修改：
#
#   net/ipv4/tcp_bbr.c
#
# 不把 .git、build 文件、临时文件写进 patch。
# ============================================================

echo
echo "============================================================"
echo "Step 5 : 生成 BBRv3 patch"
echo "============================================================"

PATCH_NAME="999-bbrv3-google.patch"
PATCH_PATH="$GENERIC_PATCH_DIR/$PATCH_NAME"

rm -f "$PATCH_PATH"

diff \
    -u \
    --label "a/net/ipv4/tcp_bbr.c" \
    --label "b/net/ipv4/tcp_bbr.c" \
    "$ORIGINAL_BBR" \
    "$LINUX_DIR/net/ipv4/tcp_bbr.c" \
    > "$PATCH_PATH" || true

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

# ============================================================
# 19. 恢复 kernel 原始源码
#
# 然后让 OpenWrt 重新 prepare，
# 验证刚刚生成的 patch 是否真的能被 OpenWrt 应用。
# ============================================================

cp -f \
    "$ORIGINAL_BBR" \
    "$LINUX_DIR/net/ipv4/tcp_bbr.c"

# ============================================================
# 20. OpenWrt 重新 prepare
# ============================================================

echo
echo "============================================================"
echo "Step 6 : OpenWrt patch 回放验证"
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

# ============================================================
# 21. 确认 OpenWrt patch 已经成功应用
# ============================================================

grep -Eq \
    '^[[:space:]]*#define[[:space:]]+BBR_VERSION[[:space:]]+3([[:space:]]|$)' \
    "$LINUX_DIR/net/ipv4/tcp_bbr.c" || {
    echo
    echo "错误：OpenWrt prepare 后没有得到 BBRv3"
    exit 1
}

echo "OpenWrt prepare : PASS"
echo "BBR_VERSION=3   : PASS"

# ============================================================
# 22. 再次真实 Linux Kbuild
# ============================================================

echo
echo "============================================================"
echo "Step 7 : 最终 BBRv3 Kbuild"
echo "============================================================"

make -C "$LINUX_DIR" olddefconfig

set +e

make -C "$LINUX_DIR" \
    V=1 \
    M=net/ipv4 \
    tcp_bbr.o \
    >"$FINAL_BUILD_LOG" 2>&1

FINAL_KBUILD_RC=$?

set -e

if [ "$FINAL_KBUILD_RC" -ne 0 ]; then
    echo
    echo "错误：OpenWrt patch 回放后 BBRv3 Kbuild 失败"
    tail -n 200 "$FINAL_BUILD_LOG"
    exit 1
fi

[ -f "$LINUX_DIR/net/ipv4/tcp_bbr.o" ] || {
    echo "错误：最终 tcp_bbr.o 不存在"
    exit 1
}

echo "最终 BBRv3 Kbuild : PASS"

# ============================================================
# 23. 最终 OpenWrt target/linux/compile
#
# 这是最终验证，不只是单独编译 tcp_bbr.o。
# ============================================================

echo
echo "============================================================"
echo "Step 8 : OpenWrt target/linux/compile"
echo "============================================================"

make target/linux/compile -j1 V=s

# ============================================================
# 24. 最终确认
# ============================================================

echo
echo "============================================================"
echo " Google BBRv3 自动适配完成"
echo "============================================================"
echo
echo "Target            : HINLINK H68K"
echo "KERNEL_PATCHVER   : $KERNEL_PATCHVER"
echo "Linux version     : $ACTUAL_KERNEL_VERSION"
echo "BBR               : Google BBRv3"
echo "OpenWrt prepare   : PASS"
echo "BBRv3 Kbuild      : PASS"
echo "OpenWrt compile   : PASS"
echo
echo "Patch:"
echo "$PATCH_PATH"
echo
echo "============================================================"
echo " FAIL-CLOSED 验证完成"
echo "============================================================"
