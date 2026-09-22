#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/common.sh"
mkdir -p package/myapp
: > build-info/sources.txt
printf 'openwrt https://github.com/openwrt/openwrt.git %s\n' "$(git rev-parse HEAD)" >> build-info/sources.txt
install_source() {
    local name="$1" url="$2" branch="$3" subdir="${4:-.}"
    source_repo "$name" "$url" "$branch"
    test -d ".sources/$name/$subdir"
    # Only expose OpenWrt packages, not the application's upstream build files.
    ln -sfn "../../.sources/$name/$subdir" "package/myapp/$name"
}
if enabled luci-app-openclash; then
    install_source openclash https://github.com/vernesong/OpenClash.git master luci-app-openclash
fi
if enabled luci-app-homeproxy; then
    install_source homeproxy https://github.com/immortalwrt/homeproxy.git master
fi
if enabled luci-app-smartdns; then
    install_source luci-app-smartdns https://github.com/pymumu/luci-app-smartdns.git master
    install_source smartdns https://github.com/pymumu/openwrt-smartdns.git master
fi
if enabled luci-app-mosdns; then
    install_source mosdns https://github.com/sbwml/luci-app-mosdns.git v5
fi
if enabled luci-app-passwall; then
    install_source passwall-packages https://github.com/Openwrt-Passwall/openwrt-passwall-packages.git main
    install_source passwall https://github.com/Openwrt-Passwall/openwrt-passwall.git main
fi
if enabled luci-app-daed; then
    install_source daed https://github.com/QiuSimons/luci-app-daed.git master
fi
if enabled luci-app-oled; then
    install_source oled https://github.com/jjm2473/luci-app-oled.git master
    install_source lcdsimple https://github.com/jjm2473/lcdsimple.git main
fi
if enabled luci-app-diskman; then
    install_source diskman https://github.com/jjm2473/luci-app-diskman.git dev
fi
if enabled luci-app-oaf; then
    install_source openappfilter https://github.com/jjm2473/OpenAppFilter.git dev7
fi
if enabled luci-app-natmapt; then
    install_source natmapt https://github.com/muink/openwrt-natmapt.git master
    install_source stuntman https://github.com/muink/openwrt-stuntman.git master
    install_source luci-app-natmapt https://github.com/muink/luci-app-natmapt.git master
fi
# Native package/ takes priority. Feed ordering resolves remaining duplicates.
cat > feeds.conf <<'EOF'
src-git nas https://github.com/linkease/nas-packages.git;master
src-git nas_luci https://github.com/linkease/nas-packages-luci.git;main
src-git jjm2473_apps https://github.com/jjm2473/openwrt-apps.git;main
src-git kenzo https://github.com/kenzok8/openwrt-packages.git
src-git small https://github.com/kenzok8/small.git
EOF
cat feeds.conf.default >> feeds.conf
./scripts/feeds update -a
# OpenWrt's parser handles LuCI-generated package definitions and native priority.
./scripts/feeds install -a
for feed in feeds/*; do
    [[ -d "$feed/.git" ]] || continue
    printf 'feed/%s %s %s\n' "${feed##*/}" "$(git -C "$feed" remote get-url origin)" "$(git -C "$feed" rev-parse HEAD)" >> build-info/sources.txt
done