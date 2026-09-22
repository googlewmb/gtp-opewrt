#!/bin/bash
#
# DIY1 - OpenWrt Mainline 第三方插件
#
# 严格来源优先级：
# ① 直接指定第三方插件源码
# ② 第三方插件源码集合 / Feeds
# ③ OpenWrt 官方插件
#
set -e

echo "========== DIY1 =========="

[ -x ./scripts/feeds ] || {
    echo "错误：当前不是 OpenWrt 源码根目录"
    exit 1
}

mkdir -p package/myapp

# ==========================================================
# ① 第三方 Feeds
# ==========================================================
add_feed() {
    grep -Fqx "src-git $1 $2" feeds.conf.default 2>/dev/null || \
        echo "src-git $1 $2" >> feeds.conf.default
}

add_feed nas "https://github.com/linkease/nas-packages.git;master"
add_feed nas_luci "https://github.com/linkease/nas-packages-luci.git;main"
add_feed jjm2473_apps "https://github.com/jjm2473/openwrt-apps.git;main"
add_feed kenzo "https://github.com/kenzok8/openwrt-packages.git"
add_feed small "https://github.com/kenzok8/small.git"

./scripts/feeds update -a

# ==========================================================
# 第三方 Golang 27.x
# ==========================================================
rm -rf feeds/packages/lang/golang
git clone -b 27.x --depth 1 \
    https://github.com/sbwml/packages_lang_golang \
    feeds/packages/lang/golang

[ -f feeds/packages/lang/golang/Makefile ]

# ==========================================================
# 删除官方冲突插件
# 保留官方其他正常依赖
# ==========================================================
rm_pkg() {
    [ -e "$1" ] && rm -rf "$1"
}

for p in \
    xray-core v2ray-geodata sing-box chinadns-ng dns2socks hysteria \
    ipt2socks microsocks naiveproxy shadowsocks-rust shadowsocksr-libev \
    simple-obfs tcping v2ray-plugin xray-plugin geoview shadow-tls
do
    rm_pkg "feeds/packages/net/$p"
done

for p in \
    luci-app-passwall luci-app-passwall2 luci-app-openclash \
    luci-app-homeproxy luci-app-lucky luci-app-smartdns \
    luci-app-timecontrol luci-app-mosdns luci-app-nikki \
    luci-app-momo luci-app-daed
do
    rm_pkg "feeds/luci/applications/$p"
done

# ==========================================================
# ② 安装第三方 Feeds
# ==========================================================
./scripts/feeds install -a

# ==========================================================
# ③ 直接指定第三方插件
# ==========================================================
clone_pkg() {
    local url="$1"
    local branch="$2"
    local dest="$3"

    rm -rf "$dest"

    if [ -n "$branch" ]; then
        git clone -b "$branch" --depth 1 "$url" "$dest"
    else
        git clone --depth 1 "$url" "$dest"
    fi
}

# ---------- 科学上网 / DNS ----------
clone_pkg \
    "https://github.com/vernesong/OpenClash.git" \
    "master" \
    "package/myapp/openclash"

clone_pkg \
    "https://github.com/immortalwrt/homeproxy.git" \
    "master" \
    "package/myapp/homeproxy"

clone_pkg \
    "https://github.com/pymumu/luci-app-smartdns.git" \
    "master" \
    "package/myapp/luci-app-smartdns"

clone_pkg \
    "https://github.com/pymumu/smartdns.git" \
    "master" \
    "package/myapp/smartdns"

clone_pkg \
    "https://github.com/sbwml/luci-app-mosdns.git" \
    "v5" \
    "package/myapp/mosdns"

clone_pkg \
    "https://github.com/sbwml/v2ray-geodata.git" \
    "" \
    "package/myapp/v2ray-geodata"

# ---------- H68K / 硬件 ----------
clone_pkg \
    "https://github.com/jjm2473/luci-app-oled.git" \
    "master" \
    "package/myapp/luci-app-oled"

clone_pkg \
    "https://github.com/jjm2473/lcdsimple.git" \
    "main" \
    "package/myapp/lcdsimple"

clone_pkg \
    "https://github.com/jjm2473/luci-app-diskman.git" \
    "dev" \
    "package/myapp/luci-app-diskman"

clone_pkg \
    "https://github.com/jjm2473/OpenAppFilter.git" \
    "dev7" \
    "package/myapp/OpenAppFilter"

# ---------- NAT / 穿透 ----------
clone_pkg \
    "https://github.com/muink/openwrt-natmapt.git" \
    "master" \
    "package/myapp/natmapt"

clone_pkg \
    "https://github.com/muink/openwrt-stuntman.git" \
    "master" \
    "package/myapp/stuntman"

clone_pkg \
    "https://github.com/muink/luci-app-natmapt.git" \
    "master" \
    "package/myapp/luci-app-natmapt"

# ---------- Liquid ----------
clone_pkg \
    "https://github.com/zzsj0928/luci-theme-liquid.git" \
    "main" \
    "package/luci-theme-liquid"

# ==========================================================
# PassWall：独立第三方源码
# ==========================================================
rm -rf package/passwall-packages package/passwall-luci

git clone --depth 1 \
    https://github.com/Openwrt-Passwall/openwrt-passwall-packages \
    package/passwall-packages

git clone --depth 1 \
    https://github.com/Openwrt-Passwall/openwrt-passwall \
    package/passwall-luci

# ==========================================================
# 完成
# ==========================================================
echo
echo "========== DIY1 OK =========="
echo "第三方直接插件：package/myapp"
echo "PassWall：package/passwall-*"
echo "Liquid：package/luci-theme-liquid"
echo "第三方 Feeds：feeds/*"
echo "官方 Feeds：保留未冲突插件"
