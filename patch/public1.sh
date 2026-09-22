#!/bin/bash
#
# ============================================================
# public1.sh
#
# OpenWrt 官方主线 BBRv3 补丁
#
# 来源：
#   QiuSimons/YAOF 25.12
#
# 适用：
#   - OpenWrt 官方主线
#   - ARM64 / H68K
#   - OpenWrt 25.12
#   - 当前使用 generic backport 内核的版本
#
# 功能：
#   1. 自动检测 OpenWrt 当前 KERNEL_PATCHVER
#   2. 自动定位对应 target/linux/generic/backport-*
#   3. 安装 YAOF BBRv3 0001~0018
#   4. 排除 0019 x86 CFI/BPF 专用补丁
#   5. 确保 CONFIG_TCP_CONG_BBR=y
#   6. 确保 CONFIG_NET_SCH_FQ=y
#   7. 确保默认 TCP 拥塞控制为 bbr
#
# 注意：
#   YAOF BBRv3 不是 CONFIG_TCP_CONG_BBR3。
#   它更新的是 Linux 原有的 BBR 模块：
#
#       CONFIG_TCP_CONG_BBR
#              ↓
#       net/ipv4/tcp_bbr.c
#              ↓
#       BBRv3
#
# 运行时仍然：
#
#       net.ipv4.tcp_congestion_control=bbr
#
# ============================================================

set -e

echo ""
echo "============================================================"
echo " OpenWrt BBRv3 Patch"
echo "============================================================"
echo " Source : QiuSimons/YAOF"
echo " Branch : 25.12"
echo " Target : ARM64 / H68K"
echo "============================================================"
echo ""

# ============================================================
# 1. 检查 OpenWrt 源码根目录
# ============================================================

if [ ! -d "target/linux" ]; then
	echo "ERROR: 当前目录不是 OpenWrt 源码根目录"
	exit 1
fi

if [ ! -f "target/linux/generic/Makefile" ]; then
	echo "ERROR: 找不到 target/linux/generic/Makefile"
	exit 1
fi

# ============================================================
# 2. BBRv3 来源
# ============================================================

BBR3_REPO="https://raw.githubusercontent.com/QiuSimons/YAOF/25.12/PATCH/kernel/bbr3"

# ============================================================
# 3. 自动检测 OpenWrt 当前内核版本
# ============================================================

KERNEL_PATCHVER="$(
	grep -E '^[[:space:]]*KERNEL_PATCHVER[[:space:]]*[:?+]?=' \
		target/linux/generic/Makefile \
		| head -n 1 \
		| sed -E 's/.*=[[:space:]]*//'
)"

if [ -z "$KERNEL_PATCHVER" ]; then
	echo "ERROR: 无法检测 KERNEL_PATCHVER"
	exit 1
fi

echo "检测到 OpenWrt 内核版本：$KERNEL_PATCHVER"

# ============================================================
# 4. 定位对应 backport 目录
# ============================================================

BACKPORT_DIR="target/linux/generic/backport-${KERNEL_PATCHVER}"

if [ ! -d "$BACKPORT_DIR" ]; then
	echo ""
	echo "ERROR: 找不到对应 backport 目录："
	echo "  $BACKPORT_DIR"
	echo ""
	echo "当前 OpenWrt generic 目录中的 backport："

	find target/linux/generic \
		-maxdepth 1 \
		-type d \
		-name 'backport-*' \
		-print \
		| sort || true

	exit 1
fi

echo "BBRv3 补丁目录：$BACKPORT_DIR"

# ============================================================
# 5. BBRv3 补丁列表
#
# YAOF 25.12 实际包含：
#
#   0001 ~ 0018
#
# 0019：
#   x86 CFI/BPF 专用
#   ARM64 / H68K 不使用
# ============================================================

PATCH_LIST="
010-0001-net-tcp_bbr-broaden-app-limited-rate-sample-detectio.patch
010-0002-net-tcp_bbr-v2-shrink-delivered_mstamp-first_tx_msta.patch
010-0003-net-tcp_bbr-v2-snapshot-packets-in-flight-at-transmi.patch
010-0004-net-tcp_bbr-v2-count-packets-lost-over-TCP-rate-samp.patch
010-0005-net-tcp_bbr-v2-export-FLAG_ECE-in-rate_sample.is_ece.patch
010-0006-net-tcp_bbr-v2-introduce-ca_ops-skb_marked_lost-CC-m.patch
010-0007-net-tcp_bbr-v2-adjust-skb-tx.in_flight-upon-merge-in.patch
010-0008-net-tcp_bbr-v2-adjust-skb-tx.in_flight-upon-split-in.patch
010-0009-net-tcp-add-new-ca-opts-flag-TCP_CONG_WANTS_CE_EVENT.patch
010-0010-net-tcp-re-generalize-TSO-sizing-in-TCP-CC-module-AP.patch
010-0011-net-tcp-add-fast_ack_mode-1-skip-rwin-check-in-tcp_f.patch
010-0012-net-tcp_bbr-v2-record-app-limited-status-of-TLP-repa.patch
010-0013-net-tcp_bbr-v2-inform-CC-module-of-losses-repaired-b.patch
010-0014-net-tcp_bbr-v2-introduce-is_acking_tlp_retrans_seq-i.patch
010-0015-tcp-introduce-per-route-feature-RTAX_FEATURE_ECN_LOW.patch
010-0016-net-tcp_bbr-v3-update-TCP-bbr-congestion-control-mod.patch
010-0017-net-tcp_bbr-v3-ensure-ECN-enabled-BBR-flows-set-ECT-.patch
010-0018-tcp-export-TCPI_OPT_ECN_LOW-in-tcp_info-tcpi_options.patch
"

# ============================================================
# 6. 清理错误的 BBR3 补丁
#
# 防止以前脚本错误加入：
#   0019 x86 专用补丁
#
# ============================================================

rm -f \
	"$BACKPORT_DIR/010-0019-x86-cfi-bpf-Add-tso_segs-and-skb_marked_lost-to-bpf_.patch"

# ============================================================
# 7. 下载 BBRv3 补丁
# ============================================================

echo ""
echo "============================================================"
echo "开始安装 BBRv3 补丁"
echo "============================================================"

PATCH_COUNT=0

for PATCH in $PATCH_LIST; do

	TARGET="$BACKPORT_DIR/$PATCH"
	URL="$BBR3_REPO/$PATCH"

	PATCH_COUNT=$((PATCH_COUNT + 1))

	echo ""
	echo "[$PATCH_COUNT/18]"
	echo "  $PATCH"

	# --------------------------------------------------------
	# 已存在则验证，不盲目覆盖
	# --------------------------------------------------------

	if [ -f "$TARGET" ] && [ -s "$TARGET" ]; then

		echo "  已存在，检查文件..."

		if grep -q '^Subject:.*BBR' "$TARGET"; then
			echo "  OK：补丁有效"
			continue
		fi

		echo "  警告：现有文件异常，重新下载"
		rm -f "$TARGET"
	fi

	# --------------------------------------------------------
	# 下载
	# --------------------------------------------------------

	TMP_FILE="${TARGET}.tmp"

	rm -f "$TMP_FILE"

	curl -fL \
		--retry 5 \
		--retry-delay 2 \
		--connect-timeout 20 \
		--max-time 300 \
		"$URL" \
		-o "$TMP_FILE"

	# --------------------------------------------------------
	# 基本完整性检查
	# --------------------------------------------------------

	if [ ! -s "$TMP_FILE" ]; then
		echo "ERROR: 下载文件为空：$PATCH"
		rm -f "$TMP_FILE"
		exit 1
	fi

	# GitHub 404/错误页面不能作为补丁
	if ! grep -q '^From ' "$TMP_FILE"; then
		echo "ERROR: 文件不是有效 Git Patch：$PATCH"
		rm -f "$TMP_FILE"
		exit 1
	fi

	if ! grep -q '^Subject:' "$TMP_FILE"; then
		echo "ERROR: Patch 缺少 Subject：$PATCH"
		rm -f "$TMP_FILE"
		exit 1
	fi

	mv "$TMP_FILE" "$TARGET"

	echo "  OK：安装完成"

done

# ============================================================
# 8. 检查 18 个补丁是否全部存在
# ============================================================

echo ""
echo "============================================================"
echo "检查 BBRv3 补丁完整性"
echo "============================================================"

MISSING=0

for PATCH in $PATCH_LIST; do

	if [ ! -s "$BACKPORT_DIR/$PATCH" ]; then
		echo "缺少：$PATCH"
		MISSING=$((MISSING + 1))
	fi

done

if [ "$MISSING" -ne 0 ]; then
	echo ""
	echo "ERROR: 缺少 $MISSING 个 BBRv3 补丁"
	exit 1
fi

echo "OK：BBRv3 18 个补丁全部存在"

# ============================================================
# 9. 删除 0019 x86 专用补丁
# ============================================================

if find "$BACKPORT_DIR" \
	-maxdepth 1 \
	-type f \
	-name '*0019*x86*cfi*bpf*.patch' \
	-print \
	| grep -q .; then

	echo ""
	echo "删除 x86 专用 BBRv3 0019 补丁"

	find "$BACKPORT_DIR" \
		-maxdepth 1 \
		-type f \
		-name '*0019*x86*cfi*bpf*.patch' \
		-delete

fi

# ============================================================
# 10. 自动确定 OpenWrt generic kernel config 文件
# ============================================================

CONFIG_FILE=""

if [ -f "target/linux/generic/config-${KERNEL_PATCHVER}" ]; then
	CONFIG_FILE="target/linux/generic/config-${KERNEL_PATCHVER}"
elif [ -f "target/linux/generic/config-${KERNEL_PATCHVER%%.*}" ]; then
	CONFIG_FILE="target/linux/generic/config-${KERNEL_PATCHVER%%.*}"
fi

# ============================================================
# 11. 如果存在 generic kernel config
#     自动启用 BBR
# ============================================================

if [ -n "$CONFIG_FILE" ]; then

	echo ""
	echo "============================================================"
	echo "配置 BBR"
	echo "============================================================"

	echo "Config：$CONFIG_FILE"

	# --------------------------------------------------------
	# CONFIG_TCP_CONG_BBR
	# --------------------------------------------------------

	if grep -q '^CONFIG_TCP_CONG_BBR=' "$CONFIG_FILE"; then

		sed -i \
			's/^CONFIG_TCP_CONG_BBR=.*/CONFIG_TCP_CONG_BBR=y/' \
			"$CONFIG_FILE"

	else

		printf '%s\n' \
			'CONFIG_TCP_CONG_BBR=y' \
			>> "$CONFIG_FILE"

	fi

	# --------------------------------------------------------
	# CONFIG_NET_SCH_FQ
	# --------------------------------------------------------

	if grep -q '^CONFIG_NET_SCH_FQ=' "$CONFIG_FILE"; then

		sed -i \
			's/^CONFIG_NET_SCH_FQ=.*/CONFIG_NET_SCH_FQ=y/' \
			"$CONFIG_FILE"

	else

		printf '%s\n' \
			'CONFIG_NET_SCH_FQ=y' \
			>> "$CONFIG_FILE"

	fi

	# --------------------------------------------------------
	# DEFAULT BBR
	#
	# OpenWrt / Linux 不同版本的 Kconfig 可能存在：
	#
	#   CONFIG_DEFAULT_BBR
	#
	# 也可能由：
	#
	#   CONFIG_DEFAULT_TCP_CONG
	#
	# 控制。
	#
	# 因此这里只处理已经存在的 CONFIG_DEFAULT_BBR，
	# 不人为创建未知 Kconfig。
	# --------------------------------------------------------

	if grep -q '^CONFIG_DEFAULT_BBR=' "$CONFIG_FILE"; then

		sed -i \
			's/^CONFIG_DEFAULT_BBR=.*/CONFIG_DEFAULT_BBR=y/' \
			"$CONFIG_FILE"

	fi

	echo ""
	echo "BBR kernel config："

	grep -E \
		'^CONFIG_TCP_CONG_BBR=|^CONFIG_NET_SCH_FQ=|^CONFIG_DEFAULT_BBR=' \
		"$CONFIG_FILE" \
		|| true

else

	echo ""
	echo "注意："
	echo "没有找到 generic kernel config 文件。"
	echo "不强行创建未知 config 文件。"
	echo ""
	echo "BBRv3 源码补丁仍然已经安装。"
	echo "OpenWrt 构建时请确保 CONFIG_TCP_CONG_BBR=y。"

fi

# ============================================================
# 12. 检查补丁是否包含真正的 BBRv3 核心
# ============================================================

BBR_CORE="$BACKPORT_DIR/010-0016-net-tcp_bbr-v3-update-TCP-bbr-congestion-control-mod.patch"

if [ ! -f "$BBR_CORE" ]; then
	echo "ERROR: BBRv3 核心补丁不存在"
	exit 1
fi

if ! grep -q 'BBRv3' "$BBR_CORE"; then
	echo "ERROR: BBRv3 核心补丁内容异常"
	exit 1
fi

if ! grep -q 'CONFIG_TCP_CONG_BBR' "$BBR_CORE"; then
	echo "ERROR: BBRv3 核心补丁没有找到 CONFIG_TCP_CONG_BBR"
	exit 1
fi

# ============================================================
# 13. 输出最终状态
# ============================================================

echo ""
echo "============================================================"
echo " BBRv3 安装完成"
echo "============================================================"
echo ""
echo "OpenWrt Kernel : $KERNEL_PATCHVER"
echo "Patch Dir      : $BACKPORT_DIR"
echo "BBRv3 Patches  : 0001 ~ 0018"
echo "x86 Patch 0019 : 已排除"
echo ""
echo "Kernel symbol:"
echo "  CONFIG_TCP_CONG_BBR=y"
echo ""
echo "BBRv3 核心："
echo "  net/ipv4/tcp_bbr.c"
echo ""
echo "运行时拥塞控制名称："
echo "  bbr"
echo ""
echo "注意："
echo "  不存在也不应该人为创建 CONFIG_TCP_CONG_BBR3。"
echo "  YAOF 的 BBRv3 使用原有 CONFIG_TCP_CONG_BBR。"
echo ""
echo "============================================================"
echo " public1.sh OK"
echo "============================================================"
