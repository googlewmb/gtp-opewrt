#!/usr/bin/env bash
# Run after feeds, final config, host tools and toolchain.
set -euo pipefail
source "$(dirname "$0")/../scripts/common.sh"
make target/linux/prepare V=s
mapfile -t kernels < <(find build_dir/target-* -type f -path '*/linux-*/net/ipv4/tcp_bbr.c')
[[ ${#kernels[@]} -eq 1 ]] || { echo 'Expected one prepared target kernel' >&2; exit 1; }
linux_dir="${kernels[0]%/net/ipv4/tcp_bbr.c}"
python3 "$PROJECT_DIR/scripts/bbr.py" "$linux_dir" "$(kernel_version)"
make target/linux/clean V=s
make target/linux/prepare V=s
mapfile -t kernels < <(find build_dir/target-* -type f -path '*/linux-*/net/ipv4/tcp_bbr.c')
[[ ${#kernels[@]} -eq 1 ]]
grep -Eq '#define[[:space:]]+BBR_VERSION[[:space:]]+3' "${kernels[0]}"
make target/linux/compile -j"$(nproc)" V=s
python3 "$PROJECT_DIR/scripts/prepare.py" kernel-check