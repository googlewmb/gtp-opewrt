#!/bin/sh
# 加载模块后检查运行配置，不修改 sysctl 或队列规则。
set -eu
fail() { echo "BBRv3 check failed: $*" >&2; exit 1; }
[ -f /etc/bbr3-build.json ] || fail 'build provenance missing'
modprobe tcp_bbr || fail 'cannot load tcp_bbr'
[ "$(cat /sys/module/tcp_bbr/version 2>/dev/null)" = 3 ] || fail 'loaded module is not version 3'
case " $(cat /proc/sys/net/ipv4/tcp_available_congestion_control) " in
  *' bbr '*) ;; *) fail 'bbr is not registered' ;;
esac
[ "$(cat /proc/sys/net/ipv4/tcp_congestion_control)" = bbr ] || fail 'default TCP algorithm is not bbr'
[ "$(cat /proc/sys/net/core/default_qdisc)" = fq ] || fail 'default qdisc is not fq'
echo 'PASS: loaded BBRv3, registered bbr, default BBR/FQ.'
echo 'This is a runtime configuration check, not a throughput/stability test.'
echo 'For a controlled peer running iperf3 -s, test: iperf3 -c PEER -C bbr -t 60'
echo 'Inspect actual egress queues separately with: tc qdisc show'
