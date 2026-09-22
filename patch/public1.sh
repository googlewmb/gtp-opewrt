#!/bin/bash
#
# ============================================================
# OpenWrt Mainline / H68K
# Google BBRv3 Kernel Integration
#
# 目标：
#   OpenWrt mainline
#   HINLINK H68K
#   Linux 6.18
#   Google BBRv3
#
# 核心原则：
#   1. 不使用 YAOF / TurboACC / XanMod / CachyOS 等下游 BBR
#   2. BBRv3 来源唯一指定为 google/bbr
#   3. 不把 6.13.7 -> v3 的整个 Git range 当作 BBR patch
#   4. 只处理明确列出的 BBR/TCP/ECN 内核提交
#   5. 已经存在于当前 Linux 6.18 的修改自动跳过
#   6. 无法安全移植的修改直接失败，不强行继续
#   7. 最终生成 OpenWrt pending-6.18 patch
#   8. 最终必须通过 target/linux/compile
#
# ============================================================

set -euo pipefail

echo
echo "============================================================"
echo " OpenWrt Mainline H68K - Google BBRv3"
echo "============================================================"
echo

# ------------------------------------------------------------
# 基础检查
# ------------------------------------------------------------

[ -d "target/linux" ] || {
    echo "错误：当前目录不是 OpenWrt 源码根目录"
    exit 1
}

[ -x "./scripts/feeds" ] || {
    echo "错误：当前目录不是有效的 OpenWrt 源码树"
    exit 1
}

grep -q '^CONFIG_TARGET_DEVICE_rockchip_armv8_DEVICE_hinlink_h68k=y$' .config 2>/dev/null || {
    echo "错误：当前配置不是 HINLINK H68K"
    exit 1
}

# ------------------------------------------------------------
# OpenWrt kernel 版本
# ------------------------------------------------------------

KERNEL_PATCHVER="$(
    sed -n 's/^KERNEL_PATCHVER[[:space:]]*:=[[:space:]]*//p' \
        target/linux/rockchip/Makefile |
    head -n 1
)"

[ -n "$KERNEL_PATCHVER" ] || {
    echo "错误：无法读取 Rockchip KERNEL_PATCHVER"
    exit 1
}

echo "检测到 Rockchip Kernel : ${KERNEL_PATCHVER}"

case "$KERNEL_PATCHVER" in
    6.18)
        ;;
    *)
        echo "错误：当前脚本只针对 Linux 6.18"
        echo "当前版本：${KERNEL_PATCHVER}"
        exit 1
        ;;
esac

# ------------------------------------------------------------
# Google BBR
# ------------------------------------------------------------

BBR_REPO="https://github.com/google/bbr.git"
BBR_BRANCH="v3"

# Google BBR v3 发布提交
BBR_RELEASE_COMMIT="90210de4b779d40496dee0b89081780eeddf2a60"

# ------------------------------------------------------------
# Google BBRv3 真正相关的 Linux 内核提交
#
# 注意：
#   这里故意不使用：
#
#       git format-patch 6.13.7..v3
#
#   因为那个范围包含非 BBR 的 Linux 提交。
#
#   下列 SHA 为 Google bbr 仓库中明确涉及：
#     - BBR v2/v3 TCP API
#     - BBR v3 算法
#     - ECN
#     - TCP rate sample
#     - TLP
#     - TSO
#     - TCP_INFO
#
#   的内核提交。
# ------------------------------------------------------------

BBR_COMMITS=(
    "703f20a1052d0c024f0e78bd1228eee6906dabf8"
    "3ee83ca004fafa436d448c261472ebe3b1942b42"
    "a631934cbcd8cddc4bac7d3fb91f890a3c07cd85"
    "4d2e56435d43a59d32890042b0ef13f6da6bac50"
    "9163f4486be72f190a5ada8002fdc14cced4b2ea"
    "6642024274d7f80ed00044962dcfbe301484edc9"
    "5093de531d14d864bbc95bd5d3031f3996dc88fc"
    "88e09e2b7c845db4faa3532903da453db745b39c"
    "f2078939d4a8cee55dc24cb4736b1fbb9eae5f97"
    "500bcfec22c478f4f1e07f66fd2a23ab2184b361"
    "3679f3b8da5a5b2528b6e14c5510617ed83db72b"
    "0e6b4413cb4a6a951532611bccd6aca4b22b5bbf"
    "a627517bdfe01967c3f8b931cfce99abfa878ef5"
    "137a508c950878712068b1d7a67ece75e4f2835c"
    "9120f8037e8b7a025e3998d1ec51b5e0fad837be"
    "cb31f3d02b1d7cd7cfdff4dd2b8b9d38879904af"
    "88aff899355d12fe1053997facec835aecd9f7d6"
    "795544cc00f03d49cfa6802f3da32c0d0a6fb4ab"
)

# ------------------------------------------------------------
# 临时目录
# ------------------------------------------------------------

WORK_ROOT="$TOPDIR"
if [ -z "${TOPDIR:-}" ]; then
    WORK_ROOT="$(pwd)"
fi

TMP_ROOT="${WORK_ROOT}/tmp-bbrv3"
BBR_SOURCE="${TMP_ROOT}/google-bbr"
PATCH_DIR="${TMP_ROOT}/patches"

rm -rf "$TMP_ROOT"
mkdir -p "$PATCH_DIR"

cleanup() {
    rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

# ------------------------------------------------------------
# OpenWrt kernel source
# ------------------------------------------------------------

echo
echo "============================================================"
echo "准备 OpenWrt Linux ${KERNEL_PATCHVER}"
echo "============================================================"

make target/linux/prepare V=s

KERNEL_DIR="$(
    find "${WORK_ROOT}/build_dir" \
        -type f \
        -path "*/linux-${KERNEL_PATCHVER}*/Makefile" \
        -print 2>/dev/null |
    head -n 1 |
    sed 's#/Makefile$##'
)"

[ -n "$KERNEL_DIR" ] || {
    echo "错误：找不到实际 Linux ${KERNEL_PATCHVER} kernel source"
    exit 1
}

[ -f "$KERNEL_DIR/Makefile" ] || {
    echo "错误：kernel source 无效：$KERNEL_DIR"
    exit 1
}

echo "Kernel source：$KERNEL_DIR"

# ------------------------------------------------------------
# 建立临时 Git 基线
#
# 目的：
#   保存“应用 BBR 前”的 Linux 6.18 完整状态。
#
# 最后通过 git diff 生成 OpenWrt patch。
# ------------------------------------------------------------

cd "$KERNEL_DIR"

rm -rf .git

git init -q
git config user.name "OpenWrt BBRv3 Builder"
git config user.email "builder@localhost"

git add -A
git commit -q -m "OpenWrt Linux ${KERNEL_PATCHVER} BBRv3 base"

BASE_COMMIT="$(git rev-parse HEAD)"

echo
echo "OpenWrt kernel base：$BASE_COMMIT"

# ------------------------------------------------------------
# 获取 Google BBR v3 Git 对象
# ------------------------------------------------------------

echo
echo "============================================================"
echo "获取 Google BBR v3"
echo "============================================================"

git remote add google "$BBR_REPO"

git fetch --no-tags --depth=128 google "$BBR_BRANCH"

git cat-file -e "${BBR_RELEASE_COMMIT}^{commit}" || {
    echo "错误：Google BBR v3 release commit 不存在"
    exit 1
}

echo "Google BBR v3 release：$BBR_RELEASE_COMMIT"

# ------------------------------------------------------------
# 逐个处理 BBR 内核提交
# ------------------------------------------------------------

APPLIED_COUNT=0
SKIPPED_COUNT=0
FAILED_COUNT=0

for COMMIT in "${BBR_COMMITS[@]}"; do

    echo
    echo "------------------------------------------------------------"
    echo "处理 BBR commit：$COMMIT"
    echo "------------------------------------------------------------"

    git cat-file -e "${COMMIT}^{commit}" || {
        echo "错误：找不到 Google BBR commit：$COMMIT"
        exit 1
    }

    SUBJECT="$(
        git show -s --format='%s' "$COMMIT"
    )"

    echo "标题：$SUBJECT"

    PATCH_FILE="${PATCH_DIR}/${COMMIT}.patch"

    git format-patch \
        --no-signature \
        --no-stat \
        --no-numbered \
        -1 \
        "$COMMIT" \
        --stdout > "$PATCH_FILE"

    [ -s "$PATCH_FILE" ] || {
        echo "错误：生成 patch 失败：$COMMIT"
        exit 1
    }

    # --------------------------------------------------------
    # 1. 正向检查
    #
    # 如果当前 Linux 6.18 尚未包含该修改，
    # 能直接应用则直接应用。
    # --------------------------------------------------------

    if git apply --check "$PATCH_FILE" >/dev/null 2>&1; then

        git apply --index "$PATCH_FILE"

        git commit -q \
            -m "Apply Google BBR: ${SUBJECT}"

        APPLIED_COUNT=$((APPLIED_COUNT + 1))

        echo "状态：已应用"

        continue
    fi

    # --------------------------------------------------------
    # 2. 反向检查
    #
    # 如果反向可以应用，说明该修改已经存在。
    # --------------------------------------------------------

    if git apply --reverse --check "$PATCH_FILE" >/dev/null 2>&1; then

        SKIPPED_COUNT=$((SKIPPED_COUNT + 1))

        echo "状态：当前 Linux ${KERNEL_PATCHVER} 已包含，跳过"

        continue
    fi

    # --------------------------------------------------------
    # 3. 正向不能直接应用、反向也不能应用
    #
    # 尝试 3-way。
    # --------------------------------------------------------

    echo "普通 patch 无法直接应用，尝试 3-way..."

    if git am --3way --keep-non-patch "$PATCH_FILE" >/dev/null 2>&1; then

        APPLIED_COUNT=$((APPLIED_COUNT + 1))

        echo "状态：3-way 应用成功"

        continue
    fi

    # --------------------------------------------------------
    # 4. 3-way 失败
    #
    # 必须失败退出。
    #
    # 不允许：
    #   - 自动丢弃冲突
    #   - 自动删除代码
    #   - 自动接受错误结果
    #   - 带着残缺 BBR 编译
    # --------------------------------------------------------

    git am --abort >/dev/null 2>&1 || true

    FAILED_COUNT=$((FAILED_COUNT + 1))

    echo
    echo "============================================================"
    echo "错误：Google BBR commit 无法安全移植"
    echo "Commit : $COMMIT"
    echo "Title  : $SUBJECT"
    echo "============================================================"
    echo
    echo "当前 Linux ${KERNEL_PATCHVER} 与该 BBR 提交存在"
    echo "无法自动解决的源码差异。"
    echo
    echo "脚本已停止，不会生成伪造的 BBRv3 patch。"
    exit 1

done

# ------------------------------------------------------------
# 删除 Google remote
# ------------------------------------------------------------

git remote remove google || true

# ------------------------------------------------------------
# 生成最终 OpenWrt patch
#
# 注意：
#   这里不是使用 Google 的历史 patch range。
#
#   而是：
#
#       OpenWrt Linux 6.18 原始状态
#                  ↓
#       实际成功应用的 BBR 修改
#                  ↓
#       当前最终 kernel 状态
#
#   再由两者 diff 生成一个 OpenWrt patch。
# ------------------------------------------------------------

FINAL_PATCH_DIR="${WORK_ROOT}/target/linux/generic/pending-${KERNEL_PATCHVER}"

mkdir -p "$FINAL_PATCH_DIR"

FINAL_PATCH="${FINAL_PATCH_DIR}/999-bbrv3-google.patch"

rm -f "$FINAL_PATCH"

git diff \
    --binary \
    "$BASE_COMMIT" \
    HEAD > "$FINAL_PATCH"

[ -s "$FINAL_PATCH" ] || {
    echo
    echo "错误：最终 BBRv3 patch 为空"
    echo "没有任何 Google BBR 修改被应用。"
    exit 1
}

# ------------------------------------------------------------
# 基础 patch 内容检查
# ------------------------------------------------------------

echo
echo "============================================================"
echo "检查最终 patch"
echo "============================================================"

grep -q 'tcp_bbr.c' "$FINAL_PATCH" || {
    echo "错误：最终 patch 不包含 tcp_bbr.c"
    exit 1
}

grep -q 'BBR_BW_PROBE_UP' "$FINAL_PATCH" || {
    echo "错误：最终 patch 缺少 BBRv3 bandwidth probe 状态机"
    exit 1
}

grep -q 'inflight_hi' "$FINAL_PATCH" || {
    echo "错误：最终 patch 缺少 BBRv3 inflight_hi"
    exit 1
}

grep -q 'bw_lo' "$FINAL_PATCH" || {
    echo "错误：最终 patch 缺少 BBRv3 bw_lo"
    exit 1
}

grep -q 'bw_hi' "$FINAL_PATCH" || {
    echo "错误：最终 patch 缺少 BBRv3 bw_hi"
    exit 1
}

# ------------------------------------------------------------
# 检查最终 kernel 源码
# ------------------------------------------------------------

[ -f "$KERNEL_DIR/net/ipv4/tcp_bbr.c" ] || {
    echo "错误：tcp_bbr.c 不存在"
    exit 1
}

grep -q 'BBR_BW_PROBE_UP' \
    "$KERNEL_DIR/net/ipv4/tcp_bbr.c" || {
    echo "错误：最终 tcp_bbr.c 缺少 BBRv3 BBR_BW_PROBE_UP"
    exit 1
}

grep -q 'inflight_hi' \
    "$KERNEL_DIR/net/ipv4/tcp_bbr.c" || {
    echo "错误：最终 tcp_bbr.c 缺少 inflight_hi"
    exit 1
}

grep -q 'bw_lo' \
    "$KERNEL_DIR/net/ipv4/tcp_bbr.c" || {
    echo "错误：最终 tcp_bbr.c 缺少 bw_lo"
    exit 1
}

grep -q 'bw_hi' \
    "$KERNEL_DIR/net/ipv4/tcp_bbr.c" || {
    echo "错误：最终 tcp_bbr.c 缺少 bw_hi"
    exit 1
}

# ------------------------------------------------------------
# 统计最终 patch
# ------------------------------------------------------------

PATCH_LINES="$(wc -l < "$FINAL_PATCH")"
PATCH_SIZE="$(wc -c < "$FINAL_PATCH")"

echo
echo "============================================================"
echo "BBRv3 源码处理完成"
echo "============================================================"
echo
echo "Google BBR commits : ${#BBR_COMMITS[@]}"
echo "Applied             : ${APPLIED_COUNT}"
echo "Already present     : ${SKIPPED_COUNT}"
echo "Failed              : ${FAILED_COUNT}"
echo
echo "Final patch         : $FINAL_PATCH"
echo "Patch size          : ${PATCH_SIZE} bytes"
echo "Patch lines         : ${PATCH_LINES}"
echo

# ------------------------------------------------------------
# 清理临时 Git 仓库
# ------------------------------------------------------------

cd "$WORK_ROOT"

rm -rf "$KERNEL_DIR/.git"

# ------------------------------------------------------------
# 重新清理并准备 OpenWrt kernel
#
# 目的：
#   验证刚才生成的：
#
#   target/linux/generic/pending-6.18/
#
#   能被 OpenWrt 正常重新应用。
# ------------------------------------------------------------

echo
echo "============================================================"
echo "重新应用 OpenWrt BBRv3 patch"
echo "============================================================"

make target/linux/clean V=s

make target/linux/prepare V=s

# ------------------------------------------------------------
# 再次定位 kernel source
# ------------------------------------------------------------

KERNEL_DIR_AFTER="$(
    find "${WORK_ROOT}/build_dir" \
        -type f \
        -path "*/linux-${KERNEL_PATCHVER}*/Makefile" \
        -print 2>/dev/null |
    head -n 1 |
    sed 's#/Makefile$##'
)"

[ -n "$KERNEL_DIR_AFTER" ] || {
    echo "错误：重新 prepare 后找不到 Linux ${KERNEL_PATCHVER}"
    exit 1
}

# ------------------------------------------------------------
# 验证 OpenWrt 真正应用了 patch
# ------------------------------------------------------------

[ -f "$KERNEL_DIR_AFTER/net/ipv4/tcp_bbr.c" ] || {
    echo "错误：重新 prepare 后 tcp_bbr.c 不存在"
    exit 1
}

grep -q 'BBR_BW_PROBE_UP' \
    "$KERNEL_DIR_AFTER/net/ipv4/tcp_bbr.c" || {
    echo "错误：重新 prepare 后没有 BBR_BW_PROBE_UP"
    exit 1
}

grep -q 'inflight_hi' \
    "$KERNEL_DIR_AFTER/net/ipv4/tcp_bbr.c" || {
    echo "错误：重新 prepare 后没有 inflight_hi"
    exit 1
}

grep -q 'bw_lo' \
    "$KERNEL_DIR_AFTER/net/ipv4/tcp_bbr.c" || {
    echo "错误：重新 prepare 后没有 bw_lo"
    exit 1
}

grep -q 'bw_hi' \
    "$KERNEL_DIR_AFTER/net/ipv4/tcp_bbr.c" || {
    echo "错误：重新 prepare 后没有 bw_hi"
    exit 1
}

# ------------------------------------------------------------
# 最终真实编译
# ------------------------------------------------------------

echo
echo "============================================================"
echo "开始编译 OpenWrt Linux ${KERNEL_PATCHVER}"
echo "============================================================"
echo

make target/linux/compile -j1 V=s

# ------------------------------------------------------------
# 最终结果
# ------------------------------------------------------------

echo
echo "============================================================"
echo " Google BBRv3 + OpenWrt Mainline + H68K"
echo "============================================================"
echo
echo "结果：BBRv3 kernel patch 编译验证成功"
echo
echo "Target  : HINLINK H68K"
echo "Kernel  : ${KERNEL_PATCHVER}"
echo "Source  : Google BBR v3"
echo "Patch   : ${FINAL_PATCH}"
echo
echo "Applied             : ${APPLIED_COUNT}"
echo "Already present     : ${SKIPPED_COUNT}"
echo "Failed              : ${FAILED_COUNT}"
echo
echo "============================================================"
echo "BBRv3 OK"
echo "============================================================"
