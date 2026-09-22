# OpenWrt 主线 BBRv3 专用适配脚本

在 Linux 构建机上，完成 feeds、目标选择、`make defconfig`、源码下载及
`make tools/install toolchain/install` 后，从 OpenWrt 源码根目录执行：

```sh
python3 /path/to/gtp-opewrt/scripts/openwrt-bbr3.py --openwrt . --jobs 4
```

必须保留同目录 `bbr.py` 和 `bbr3-check.sh`。需要 Python 3、Git、网络和
OpenWrt 构建依赖；配置启用 `CONFIG_PACKAGE_kmod-tcp-bbr=y` 与
`CONFIG_PACKAGE_kmod-sched=y`。仓库现有云编译已通过 `patch/public1.sh` 自动调用。

流程：

1. 从最终 `.config` 识别目标，从实际准备后的内核 Makefile 识别内核系列。
2. 优先尝试固定、已检查过的 TCP 适配器；自动获取同一上游 BBR 补丁的近期
   不同版本作为候选，最多 8 个。`--pinned-only` 可关闭上游候选发现。
3. Google 算法固定为 `795544cc00f03d49cfa6802f3da32c0d0a6fb4ab`。
   不混用其他补丁自带的算法；保留 TCP 核心配套改动。
4. 在临时目录做完整匹配，生成针对当前源码的补丁，重新 prepare 并完整 Kbuild。
   匹配或编译失败自动尝试下一候选；每次编译日志独立保存。
5. 核对所有修改后的源码 SHA256、BBR/FQ 配置、vmlinux 和 tcp_bbr.ko 的
   `version=3`；最终固件发布前再次核对。任何候选都不通过时明确失败。

`build-info/bbr.json` 保存状态、候选失败原因、来源提交及摘要；
`build-info/bbr-attempt-*.log` 保存编译错误。重复执行只清理有摘要记录且未被编辑的
自有补丁，拒绝覆盖其他 BBR 补丁。脚本会重新编译目标内核，需要相应时间与磁盘。

刷机并启动后执行：

```sh
bbr3-check
```

它加载 tcp_bbr，检查运行模块版本、算法注册与默认 BBR/FQ 配置，不改动现有
sysctl 或队列规则。实际出口队列用 `tc qdisc show` 检查。
受控对端运行 `iperf3 -s` 后，可在路由器执行 `iperf3 -c PEER -C bbr -t 60`
并结合双向流量、丢包、延迟及长期运行测试验证效果（需自行安装 iperf3）。

自动适配的边界：候选更新能覆盖上游已经完成的移植，不能自动发明未知内核 API
的正确语义。严格补丁匹配和完整编译也不能证明所有网络场景稳定。
因此不承诺任意未来主线永远兼容，不把编译成功当成实机测试成功，不降级为 BBRv1。
SONiC、DAED 等其他组件仍有各自兼容范围，本脚本只负责 BBRv3。
