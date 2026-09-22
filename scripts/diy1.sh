#!/bin/bash
#
# DIY1 - 第三方插件
#

echo "DIY1 - 下载第三方插件"

mkdir -p package/myapp
cd package/myapp

# 科学上网 / DNS
git clone -b master --depth 1 https://github.com/vernesong/OpenClash.git openclash
git clone -b master --depth 1 https://github.com/immortalwrt/homeproxy.git homeproxy
git clone -b master --depth 1 https://github.com/pymumu/luci-app-smartdns.git luci-app-smartdns
git clone -b master --depth 1 https://github.com/pymumu/smartdns.git smartdns
git clone -b v5 --depth 1 https://github.com/sbwml/luci-app-mosdns.git mosdns
git clone --depth 1 https://github.com/sbwml/v2ray-geodata.git v2ray-geodata

# H68K / 硬件 / NAS
git clone -b master --depth 1 https://github.com/jjm2473/luci-app-oled.git luci-app-oled
git clone -b main --depth 1 https://github.com/jjm2473/lcdsimple.git lcdsimple
git clone -b dev --depth 1 https://github.com/jjm2473/luci-app-diskman.git luci-app-diskman
git clone -b dev7 --depth 1 https://github.com/jjm2473/OpenAppFilter.git OpenAppFilter

# NAT 穿透
git clone -b master --depth 1 https://github.com/muink/openwrt-natmapt.git natmapt
git clone -b master --depth 1 https://github.com/muink/openwrt-stuntman.git stuntman
git clone -b master --depth 1 https://github.com/muink/luci-app-natmapt.git luci-app-natmapt

# 备用插件
# git clone -b main --depth 1 https://github.com/gdy666/luci-app-lucky.git lucky
# git clone -b main --depth 1 https://github.com/sirpdboy/luci-app-timecontrol.git timecontrol
# git clone -b main --depth 1 https://github.com/nikkinikki-org/OpenWrt-nikki.git nikki
# git clone -b main --depth 1 https://github.com/nikkinikki-org/OpenWrt-momo.git momo
# git clone -b master --depth 1 https://github.com/QiuSimons/luci-app-daed.git daed
# git clone -b master --depth 1 https://github.com/eamonxg/luci-theme-aurora.git aurora
# git clone -b master --depth 1 https://github.com/fw876/helloworld.git helloworld
# git clone -b main --depth 1 https://github.com/Openwrt-Passwall/openwrt-passwall-packages.git passwall-packages
# git clone -b main --depth 1 https://github.com/Openwrt-Passwall/openwrt-passwall.git passwall
# git clone -b main --depth 1 https://github.com/Openwrt-Passwall/openwrt-passwall2.git passwall2

cd ../..

# 第三方 Feeds
echo 'src-git nas https://github.com/linkease/nas-packages.git;master' >> feeds.conf.default
echo 'src-git nas_luci https://github.com/linkease/nas-packages-luci.git;main' >> feeds.conf.default
echo 'src-git jjm2473_apps https://github.com/jjm2473/openwrt-apps.git;main' >> feeds.conf.default
echo 'src-git kenzo https://github.com/kenzok8/openwrt-packages.git' >> feeds.conf.default
echo 'src-git small https://github.com/kenzok8/small.git' >> feeds.conf.default

# 备用 Feeds
# echo 'src-git istore https://github.com/linkease/istore-packages.git;main' >> feeds.conf.default
# echo 'src-git kiddin9 https://github.com/kiddin9/op-packages.git' >> feeds.conf.default
# echo 'src-git vikingyfy https://github.com/VIKINGYFY/packages.git' >> feeds.conf.default
# echo 'src-git modem https://github.com/FUjr/modem_feeds.git' >> feeds.conf.default
# echo 'src-git small_package https://github.com/kenzok8/small-package.git' >> feeds.conf.default

# Liquid 主题
git clone --depth 1 https://github.com/xylz0928/luci-theme-liquid.git package/luci-theme-liquid

# 插件列表
echo "package/myapp:"
find package/myapp -maxdepth 1 -mindepth 1 -type d -printf '%f\n' | sort

echo "DIY1 OK"
