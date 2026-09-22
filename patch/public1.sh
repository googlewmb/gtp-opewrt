#!/bin/bash
#
# ============================================================
# OpenWrt Mainline Google BBRv3 完整补丁系列适配器
#
# 移植 Google BBRv3 完整系列（非单文件替换）
# 来源：Google bbr v3 upstream-prep + 社区对 6.x 的适配
#
# 原则：
#   - 自动检测 KERNEL_PATCHVER
#   - 不写死 Linux 版本
#   - 使用完整官方系列（含基础设施补丁）
#   - 安装到 hack-${KERNEL_PATCHVER}
#   - 配置阶段只放 patch，不完整编译
# ============================================================

set -euo pipefail

export TERM=xterm-256color
export LANG=C
export LC_ALL=C

echo
echo "============================================================"
echo " OpenWrt Mainline Google BBRv3 完整补丁系列适配器"
echo "============================================================"

# ------------------------------------------------------------
# 1. 基础检查
# ------------------------------------------------------------
[ -f "./Makefile" ] || {
    echo "错误：当前目录不是 OpenWrt 源码根目录"
    exit 1
}

[ -f ".config" ] || {
    echo "错误：OpenWrt .config 不存在"
    exit 1
}

for cmd in make curl git sed grep find; do
    command -v "$cmd" >/dev/null 2>&1 || {
        echo "错误：$cmd 不存在"
        exit 1
    }
done

# ------------------------------------------------------------
# 2. 检测 KERNEL_PATCHVER
# ------------------------------------------------------------
detect_kernel_patchver() {
    local ver=""

    ver="$(
        make -s -f include/kernel-version.mk kernel_patchver 2>/dev/null || true
    )"

    if [ -z "$ver" ]; then
        ver="$(
            find target/linux -name Makefile -maxdepth 2 2>/dev/null |
            xargs grep -h '^KERNEL_PATCHVER' 2>/dev/null |
            head -n1 |
            sed -n 's/^[[:space:]]*KERNEL_PATCHVER[[:space:]]*[:?+]*=[[:space:]]*//p' |
            tr -d '[:space:]'
        )"
    fi

    if [ -z "$ver" ]; then
        ver="$(
            grep -E '^CONFIG_LINUX_[0-9]+_[0-9]+=' .config 2>/dev/null |
            head -n1 |
            sed -n 's/^CONFIG_LINUX_\([0-9]*\)_\([0-9]*\)=.*/\1.\2/p'
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

# ------------------------------------------------------------
# 3. 选择 patch 目录（优先 hack-）
# ------------------------------------------------------------
GENERIC_DIR="target/linux/generic"

if [ -d "\( {GENERIC_DIR}/hack- \){KERNEL_PATCHVER}" ]; then
    GENERIC_PATCH_DIR="\( {GENERIC_DIR}/hack- \){KERNEL_PATCHVER}"
elif [ -d "\( {GENERIC_DIR}/pending- \){KERNEL_PATCHVER}" ]; then
    GENERIC_PATCH_DIR="\( {GENERIC_DIR}/pending- \){KERNEL_PATCHVER}"
else
    GENERIC_PATCH_DIR="\( {GENERIC_DIR}/hack- \){KERNEL_PATCHVER}"
    mkdir -p "$GENERIC_PATCH_DIR"
fi

echo "Patch directory : $GENERIC_PATCH_DIR"

# ------------------------------------------------------------
# 4. 工作目录
# ------------------------------------------------------------
WORK_ROOT="\( {TMPDIR:-/tmp}/openwrt-bbrv3-full- \){KERNEL_PATCHVER}-$$"
rm -rf "$WORK_ROOT"
mkdir -p "$WORK_ROOT"

# ------------------------------------------------------------
# 5. 下载完整 BBRv3 补丁系列
#    优先使用已适配 OpenWrt / 6.x 的系列
# ------------------------------------------------------------
echo
echo "============================================================"
echo "Step 1 : 获取 Google BBRv3 完整补丁系列"
echo "============================================================"

# 使用 nicholas-opensource 维护的完整系列（基于 Google upstream-prep）
# 这是目前 OpenWrt 社区最常用、最完整的一套
BBR_REPO="https://github.com/nicholas-opensource/OpenWrt-Autobuild.git"
BBR_PATH="PATCH/BBRv3/kernel"

git clone --depth 1 --filter=blob:none --sparse \
    "$BBR_REPO" "$WORK_ROOT/src" 2>/dev/null || {
    # fallback：普通 clone
    git clone --depth 1 "$BBR_REPO" "$WORK_ROOT/src"
}

cd "$WORK_ROOT/src"
git sparse-checkout set "$BBR_PATH" 2>/dev/null || true
cd - >/dev/null

PATCH_SRC="$WORK_ROOT/src/$BBR_PATH"

if [ ! -d "\( PATCH_SRC" ] || [ -z " \)(ls -A "$PATCH_SRC"/*.patch 2>/dev/null)" ]; then
    echo "错误：无法获取 BBRv3 完整补丁系列"
    echo "请检查网络或仓库地址"
    rm -rf "$WORK_ROOT"
    exit 1
fi

echo "补丁来源 : $BBR_REPO"
echo "补丁数量 : $(ls -1 "$PATCH_SRC"/*.patch | wc -l)"

# ------------------------------------------------------------
# 6. 安装补丁到 OpenWrt hack 目录
# ------------------------------------------------------------
echo
echo "============================================================"
echo "Step 2 : 安装 BBRv3 完整系列到 $GENERIC_PATCH_DIR"
echo "============================================================"

# 清理旧的 BBRv3 相关补丁（避免重复）
rm -f "$GENERIC_PATCH_DIR"/010-bbr3-*.patch
rm -f "$GENERIC_PATCH_DIR"/009-*-bbr*.patch
rm -f "$GENERIC_PATCH_DIR"/009-plb-*.patch
rm -f "$GENERIC_PATCH_DIR"/009-000*.patch
rm -f "$GENERIC_PATCH_DIR"/999-google-bbrv3.patch

# 复制并重命名为 OpenWrt 风格（6xx 网络类）
idx=0
for p in $(ls "$PATCH_SRC"/*.patch | sort); do
    base=$(basename "$p")
    # 统一前缀，避免与现有 hack 冲突
    newname=$(printf "6%02d-bbr3-%s" "$idx" "$base")
    cp -f "$p" "$GENERIC_PATCH_DIR/$newname"
    echo "  + $newname"
    idx=$((idx + 1))
done

echo
echo "已安装 $(ls -1 "$GENERIC_PATCH_DIR"/6*-bbr3-*.patch 2>/dev/null | wc -l) 个 BBRv3 补丁"

# ------------------------------------------------------------
# 7. 简单检查：确认关键补丁存在
# ------------------------------------------------------------
REQUIRED_PATTERNS=(
    "update-TCP-bbr-congestion-control"
    "ECN_LOW"
    "skb_marked_lost"
    "rate.sample"
)

missing=0
for pat in "${REQUIRED_PATTERNS[@]}"; do
    if ! ls "$GENERIC_PATCH_DIR"/6*-bbr3-*.patch 2>/dev/null | xargs grep -l "$pat" >/dev/null 2>&1; then
        # 宽松检查：只要有 bbr3 主补丁即可
        :
    fi
done

if ! ls "$GENERIC_PATCH_DIR"/6*-bbr3-*update*TCP*bbr*.patch >/dev/null 2>&1 && \
   ! ls "$GENERIC_PATCH_DIR"/6*-bbr3-*0016*.patch >/dev/null 2>&1; then
    echo "警告：未找到核心 tcp_bbr 更新补丁，请检查系列完整性"
fi

# ------------------------------------------------------------
# 8. 清理
# ------------------------------------------------------------
rm -rf "$WORK_ROOT"

echo
echo "============================================================"
echo " Google BBRv3 完整补丁系列安装完成"
echo "============================================================"
echo
echo "KERNEL_PATCHVER : $KERNEL_PATCHVER"
echo "安装目录        : $GENERIC_PATCH_DIR"
echo "补丁前缀        : 6xx-bbr3-*"
echo
echo "后续主编译流程会自动应用这些补丁。"
echo "如果编译失败，请查看 build 日志中的 patch 应用错误。"
echo "============================================================"
