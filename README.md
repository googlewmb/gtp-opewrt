# OpenWrt H68K 云编译

使用 **openwrt/openwrt 的 main 分支**与官方 `hinlink_h68k` Target、DTS 和 U-Boot 配置，目标为 HINLINK H68K / RK3568 / ARM64。

在 Actions → **OpenWrt H68K** → Run workflow 启动。成功后生成固件 Artifact；勾选 `release` 时发布 Release。下载固件时一起保存 `sha256sums`，刷机前核验。CI 不替代实机启动测试。

## 修复内容

- 先更新 feeds，再安装依赖和应用 SONiC；不再按通配符执行所有脚本，也不提前用不完整配置准备内核。
- 修复 Ninja 1.13.2 的 `configure.py` 不支持 `--no-rebuild` 导致的构建失败。
- 缓存路径不含行尾注释；保留配置、下载、工具链、内核和并行/单线程编译日志。
- 使用 OpenWrt 包配置命名空间；BBR/FQ 通过 `kmod-tcp-bbr`、`kmod-sched` 安装及自动加载，sysctl 设置默认 BBR/FQ。不会把原生 BBRv1 当作 BBRv3。
- 对最终 `.config` 检查请求的所有选项，缺包/依赖不满足时停止，避免 `defconfig` 静默删除功能。
- 检查 H68K 镜像、manifest、真实文件名 `sha256sums` 及校验结果，验证成功后才发布。

## 功能与来源

`config/h68k.txt` 是功能选择入口。默认启用 OpenClash、HomeProxy、SmartDNS、MosDNS、PassWall、DAED、Diskman，以及常用网络/存储服务。代理需要自行配置，不保证多个透明代理能同时运行。

独立包优先于集合 feed，集合 feed 按 `feeds.conf` 顺序优先于官方 feed。保留官方工具链；不使用其他发行版作为底层。`store`、`third` 不是官方 OpenWrt 默认 feed，不凭资料中的名称伪造来源。OLED、OpenAppFilter、NATMapT 可在配置启用后下载；其余资料列出的插件尚未逐一移植验证。

SONiC 来自 [mufeng05/openwrt-sonic-fullcone](https://github.com/mufeng05/openwrt-sonic-fullcone)。集成内核、libnftnl、nftables、firewall4、LuCI 与中文翻译。当前上游共用补丁支持 6.6/6.12/6.18；遇到未支持的内核立即停止。可在原生防火墙页面设置全局、区域与协议，不自动开放所有 Full Cone 规则，不引入 TurboACC。

DAED 来自 [QiuSimons/luci-app-daed](https://github.com/QiuSimons/luci-app-daed)，同时安装后端、Web 前端、LuCI 与 BPF/BTF/XDP 依赖。主机安装 Clang/LLVM/Node/pnpm。针对其固定 DAED 源码 `f045ecd` 的两处 catalog 锁文件不一致修复元数据，不更改锁定版本或关闭 frozen 检查；其他未知不一致会报错。

BBRv3 的算法源码直接来自 [Google BBR team](https://github.com/google/bbr/tree/v3)，固定提交 `795544cc00f03d49cfa6802f3da32c0d0a6fb4ab`。TCP 配套接口移植参考 [sbwml/kernel-latest-centos](https://github.com/sbwml/kernel-latest-centos) 的固定 BBR 补丁提交，只取 BBR 相关文件，不使用其发行版或其他补丁。检测实际内核接口后，选择能完整通过 dry-run 的适配器，生成当前源码专用 patch，重新 prepare 并实际 Kbuild。**无法承诺自动支持任意未来内核 API**；不匹配时明确失败，需要补充经过验证的适配器。补丁回放成功不等于内核已编译成功。

`build-info` 保存 OpenWrt、feeds、插件提交、BBR 来源、最终配置及内核配置。上游 main/feeds 仍可能变化；诊断问题时请提供对应构建日志及此目录。

首次启动通过 UCI defaults 配置并启用检测到的 Wi-Fi，H68K 无内置无线电。conntrack 上限为 `655550`，配置位于独立 sysctl.d 文件中。

## 验证边界

本地检查覆盖 YAML/Shell/Python 语法、官方 H68K 定义、Ninja 修复、DAED 锁文件、BBRv3 在 Linux 6.18.52 TCP 源码上的完整补丁回放。GitHub Actions 的实际结果是编译成功与否的依据；仅有本地检查不能认定固件已可用。
