#!/bin/bash
#
# DIY2 - OpenWrt 官方主线配置
#

set -e

echo "DIY2 - 开始配置"

# ============================================================
# 1. 最大连接数
# ============================================================

echo "设置最大连接数: 655555"

mkdir -p package/base-files/files/etc/sysctl.d

cat > package/base-files/files/etc/sysctl.d/99-conntrack.conf <<'EOF'
net.netfilter.nf_conntrack_max=655555
EOF


# ============================================================
# 2. 默认开启无线
# ============================================================

echo "设置默认开启无线"

mkdir -p package/base-files/files/etc/uci-defaults

cat > package/base-files/files/etc/uci-defaults/99-wireless-enable <<'EOF'
#!/bin/sh

config_load wireless

config_foreach enable_wifi_device wifi-device

enable_wifi_device() {
	local cfg="$1"
	uci -q set wireless.$cfg.disabled='0'
}

uci commit wireless

exit 0
EOF

chmod +x package/base-files/files/etc/uci-defaults/99-wireless-enable


# ============================================================
# 3. SONiC Full Cone NAT
# ============================================================

echo "应用 SONiC Full Cone NAT"

SONIC_URL="https://raw.githubusercontent.com/mufeng05/openwrt-sonic-fullcone/master/add_sonic_fullcone.sh"

curl -fsSL "$SONIC_URL" | bash


# ============================================================
# 4. 完成
# ============================================================

echo ""
echo "============================================================"
echo "DIY2 OK"
echo "============================================================"
echo "Conntrack : 655555"
echo "Wi-Fi     : 默认开启"
echo "Full Cone : SONiC"
echo "============================================================"
