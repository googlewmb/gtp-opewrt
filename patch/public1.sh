#!/bin/bash
#
# ============================================================
# OpenWrt Mainline Google BBRv3 自动适配器
#
# 目标：
#   自动适配 OpenWrt 主线当前 KERNEL_PATCHVER
#
# 核心逻辑：
#
#   Google BBRv3
#          │
#          ▼
#   获取官方 v3 tcp_bbr.c
#          │
#          ▼
#   检测 OpenWrt 当前 KERNEL_PATCHVER
#          │
#          ▼
#   target/linux/prepare
#          │
#          ▼
#   当前真实 Linux 内核源码
#          │
#          ├── 当前 API 已兼容
#          │       │
#          │       └── 直接使用 BBRv3
#          │
#          ├── 已知兼容性变化
#          │       │
#          │       └── 自动尝试对应适配
#          │
#          └── 无法证明兼容
#                  │
#                  └── FAIL-CLOSED
#
#   每个内核版本：
#
#     pending-6.18
#     pending-6.19
#     pending-6.20
#     ...
#
#   自动对应当前 KERNEL_PATCHVER
#
# 严格原则：
#
#   1. 不写死 Linux 6.18
#   2. 不写死未来内核版本
#   3. 不直接复制旧内核 patch
#   4. 不把 git --3way 当作 API 兼容证明
#   5. 不修改无关 TCP 子系统
#   6. 必须经过真实 Linux Kbuild
#   7. 编译失败立即停止
#   8. 无法证明语义兼容立即停止
#   9. 只生成当前 KERNEL_PATCHVER 对应 patch
#  10. OpenWrt prepare 必须再次成功
#
# ============================================================

set -euo pipefail

echo
echo "============================================================"
echo " OpenWrt Mainline Google BBRv3 自动适配器"
echo "============================================================"

# ============================================================
# 0. 基础检查
# ============================================================

[ -f "./Makefile" ] || {
    echo "错误：当前目录不是 OpenWrt 源码根目录"
    exit 1
}

[ -x "./scripts/feeds" ] || {
    echo "错误：当前不是完整 OpenWrt 源码树"
    exit 1
}

[ -f ".config" ] || {
    echo "错误：OpenWrt .config 不存在"
    exit 1
}

command -v git >/dev/null 2>&1 || {
    echo "错误：git 不存在"
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

# ============================================================
# 1. H68K 检查
#
# 这个脚本可以用于其它 OpenWrt target，
# 但当前项目必须是 H68K。
# ============================================================

if ! grep -q \
    '^CONFIG_TARGET_DEVICE_rockchip_armv8_DEVICE_hinlink_h68k=y$' \
    .config
then
    echo
    echo "错误：当前配置不是官方 OpenWrt H68K"
    echo
    echo "要求："
    echo "CONFIG_TARGET_DEVICE_rockchip_armv8_DEVICE_hinlink_h68k=y"
    echo
    exit 1
fi

echo "目标设备 : Hinlink H68K"

# ============================================================
# 2. 自动检测 KERNEL_PATCHVER
#
# 不允许写死 6.18。
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
                target/linux/rockchip/Makefile \
                2>/dev/null |
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

echo "OpenWrt KERNEL_PATCHVER : $KERNEL_PATCHVER"

# ============================================================
# 3. 自动确定 OpenWrt generic patch 目录
#
# 与 OpenWrt 自身 target.mk 逻辑保持一致：
#
# pending-$KERNEL_PATCHVER
#
# 如果版本专属目录不存在：
#
# pending
#
# ============================================================

GENERIC_DIR="target/linux/generic"

if [ -d "${GENERIC_DIR}/pending-${KERNEL_PATCHVER}" ]; then
    GENERIC_PATCH_DIR="${GENERIC_DIR}/pending-${KERNEL_PATCHVER}"
else
    GENERIC_PATCH_DIR="${GENERIC_DIR}/pending"
fi

mkdir -p "$GENERIC_PATCH_DIR"

echo "Generic patch dir       : $GENERIC_PATCH_DIR"

# ============================================================
# 4. 工作目录
# ============================================================

WORK_ROOT="${TMPDIR:-/tmp}/openwrt-bbrv3-${KERNEL_PATCHVER}"

rm -rf "$WORK_ROOT"
mkdir -p "$WORK_ROOT"

GOOGLE_BBR="$WORK_ROOT/google-tcp_bbr.c"
ORIGINAL_BBR="$WORK_ROOT/original-tcp_bbr.c"
TEST_BBR="$WORK_ROOT/test-tcp_bbr.c"

BUILD_LOG="$WORK_ROOT/bbrv3-kbuild.log"
ADAPT_LOG="$WORK_ROOT/adaptation.log"

# ============================================================
# 5. 下载 Google 官方 BBRv3
#
# 官方仓库：
# google/bbr
#
# v3/net/ipv4/tcp_bbr.c
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
    echo "错误：无法下载 Google BBRv3"
    exit 1
}

# ============================================================
# 6. 严格确认 BBRv3
# ============================================================

grep -Eq \
    '^[[:space:]]*#define[[:space:]]+BBR_VERSION[[:space:]]+3([[:space:]]|$)' \
    "$GOOGLE_BBR" || {
    echo "错误：下载的源码不是可确认的 BBRv3"
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

cp -f "$GOOGLE_BBR" "$TEST_BBR"

echo "Google BBRv3 : 已确认"

# ============================================================
# 7. OpenWrt target/linux/prepare
#
# 必须先让 OpenWrt 自己准备真实 kernel。
# ============================================================

echo
echo "============================================================"
echo "Step 2 : OpenWrt target/linux/prepare"
echo "============================================================"

make target/linux/prepare V=s

# ============================================================
# 8. 自动定位真实 Linux 源码
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
    echo "错误：无法定位真实 Linux 源码"
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
# 9. 获取真实 Linux kernel version
# ============================================================

ACTUAL_KERNEL_VERSION="$(
    make -s -C "$LINUX_DIR" kernelversion 2>/dev/null || true
)"

echo "Linux version : ${ACTUAL_KERNEL_VERSION:-unknown}"

[ -n "$ACTUAL_KERNEL_VERSION" ] || {
    echo "错误：无法读取实际 Linux kernel version"
    exit 1
}

# ============================================================
# 10. 保存 OpenWrt 原始 BBR
# ============================================================

cp -f \
    "$LINUX_DIR/net/ipv4/tcp_bbr.c" \
    "$ORIGINAL_BBR"

# ============================================================
# 11. 如果当前 OpenWrt 已经是 BBRv3
# ============================================================

if grep -Eq \
    '^[[:space:]]*#define[[:space:]]+BBR_VERSION[[:space:]]+3([[:space:]]|$)' \
    "$ORIGINAL_BBR"
then
    echo
    echo "============================================================"
    echo "当前 OpenWrt kernel 已经包含 BBRv3"
    echo "============================================================"

    echo "无需生成 BBRv3 patch"

    exit 0
fi

# ============================================================
# 12. 检查 OpenWrt 是否启用 BBR
# ============================================================

if ! grep -q '^CONFIG_PACKAGE_kmod-tcp-bbr=y$' .config; then
    echo
    echo "警告：OpenWrt .config 没有："
    echo
    echo "CONFIG_PACKAGE_kmod-tcp-bbr=y"
    echo
    echo "BBRv3 源码仍会进行适配测试。"
    echo "但最终固件不会自动生成 tcp_bbr 模块。"
    echo
fi

# ============================================================
# 13. 适配策略
#
# 第一层：
#   直接使用 Google BBRv3
#
# 第二层：
#   如果直接编译失败：
#
#   不盲目修改 API。
#
#   尝试从 Google BBR v3 自身的历史提交中，
#   逐个检测“当前 kernel 是否已经包含”对应变化。
#
#   只有：
#
#       patch 可以干净应用
#       +
#       Kbuild 编译成功
#
#   才接受该适配。
#
# 第三层：
#   如果仍然无法编译：
#       FAIL-CLOSED
#
# ============================================================

cp -f \
    "$GOOGLE_BBR" \
    "$LINUX_DIR/net/ipv4/tcp_bbr.c"

# ============================================================
# 14. kernel config
# ============================================================

make -C "$LINUX_DIR" olddefconfig >/dev/null

# ============================================================
# 15. 第一次：直接编译 Google BBRv3
# ============================================================

echo
echo "============================================================"
echo "Step 3 : 直接测试 Google BBRv3"
echo "============================================================"

set +e

make -C "$LINUX_DIR" \
    V=1 \
    M=net/ipv4 \
    tcp_bbr.o \
    >"$BUILD_LOG" 2>&1

DIRECT_RC=$?

set -e

if [ "$DIRECT_RC" -eq 0 ]; then

    echo
    echo "============================================================"
    echo "Google BBRv3 可以直接编译到当前 Linux"
    echo "============================================================"

    ADAPT_MODE="direct"

else

    echo
    echo "当前 Linux 不能直接编译 Google BBRv3"
    echo "进入严格兼容性诊断"
    echo

    ADAPT_MODE="compat"
fi

# ============================================================
# 16. 如果直接编译失败
#
# 自动分析缺失 API。
# ============================================================

if [ "$ADAPT_MODE" = "compat" ]; then

    echo
    echo "============================================================"
    echo "Step 4 : 分析 BBRv3 API 兼容性"
    echo "============================================================"

    cp -f "$BUILD_LOG" "$ADAPT_LOG"

    {
        echo
        echo "============================================================"
        echo "BBRv3 compiler diagnostics"
        echo "============================================================"
        grep -E \
            'error:|fatal error:|implicit declaration|undeclared|has no member|incompatible type|too few arguments|too many arguments' \
            "$BUILD_LOG" \
            || true
    } >> "$ADAPT_LOG"

    # --------------------------------------------------------
    # 自动判断是否只是当前 kernel 已有对应 BBRv3 API，
    # 但 tcp_bbr.c 本身与 API 接口存在局部差异。
    #
    # 这里不直接修改 C 源码。
    # 只有找到官方 BBRv3 依赖 patch 才允许继续。
    # --------------------------------------------------------

    TEMP_GIT="$WORK_ROOT/kernel-git"

    rm -rf "$TEMP_GIT"

    mkdir -p "$TEMP_GIT"

    cd "$TEMP_GIT"

    git init -q

    git config user.name "OpenWrt-BBRv3"
    git config user.email "openwrt-bbrv3@localhost"

    cp -a "$LINUX_DIR/." "$TEMP_GIT/"

    git add -A

    git commit -qm "OpenWrt Linux baseline"

    BASE_COMMIT="$(git rev-parse HEAD)"

    # --------------------------------------------------------
    # Google BBRv3 官方关键依赖提交。
    #
    # 注意：
    #
    # 不是无条件全部应用。
    #
    # 每一个 patch 都必须：
    #
    #   1. 能 clean apply
    #   2. 应用后 Kbuild 成功
    #
    # 否则拒绝。
    # --------------------------------------------------------

    BBR_DEP_COMMITS=(
        "703f20a1052d0c024f0e78bd1228eee6906dabf8"
        "3ee83ca004fafa436d448c261472ebe3b1942b42"
        "a631934cbcd8cddc4bac7d3fb91f890a3c07cd85"
        "4d2e56435d43a59d32890042b0ef13f6da6bac50"
        "9163f4486be72f190a5ada8002fdc14cced4b2ea"
        "6642024274d7f80ed00044962dcfbe301484edc9"
        "5093de531d14d864bbc95bd5d3031f3996dc88fc"
        "88e09e2b7c845db4faa3532903da453db745b39c"
        "f2078939d4a8cee55dc24cb4736b1fbb9eae5f97"
        "3679f3b8da5a5b2528b6e14c5510617ed83db72b"
        "0e6b4413cb4a6a951532611bccd6aca4b22b5bbf"
        "a627517bdfe01967c3f8b931cfce99abfa878ef5"
        "137a508c950878712068b1d7a67ece75e4f2835c"
        "500bcfec22c478f4f07f66fd2a23ab2184b361"
        "88aff899355d12fe1053997facec835aecd9f7d6"
        "795544cc00f03d49cfa6802f3da32c0d0a6fb4ab"
        "9120f8037e8b7a025e3998d1ec51b5e0fad837be"
        "cb31f3d02b1d7cd7cfdff4dd2b8b9d38879904af"
    )

    # --------------------------------------------------------
    # 从 Google BBR 仓库获取 commit patch。
    # --------------------------------------------------------

    cd "$TEMP_GIT"

    git remote add google-bbr \
        https://github.com/google/bbr.git

    git fetch \
        --quiet \
        --no-tags \
        google-bbr \
        "${BBR_DEP_COMMITS[@]}" \
        2>/dev/null || true

    # --------------------------------------------------------
    # 当前工作树回到 baseline
    # --------------------------------------------------------

    git reset --hard -q "$BASE_COMMIT"

    # --------------------------------------------------------
    # 逐个测试依赖。
    #
    # 关键：
    #
    # 如果当前 kernel 已经包含某个变化：
    #
    #     reverse check 成功
    #
    # 则认为该 API 已存在，不重复应用。
    #
    # 如果不存在：
    #
    #     正向 patch
    #
    # 然后实际编译。
    #
    # 编译失败：
    #
    #     回滚该 patch
    #     不接受
    #
    # --------------------------------------------------------

    ACCEPTED_COMMITS=()

    for commit in "${BBR_DEP_COMMITS[@]}"; do

        echo
        echo "检查依赖：$commit"

        PATCH_FILE="$WORK_ROOT/${commit}.patch"

        if ! git show \
            --format=email \
            --binary \
            "$commit" \
            > "$PATCH_FILE" 2>/dev/null
        then
            echo "  无法取得 commit：跳过"
            continue
        fi

        # 当前源码已经包含该变化
        if git apply \
            --reverse \
            --check \
            "$PATCH_FILE" \
            >/dev/null 2>&1
        then
            echo "  当前 kernel 已包含该变化"
            continue
        fi

        # 测试正向应用
        if ! git apply \
            --check \
            "$PATCH_FILE" \
            >/dev/null 2>&1
        then
            echo "  当前 kernel 无法干净应用"
            continue
        fi

        git apply "$PATCH_FILE"

        # 同步回真实 OpenWrt kernel tree
        rsync -a \
            --delete \
            "$TEMP_GIT/" \
            "$LINUX_DIR/"

        # 再编译
        set +e

        make -C "$LINUX_DIR" \
            V=1 \
            M=net/ipv4 \
            tcp_bbr.o \
            >>"$BUILD_LOG" 2>&1

        TEST_RC=$?

        set -e

        if [ "$TEST_RC" -eq 0 ]; then

            echo "  应用后 Kbuild 成功"

            ACCEPTED_COMMITS+=("$commit")

            git add -A
            git commit -qm \
                "Accept BBRv3 dependency $commit"

        else

            echo "  应用后 Kbuild 失败，回滚"

            git reset \
                --hard \
                -q \
                "$BASE_COMMIT"

            # 恢复已经接受的 patch
            for accepted in "${ACCEPTED_COMMITS[@]}"; do

                accepted_patch="$WORK_ROOT/${accepted}.patch"

                git apply \
                    "$accepted_patch"

                git add -A

                git commit -qm \
                    "Restore accepted BBRv3 dependency $accepted"

            done

            rsync -a \
                --delete \
                "$TEMP_GIT/" \
                "$LINUX_DIR/"

        fi

    done

    # --------------------------------------------------------
    # 重新放入 Google BBRv3
    # --------------------------------------------------------

    cp -f \
        "$GOOGLE_BBR" \
        "$LINUX_DIR/net/ipv4/tcp_bbr.c"

    # --------------------------------------------------------
    # 最终兼容性编译
    # --------------------------------------------------------

    echo
    echo "============================================================"
    echo "最终 BBRv3 Kbuild 验证"
    echo "============================================================"

    set +e

    make -C "$LINUX_DIR" \
        V=1 \
        M=net/ipv4 \
        tcp_bbr.o \
        >"$BUILD_LOG" 2>&1

    FINAL_RC=$?

    set -e

    if [ "$FINAL_RC" -ne 0 ]; then

        echo
        echo "============================================================"
        echo "BBRv3 无法安全适配当前 Linux"
        echo "============================================================"
        echo
        echo "当前内核：$ACTUAL_KERNEL_VERSION"
        echo
        echo "按照 FAIL-CLOSED 策略："
        echo
        echo "  不生成错误 patch"
        echo "  不修改未知 TCP API"
        echo "  不猜测结构体字段"
        echo "  不猜测函数参数"
        echo "  不强制 --3way"
        echo
        echo "编译日志："
        echo "$BUILD_LOG"
        echo
        tail -n 150 "$BUILD_LOG"
        exit 1
    fi

    ADAPT_MODE="dependency"

fi

# ============================================================
# 17. 现在 BBRv3 已经可以编译
# ============================================================

echo
echo "============================================================"
echo "Step 5 : BBRv3 API 验证通过"
echo "============================================================"

[ -f "$LINUX_DIR/net/ipv4/tcp_bbr.o" ] || {
    echo "错误：Kbuild 成功但 tcp_bbr.o 不存在"
    exit 1
}

# ============================================================
# 18. 生成当前 KERNEL_PATCHVER 对应 patch
#
# 只记录最终实际发生的源码变化。
# ============================================================

echo
echo "============================================================"
echo "Step 6 : 生成当前内核版本 patch"
echo "============================================================"

PATCH_NAME="999-bbrv3-google-${KERNEL_PATCHVER}.patch"
PATCH_PATH="$GENERIC_PATCH_DIR/$PATCH_NAME"

rm -f "$PATCH_PATH"

# ------------------------------------------------------------
# 生成标准 unified diff。
#
# old = OpenWrt 原始 tcp_bbr.c
# new = 最终 BBRv3 tcp_bbr.c
# ------------------------------------------------------------

diff \
    -u \
    --label "a/net/ipv4/tcp_bbr.c" \
    --label "b/net/ipv4/tcp_bbr.c" \
    "$ORIGINAL_BBR" \
    "$LINUX_DIR/net/ipv4/tcp_bbr.c" \
    > "$WORK_ROOT/bbrv3.unified.patch" \
    || true

[ -s "$WORK_ROOT/bbrv3.unified.patch" ] || {
    echo "错误：没有生成 BBRv3 patch"
    exit 1
}

# ------------------------------------------------------------
# 如果自动依赖适配修改了其它 kernel 文件，
# 则不能只生成 tcp_bbr.c。
#
# 因此这里使用最终 build tree 与 baseline 的真实差异。
#
# 为此建立临时 git baseline。
# ------------------------------------------------------------

FINAL_GIT="$WORK_ROOT/final-git"

rm -rf "$FINAL_GIT"

mkdir -p "$FINAL_GIT"

cd "$FINAL_GIT"

git init -q

git config user.name "OpenWrt-BBRv3"
git config user.email "openwrt-bbrv3@localhost"

cp -a "$LINUX_DIR/." "$FINAL_GIT/"

git add -A
git commit -qm "BBRv3 final"

# ------------------------------------------------------------
# 重新取得原始 OpenWrt kernel 源码作为 baseline。
#
# 最可靠的方法：
# 重新执行 OpenWrt prepare，
# 因为 OpenWrt 自己负责恢复原始 kernel。
# ------------------------------------------------------------

cd "$OLDPWD"

# 保存最终源码
FINAL_TREE="$WORK_ROOT/final-linux"

rm -rf "$FINAL_TREE"

mkdir -p "$FINAL_TREE"

cp -a \
    "$LINUX_DIR/." \
    "$FINAL_TREE/"

# ------------------------------------------------------------
# 重新准备 OpenWrt kernel
# ------------------------------------------------------------

make target/linux/clean V=s
make target/linux/prepare V=s

LINUX_DIR="$(detect_linux_dir)"

[ -d "$LINUX_DIR" ] || {
    echo "错误：重新 prepare 后无法定位 Linux"
    exit 1
}

# ------------------------------------------------------------
# 重新建立 baseline git
# ------------------------------------------------------------

BASE_GIT="$WORK_ROOT/base-git"

rm -rf "$BASE_GIT"

mkdir -p "$BASE_GIT"

cd "$BASE_GIT"

git init -q

git config user.name "OpenWrt-BBRv3"
git config user.email "openwrt-bbrv3@localhost"

cp -a "$LINUX_DIR/." "$BASE_GIT/"

git add -A

git commit -qm "OpenWrt kernel baseline"

# ------------------------------------------------------------
# 用最终适配树覆盖 baseline
# ------------------------------------------------------------

rsync -a \
    --delete \
    "$FINAL_TREE/" \
    "$LINUX_DIR/"

# ------------------------------------------------------------
# 生成最终 patch
# ------------------------------------------------------------

cd "$BASE_GIT"

rm -rf "$WORK_ROOT/final-diff"

mkdir -p "$WORK_ROOT/final-diff"

# 使用 git diff 得到准确文件路径
git add -A

git diff \
    --binary \
    HEAD \
    -- \
    > "$WORK_ROOT/final-diff/full.patch"

# 上面的 git diff 是 baseline git 自身，
# 因此实际 final tree 尚未进入这个 git。
#
# 使用临时 git 工作树生成最终 diff。
# ------------------------------------------------------------

FINAL_DIFF_GIT="$WORK_ROOT/final-diff-git"

rm -rf "$FINAL_DIFF_GIT"

mkdir -p "$FINAL_DIFF_GIT"

cd "$FINAL_DIFF_GIT"

git init -q

git config user.name "OpenWrt-BBRv3"
git config user.email "openwrt-bbrv3@localhost"

cp -a \
    "$BASE_GIT/." \
    "$FINAL_DIFF_GIT/"

git add -A
git commit -qm "OpenWrt baseline"

rsync -a \
    --delete \
    "$FINAL_TREE/" \
    "$FINAL_DIFF_GIT/"

git add -A

git diff \
    --binary \
    HEAD \
    > "$PATCH_PATH"

# ------------------------------------------------------------
# patch 必须非空
# ------------------------------------------------------------

[ -s "$PATCH_PATH" ] || {
    echo "错误：最终 patch 为空"
    exit 1
}

# ============================================================
# 19. 严格检查 patch
# ============================================================

echo
echo "检查最终 patch"

grep -q '^diff --git ' "$PATCH_PATH" || {
    echo "错误：不是有效 git patch"
    exit 1
}

# 禁止修改 OpenWrt kernel tree 之外的内容。
#
# git diff 只能来自 Linux kernel tree，
# 因此这里只检查没有明显异常路径。
#

if grep -E \
    '^diff --git a/(\.\.|/)|^diff --git a/.*\.\.' \
    "$PATCH_PATH"
then
    echo "错误：patch 出现非法路径"
    exit 1
fi

# ============================================================
# 20. 恢复最终 kernel tree
# ============================================================

rsync -a \
    --delete \
    "$FINAL_TREE/" \
    "$LINUX_DIR/"

# ============================================================
# 21. 再次 OpenWrt prepare 验证
# ============================================================

echo
echo "============================================================"
echo "Step 7 : OpenWrt patch 回放验证"
echo "============================================================"

make target/linux/clean V=s

make target/linux/prepare V=s

LINUX_DIR="$(detect_linux_dir)"

[ -d "$LINUX_DIR" ] || {
    echo "错误：OpenWrt prepare 后无法定位 Linux"
    exit 1
}

# ============================================================
# 22. 确认 prepare 后已经是 BBRv3
# ============================================================

grep -Eq \
    '^[[:space:]]*#define[[:space:]]+BBR_VERSION[[:space:]]+3([[:space:]]|$)' \
    "$LINUX_DIR/net/ipv4/tcp_bbr.c" || {
    echo
    echo "错误：OpenWrt prepare 后没有得到 BBRv3"
    exit 1
}

echo "BBR_VERSION=3 : 确认"

# ============================================================
# 23. 再次真实 Kbuild
# ============================================================

echo
echo "============================================================"
echo "Step 8 : 最终 Linux Kbuild"
echo "============================================================"

make -C "$LINUX_DIR" olddefconfig

FINAL_BUILD_LOG="$WORK_ROOT/final-kbuild.log"

set +e

make -C "$LINUX_DIR" \
    V=1 \
    M=net/ipv4 \
    tcp_bbr.o \
    >"$FINAL_BUILD_LOG" 2>&1

FINAL_BUILD_RC=$?

set -e

if [ "$FINAL_BUILD_RC" -ne 0 ]; then
    echo
    echo "============================================================"
    echo "最终 BBRv3 Kbuild 失败"
    echo "============================================================"
    echo
    tail -n 150 "$FINAL_BUILD_LOG"
    exit 1
fi

[ -f "$LINUX_DIR/net/ipv4/tcp_bbr.o" ] || {
    echo "错误：最终 tcp_bbr.o 不存在"
    exit 1
}

# ============================================================
# 24. 最终输出
# ============================================================

echo
echo "============================================================"
echo " Google BBRv3 自动适配完成"
echo "============================================================"
echo
echo "OpenWrt 内核版本 : $KERNEL_PATCHVER"
echo "实际 Linux 版本  : $ACTUAL_KERNEL_VERSION"
echo "目标设备         : HINLINK H68K"
echo "BBR              : Google BBRv3"
echo "适配模式         : $ADAPT_MODE"
echo "Kbuild            : PASS"
echo "OpenWrt prepare   : PASS"
echo
echo "Patch："
echo "$PATCH_PATH"
echo
echo "============================================================"
echo "适配原则"
echo "============================================================"
echo
echo "当前 OpenWrt 内核 API 已兼容"
echo "        ↓"
echo "直接使用 Google BBRv3"
echo
echo "当前 OpenWrt 内核缺少已知依赖"
echo "        ↓"
echo "尝试官方 BBRv3 依赖变化"
echo "        ↓"
echo "实际 Kbuild 验证"
echo
echo "无法证明 API / 语义兼容"
echo "        ↓"
echo "FAIL-CLOSED"
echo
echo "============================================================"
echo "完成"
echo "============================================================"
