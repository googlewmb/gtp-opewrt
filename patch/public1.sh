#!/bin/bash
#
# ============================================================
# public1.sh
#
# OpenWrt Mainline / HINLINK H68K
#
# 功能：
#   1. 确认当前源码是 OpenWrt Mainline
#   2. 确认目标为 HINLINK H68K
#   3. 确认 Rockchip 使用 Linux 6.18
#   4. 获取 Google 官方 BBR v3 源码历史
#   5. 从 Google 官方 Linux 6.13.7 基线提取 BBRv3 内核提交
#   6. 排除 tcp_bbr1.c / iproute2 / 测试代码
#   7. 在当前 OpenWrt 6.18 实际内核源码上逐提交进行 3-way backport
#   8. 只有全部提交成功才生成 OpenWrt patch
#   9. 重新执行 OpenWrt kernel prepare
#  10. 验证 BBR_VERSION=3
#  11. 编译 Linux kernel 验证
#
# 来源：
#   Google 官方：
#     https://github.com/google/bbr
#
# Google BBRv3：
#   基线：
#     648e04a805652f513af04b47035cde896addf9b0
#
#   最终：
#     90210de4b779d40496dee0b89081780eeddf2a60
#
# 注意：
#   90210... 是 Google bbr/v3 当前最终 README 提交。
#   内核 patch 通过路径过滤，只提取 include/ 和 net/
#   中的内核代码，因此不会把 README/iproute2/test 内容带入。
#
# ============================================================

set -euo pipefail

echo
echo "============================================================"
echo " OpenWrt Mainline / Google BBRv3"
echo " HINLINK H68K / Linux 6.18"
echo "============================================================"
echo

# ============================================================
# 1. 基础检查
# ============================================================

[ -f Makefile ] || {
    echo "错误：当前目录不是 OpenWrt 源码根目录"
    exit 1
}

[ -x ./scripts/feeds ] || {
    echo "错误：scripts/feeds 不存在"
    exit 1
}

[ -f .config ] || {
    echo "错误：.config 不存在"
    exit 1
}

# ============================================================
# 2. 确认 H68K
# ============================================================

if ! grep -q \
    '^CONFIG_TARGET_DEVICE_rockchip_armv8_DEVICE_hinlink_h68k=y$' \
    .config; then

    echo "错误：当前配置不是 HINLINK H68K"
    echo
    echo "当前 Rockchip 设备配置："
    grep '^CONFIG_TARGET_DEVICE_rockchip_armv8_DEVICE_' .config || true
    exit 1
fi

echo "目标设备：HINLINK H68K"

# ============================================================
# 3. 获取 Rockchip kernel 版本
# ============================================================

ROCKCHIP_MK="target/linux/rockchip/Makefile"

[ -f "$ROCKCHIP_MK" ] || {
    echo "错误：找不到 $ROCKCHIP_MK"
    exit 1
}

KERNEL_PATCHVER="$(
    sed -n \
        's/^[[:space:]]*KERNEL_PATCHVER[[:space:]]*:=[[:space:]]*//p' \
        "$ROCKCHIP_MK" |
        head -n 1
)"

[ -n "$KERNEL_PATCHVER" ] || {
    echo "错误：无法获取 Rockchip KERNEL_PATCHVER"
    exit 1
}

echo "OpenWrt Rockchip kernel：$KERNEL_PATCHVER"

if [ "$KERNEL_PATCHVER" != "6.18" ]; then
    echo
    echo "错误：当前脚本只针对 OpenWrt Mainline Linux 6.18"
    echo "检测到：$KERNEL_PATCHVER"
    exit 1
fi

# ============================================================
# 4. 规范化配置
#
# public1.sh 在 workflow 中早于最终 make defconfig。
# 这里先确保 kernel prepare 使用的是有效配置。
# 后面的 workflow 仍然会再次执行 make defconfig。
# ============================================================

echo
echo "========== OpenWrt defconfig =========="

make defconfig V=s

# 再次确认 H68K 没有被配置过程改变

grep -q \
    '^CONFIG_TARGET_DEVICE_rockchip_armv8_DEVICE_hinlink_h68k=y$' \
    .config || {
    echo "错误：defconfig 后 H68K 配置丢失"
    exit 1
}

# ============================================================
# 5. 先准备 OpenWrt 原始 Linux 6.18
# ============================================================

echo
echo "========== OpenWrt kernel prepare =========="

make target/linux/prepare -j1 V=s

# ============================================================
# 6. 定位 OpenWrt 实际使用的 Linux 源码
# ============================================================

LINUX_DIR="$(
    find build_dir/target-* \
        -maxdepth 4 \
        -type f \
        -path '*/linux-6.18*/Makefile' \
        -print 2>/dev/null |
    while read -r f; do
        d="${f%/Makefile}"

        if grep -q '^VERSION = 6$' "$f" &&
           grep -q '^PATCHLEVEL = 18$' "$f"; then
            echo "$d"
            break
        fi
    done
)"

if [ -z "$LINUX_DIR" ] || [ ! -f "$LINUX_DIR/Makefile" ]; then
    echo "错误：无法定位实际 Linux 6.18 源码目录"
    exit 1
fi

echo "Linux source：$LINUX_DIR"

# ============================================================
# 7. 再次确认实际 kernel 版本
# ============================================================

LINUX_VERSION="$(
    awk -F' = ' '
        /^VERSION =/     { v=$2 }
        /^PATCHLEVEL =/  { p=$2 }
        /^SUBLEVEL =/    { s=$2 }
        END {
            if (v != "" && p != "" && s != "")
                print v "." p "." s
        }
    ' "$LINUX_DIR/Makefile"
)"

case "$LINUX_VERSION" in
    6.18.*)
        ;;
    *)
        echo "错误：实际 Linux 源码不是 6.18.x"
        echo "检测到：$LINUX_VERSION"
        exit 1
        ;;
esac

echo "实际 Linux 版本：$LINUX_VERSION"

# ============================================================
# 8. Google BBR 官方固定版本
#
# 不使用 floating branch 来避免未来 v3 branch 改动导致
# CI 得到不同源码。
# ============================================================

BBR_REPO="https://github.com/google/bbr.git"

BBR_BASE="648e04a805652f513af04b47035cde896addf9b0"
BBR_HEAD="90210de4b779d40496dee0b89081780eeddf2a60"

BBR_BASE_NAME="Linux 6.13.7"
BBR_HEAD_NAME="Google BBR v3 release"

# ============================================================
# 9. 工作目录
# ============================================================

WORK_DIR="$(
    mktemp -d \
        "${TMPDIR:-/tmp}/openwrt-google-bbr3.XXXXXX"
)"

cleanup() {
    rm -rf "$WORK_DIR"
}

trap cleanup EXIT INT TERM

GOOGLE_DIR="$WORK_DIR/google-bbr"
SERIES_DIR="$WORK_DIR/series"

mkdir -p "$SERIES_DIR"

# ============================================================
# 10. 获取 Google 官方 BBR 仓库
#
# 使用 shallow fetch。
#
# BBR_BASE -> BBR_HEAD 的实际官方提交序列很短。
# 这里给足 128 层，避免使用整个 Linux 历史。
# ============================================================

echo
echo "========== 获取 Google 官方 BBR v3 =========="

git init -q "$GOOGLE_DIR"

git -C "$GOOGLE_DIR" remote add google-bbr "$BBR_REPO"

git -C "$GOOGLE_DIR" fetch \
    --no-tags \
    --depth=128 \
    google-bbr \
    "$BBR_HEAD"

# ============================================================
# 11. 确认两个固定提交存在
# ============================================================

git -C "$GOOGLE_DIR" cat-file -e \
    "${BBR_BASE}^{commit}" 2>/dev/null || {
    echo "错误：Google BBR 6.13.7 基线提交不存在"
    exit 1
}

git -C "$GOOGLE_DIR" cat-file -e \
    "${BBR_HEAD}^{commit}" 2>/dev/null || {
    echo "错误：Google BBR v3 最终提交不存在"
    exit 1
}

# ============================================================
# 12. 确认 BBR_BASE 是 BBR_HEAD 的祖先
# ============================================================

git -C "$GOOGLE_DIR" merge-base \
    --is-ancestor \
    "$BBR_BASE" \
    "$BBR_HEAD" || {

    echo "错误：Google BBR v3 历史异常"
    echo "无法确认 Linux 6.13.7 是 v3 的基线"
    exit 1
}

# ============================================================
# 13. 确认 Google v3 源码确实是 Linux 6.13.7
# ============================================================

GOOGLE_VERSION="$(
    git -C "$GOOGLE_DIR" show "$BBR_HEAD:Makefile" |
    awk -F' = ' '
        /^VERSION =/     { v=$2 }
        /^PATCHLEVEL =/  { p=$2 }
        /^SUBLEVEL =/    { s=$2 }
        END {
            if (v != "" && p != "" && s != "")
                print v "." p "." s
        }
    '
)"

if [ "$GOOGLE_VERSION" != "6.13.7" ]; then
    echo "错误：Google BBR v3 基线版本异常"
    echo "检测到：$GOOGLE_VERSION"
    exit 1
fi

echo "Google BBR 基线：$GOOGLE_VERSION"

# ============================================================
# 14. 生成官方 BBR kernel patch series
#
# 只取：
#
#   include/**
#   net/**
#
# 排除：
#
#   net/ipv4/tcp_bbr1.c
#
# 因为 tcp_bbr1.c 是 Google BBRv1 测试副本，
# 不是 H68K 所需的 BBRv3。
#
# iproute2/test/README 不在 include/net 中，因此自然不会进入。
# ============================================================

echo
echo "========== 提取 Google 官方 BBR kernel 提交 =========="

git -C "$GOOGLE_DIR" format-patch \
    --no-signature \
    --no-stat \
    --no-numbered \
    --output-directory "$SERIES_DIR" \
    "$BBR_BASE..$BBR_HEAD" \
    -- \
    'include/**' \
    'net/**' \
    ':(exclude)net/ipv4/tcp_bbr1.c'

PATCH_COUNT="$(
    find "$SERIES_DIR" \
        -maxdepth 1 \
        -type f \
        -name '*.patch' |
    wc -l
)"

if [ "$PATCH_COUNT" -eq 0 ]; then
    echo "错误：没有提取到 Google BBR kernel patch"
    exit 1
fi

echo "Google kernel patch 数量：$PATCH_COUNT"

# ============================================================
# 15. 严格检查 patch 内容
#
# 不允许：
#   tcp_bbr1.c
#   iproute2
#   gtests
#   userspace
#
# 允许：
#   include/*
#   net/*
# ============================================================

echo
echo "========== 检查 Google BBR patch 内容 =========="

for p in "$SERIES_DIR"/*.patch; do

    if grep -Eq \
        '^[+][+][+] b/.*tcp_bbr1\.c$|^[-]{3} a/.*tcp_bbr1\.c$' \
        "$p"; then

        echo "错误：检测到 tcp_bbr1.c"
        echo "文件：$p"
        exit 1
    fi

    while read -r path; do

        [ -z "$path" ] && continue

        case "$path" in
            include/*|net/*)
                ;;
            *)
                echo "错误：Google BBR kernel patch 出现非法路径"
                echo "路径：$path"
                echo "补丁：$p"
                exit 1
                ;;
        esac

    done < <(
        sed -n \
            -E \
            's/^\+\+\+ b\/(.+)$/\1/p' \
            "$p"
    )
done

# ============================================================
# 16. 在实际 OpenWrt Linux 6.18 上建立临时 Git 基线
#
# 重要：
#
# 不是拿 Google repo 与 OpenWrt 做 merge-base。
#
# 而是：
#
#   当前 OpenWrt Linux 6.18
#              ↓
#       建立真实基线 commit
#              ↓
#       逐个应用 Google BBR 官方 commit
#              ↓
#       失败立即停止
#
# 这样才能真正检测 6.13.7 → 6.18 的 API/backport 冲突。
# ============================================================

echo
echo "========== 建立 Linux 6.18 backport 基线 =========="

cd "$LINUX_DIR"

if [ -e .git ]; then
    echo "错误：Linux 源码目录已经存在 .git"
    echo "为避免污染已有 Git 仓库，停止。"
    exit 1
fi

git init -q .

git config user.name "OpenWrt Google BBRv3 Backport"
git config user.email "bbrv3-backport@localhost"

git add -A

git commit \
    -q \
    -m "OpenWrt Linux ${LINUX_VERSION} BBRv3 backport base"

OPENWRT_BASE="$(git rev-parse HEAD)"

echo "OpenWrt Linux 基线：$OPENWRT_BASE"

# ============================================================
# 17. 把 Google BBR 官方对象放入当前 kernel Git 对象库
#
# 这样 git am --3way 才能找到官方 patch 所记录的
# 原始 blob。
# ============================================================

echo
echo "========== 导入 Google BBR 官方 Git 对象 =========="

git remote add google-bbr "$BBR_REPO"

git fetch \
    --no-tags \
    --depth=128 \
    google-bbr \
    "$BBR_HEAD"

# ============================================================
# 18. 再次确认 Google BBR 基线对象存在
# ============================================================

git cat-file -e \
    "${BBR_BASE}^{commit}" 2>/dev/null || {

    echo "错误：当前 kernel Git 对象库中没有 Google BBR 基线"
    echo "无法进行可靠 3-way backport"
    exit 1
}

# ============================================================
# 19. 逐个应用官方 Google BBR kernel patch
#
# 绝不自动解决冲突。
#
# 如果某个 commit：
#   - 与 Linux 6.18 API 不兼容
#   - 上游已经发生结构变化
#   - OpenWrt patch 改变了上下文
#   - 需要人工语义调整
#
# 就直接失败。
#
# 这比“强行成功但代码错误”安全得多。
# ============================================================

echo
echo "========== 开始 Google BBR → Linux 6.18 backport =========="

PATCH_NO=0

for PATCH in "$SERIES_DIR"/*.patch; do

    PATCH_NO=$((PATCH_NO + 1))

    echo
    echo "------------------------------------------------------------"
    echo "应用 [$PATCH_NO/$PATCH_COUNT]"
    echo "文件：$(basename "$PATCH")"
    echo "------------------------------------------------------------"

    if ! git am \
        --3way \
        --no-verify \
        "$PATCH"; then

        echo
        echo "============================================================"
        echo "错误：Google BBR patch 无法安全 backport 到 Linux 6.18"
        echo "============================================================"
        echo
        echo "失败补丁：$PATCH"
        echo
        echo "当前 patch："
        git am --show-current-patch=diff || true
        echo
        echo "不会自动猜测或强行解决冲突。"
        echo "这是故意的 fail-closed 行为。"
        echo

        git am --abort || true

        exit 1
    fi
done

# ============================================================
# 20. 检查 Git 状态
# ============================================================

if ! git diff --quiet; then
    echo "错误：BBRv3 backport 后工作区仍有未提交修改"
    exit 1
fi

# ============================================================
# 21. 生成最终 OpenWrt 单 patch
#
# 这里不是直接使用 Google 原始 patch。
#
# 而是：
#
#   OpenWrt Linux 6.18
#          ↓
#   Google 官方 BBRv3 commits
#          ↓
#   已经成功 rebase 到 6.18
#          ↓
#   生成适用于当前 OpenWrt 的最终 patch
#
# 这是整个脚本最重要的一步。
# ============================================================

FINAL_PATCH_DIR="$OLDPWD/target/linux/generic/pending-${KERNEL_PATCHVER}"

mkdir -p "$FINAL_PATCH_DIR"

FINAL_PATCH="$FINAL_PATCH_DIR/999-bbrv3-google.patch"

rm -f \
    "$FINAL_PATCH_DIR"/999-bbrv3-google.patch \
    "$FINAL_PATCH_DIR"/999-bbrv3-google-*.patch

echo
echo "========== 生成最终 OpenWrt BBRv3 patch =========="

git diff \
    --binary \
    "$OPENWRT_BASE" \
    HEAD \
    -- \
    include \
    net \
    ':(exclude)net/ipv4/tcp_bbr1.c' \
    > "$FINAL_PATCH"

[ -s "$FINAL_PATCH" ] || {
    echo "错误：最终 BBRv3 patch 为空"
    exit 1
}

# ============================================================
# 22. 严格检查最终 patch 路径
# ============================================================

echo
echo "========== 检查最终 patch =========="

while read -r path; do

    [ -z "$path" ] && continue

    case "$path" in
        include/*|net/*)
            ;;
        *)
            echo "错误：最终 BBRv3 patch 出现非法路径"
            echo "路径：$path"
            exit 1
            ;;
    esac

    case "$path" in
        net/ipv4/tcp_bbr1.c)
            echo "错误：最终 patch 不允许包含 tcp_bbr1.c"
            exit 1
            ;;
    esac

done < <(
    git diff \
        --name-only \
        "$OPENWRT_BASE" \
        HEAD \
        -- \
        include \
        net
)

# ============================================================
# 23. 检查最终 patch 是否包含 BBRv3 核心标识
# ============================================================

grep -q \
    '^+#define BBR_VERSION[[:space:]]*3' \
    "$FINAL_PATCH" || {

    echo "错误：最终 patch 没有检测到 BBR_VERSION 3"
    exit 1
}

# ============================================================
# 24. 检查 BBRv3 核心字段
# ============================================================

for marker in \
    'bw_lo' \
    'bw_hi' \
    'inflight_lo' \
    'inflight_hi' \
    'BBR_BW_PROBE_UP' \
    'BBR_BW_PROBE_DOWN' \
    'BBR_BW_PROBE_CRUISE' \
    'BBR_BW_PROBE_REFILL' \
    'bbr_ecn_alpha_gain'
do

    grep -q "$marker" "$FINAL_PATCH" || {
        echo "错误：最终 BBRv3 patch 缺少核心标识：$marker"
        exit 1
    }

done

# ============================================================
# 25. 删除当前 Git 仓库
#
# 后面 make target/linux/clean 会重新生成 kernel source。
# 这里先主动删除，避免 .git 被后续 OpenWrt 构建系统带走。
# ============================================================

cd "$OLDPWD"

rm -rf "$LINUX_DIR/.git"

# ============================================================
# 26. 重新 clean
#
# 目的是确保下面的 prepare 真正从 OpenWrt kernel source
# + 999-bbrv3-google.patch 重新构建，而不是使用刚才
# Git backport 后的工作树。
# ============================================================

echo
echo "========== 清理临时 kernel source =========="

make target/linux/clean

# ============================================================
# 27. 重新 prepare
#
# 现在 OpenWrt 会正式按照：
#
#   generic/backport-6.18
#   generic/pending-6.18
#   ...
#   999-bbrv3-google.patch
#
# 重新应用全部 patch。
# ============================================================

echo
echo "========== 重新应用 OpenWrt BBRv3 patch =========="

make target/linux/prepare -j1 V=s

# ============================================================
# 28. 重新定位 kernel source
# ============================================================

LINUX_DIR="$(
    find build_dir/target-* \
        -maxdepth 4 \
        -type f \
        -path '*/linux-6.18*/Makefile' \
        -print 2>/dev/null |
    while read -r f; do
        d="${f%/Makefile}"

        if grep -q '^VERSION = 6$' "$f" &&
           grep -q '^PATCHLEVEL = 18$' "$f"; then
            echo "$d"
            break
        fi
    done
)"

[ -n "$LINUX_DIR" ] || {
    echo "错误：重新 prepare 后无法找到 Linux 6.18"
    exit 1
}

# ============================================================
# 29. 最终源码验证
# ============================================================

BBR_SOURCE="$LINUX_DIR/net/ipv4/tcp_bbr.c"

[ -f "$BBR_SOURCE" ] || {
    echo "错误：找不到 tcp_bbr.c"
    exit 1
}

echo
echo "========== 最终 BBRv3 源码检查 =========="

grep -q \
    '^#define BBR_VERSION[[:space:]]*3' \
    "$BBR_SOURCE" || {

    echo "错误：最终 Linux 源码不是 BBRv3"
    exit 1
}

for marker in \
    'bw_lo' \
    'bw_hi' \
    'inflight_lo' \
    'inflight_hi' \
    'BBR_BW_PROBE_UP' \
    'BBR_BW_PROBE_DOWN' \
    'BBR_BW_PROBE_CRUISE' \
    'BBR_BW_PROBE_REFILL' \
    'bbr_ecn_alpha_gain'
do

    grep -q "$marker" "$BBR_SOURCE" || {
        echo "错误：最终 tcp_bbr.c 缺少：$marker"
        exit 1
    }

done

# ============================================================
# 30. 检查没有引入 BBR1 测试副本
# ============================================================

if [ -e "$LINUX_DIR/net/ipv4/tcp_bbr1.c" ]; then
    echo "错误：发现 tcp_bbr1.c"
    echo "本项目不允许把 Google BBR1 测试副本加入 H68K kernel"
    exit 1
fi

# ============================================================
# 31. 显示最终 BBR 版本
# ============================================================

echo
echo "BBR version："
grep \
    '^#define BBR_VERSION' \
    "$BBR_SOURCE"

# ============================================================
# 32. 最终 kernel 编译验证
#
# 只验证 kernel。
# 后面的主 workflow 仍然会进行完整 OpenWrt 编译。
# ============================================================

echo
echo "============================================================"
echo " 开始 Linux 6.18 + Google BBRv3 kernel compile"
echo "============================================================"
echo

make target/linux/compile -j1 V=s

# ============================================================
# 33. 最终结果
# ============================================================

echo
echo "============================================================"
echo " Google BBRv3 backport 成功"
echo "============================================================"
echo
echo "目标      : HINLINK H68K"
echo "OpenWrt   : Mainline"
echo "Kernel    : Linux 6.18"
echo "BBR       : Google TCP BBRv3"
echo "BBR base  : Linux 6.13.7"
echo "BBR final : Google official v3"
echo
echo "OpenWrt patch："
echo "$FINAL_PATCH"
echo
echo "Kernel source："
echo "$LINUX_DIR"
echo
echo "============================================================"
echo " public1.sh OK"
echo "============================================================"
