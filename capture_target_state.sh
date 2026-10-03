#!/usr/bin/env bash
# =============================================================================
#  capture_target_state.sh
#
#  OPTIONAL helper. Run it on the OFFLINE H200 server. It collects, read-only,
#  the facts the bundle builder needs to resolve dependencies against the
#  H200's exact installed package set:
#      /etc/os-release, uname -r, dpkg architectures, /var/lib/dpkg/status,
#      held packages, NVIDIA PCI devices, Secure Boot state.
#  Nothing is changed on the server and no network access is used.
#
#  Usage (on the H200):   bash ./capture_target_state.sh [output-directory]
#  Then on the online machine:
#      ./build_h200_nvidia_offline_bundle.sh --target-state h200_target_state_<host>_<time>.tar.gz
# =============================================================================
set -Eeuo pipefail
umask 022
export LC_ALL=C LANG=C

out_dir=${1:-.}
[[ -d $out_dir && -w $out_dir ]] || { printf 'Output directory %s does not exist or is not writable.\n' "$out_dir" >&2; exit 2; }

host=$(uname -n)
host=${host%%.*}
stamp=$(date -u +%Y%m%dT%H%M%SZ)
name="h200_target_state_${host}_${stamp}"

tmp=$(mktemp -d /tmp/h200-target-state.XXXXXX)
trap 'rm -rf -- "$tmp"' EXIT
d="$tmp/$name"
mkdir -p -- "$d"

echo "FORMAT=1" >"$d/FORMAT"
cp -- /etc/os-release "$d/os-release"
uname -r >"$d/uname-r"
uname -m >"$d/uname-m"
dpkg --print-architecture >"$d/dpkg-architecture"
dpkg --print-foreign-architectures >"$d/dpkg-foreign-architectures"
cp -- /var/lib/dpkg/status "$d/dpkg-status"
dpkg-query -W -f='${db:Status-Abbrev}\t${Package}\t${Version}\t${Architecture}\n' >"$d/dpkg-packages.tsv"
apt-mark showhold >"$d/apt-holds" 2>/dev/null || true

{
  for dev in /sys/bus/pci/devices/*; do
    [[ -r $dev/vendor ]] || continue
    [[ $(<"$dev/vendor") == 0x10de ]] || continue
    drv=none
    [[ -L $dev/driver ]] && drv=$(basename -- "$(readlink -f -- "$dev/driver")")
    printf '%s class=%s device=%s driver=%s\n' "${dev##*/}" "$(<"$dev/class")" "$(<"$dev/device")" "$drv"
  done
} >"$d/pci-nvidia.txt"
if command -v lspci >/dev/null 2>&1; then lspci -nn >"$d/lspci.txt" 2>&1 || true; fi
if command -v mokutil >/dev/null 2>&1; then mokutil --sb-state >"$d/secureboot.txt" 2>&1 || true; fi
if [[ -r /proc/driver/nvidia/version ]]; then cp -- /proc/driver/nvidia/version "$d/nvidia-driver-version.txt"; fi

tar -C "$tmp" -czf "$out_dir/$name.tar.gz" "$name"
printf 'Created %s/%s.tar.gz\n' "$out_dir" "$name"
printf '  Ubuntu : %s\n' "$(. /etc/os-release && printf '%s' "${VERSION:-$VERSION_ID}")"
printf '  Kernel : %s\n' "$(cat "$d/uname-r")"
printf '  Arch   : %s\n' "$(cat "$d/dpkg-architecture")"
printf '  NVIDIA PCI devices: %s\n' "$(grep -c . "$d/pci-nvidia.txt" || true)"
printf '\nCopy this file to the online build machine and run:\n'
printf '  ./build_h200_nvidia_offline_bundle.sh --target-state %s.tar.gz\n' "$name"
