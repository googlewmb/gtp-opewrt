#!/usr/bin/env bash
# 系统默认设置：连接跟踪上限、BBR/FQ 与检测到的无线设备。
set -euo pipefail
mkdir -p files/etc/sysctl.d files/etc/uci-defaults
cat > files/etc/sysctl.d/99-h68k.conf <<'EOF'
net.netfilter.nf_conntrack_max=655550
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF
cat > files/etc/uci-defaults/99-h68k-wifi <<'EOF'
#!/bin/sh
. /lib/functions.sh
[ -s /etc/config/wireless ] || wifi config
[ -s /etc/config/wireless ] || exit 0
enable_wifi() { uci -q set "wireless.$1.disabled=0"; }
config_load wireless
config_foreach enable_wifi wifi-device
config_foreach enable_wifi wifi-iface
uci -q commit wireless
exit 0
EOF
chmod +x files/etc/uci-defaults/99-h68k-wifi