#!/usr/bin/env bash
# =============================================================================
#  prepare_h200_usb.sh  -  everything that needs the Internet, in one command
#
#  Run on the ONLINE Ubuntu 26.04 amd64 machine BEFORE the USB drive goes to the
#  offline H200. It:
#    1. installs the few tools the builder needs if they are missing
#       (curl zip unzip xz-utils - via sudo apt-get),
#    2. downloads the NVIDIA 615.71.09 local repository package
#       (download_nvidia_repo.sh -> ./nvidia-downloads/),
#    3. downloads every required Ubuntu 26.04 package and builds + validates
#       H200_NVIDIA_615.71.09_Ubuntu26.04_Offline.zip
#       (build_h200_nvidia_offline_bundle.sh),
#    4. with --usb: copies the ZIP to the mounted USB drive, writes a .sha256 file
#       next to it and verifies the copy.
#
#  Usage:
#    ./prepare_h200_usb.sh [--usb MOUNTED_USB_DIR] [--output-dir DIR] [builder options]
#  Builder options are passed through unchanged, for example:
#    ./prepare_h200_usb.sh --usb /media/$USER/MYUSB --kernel 7.0.0-38-generic
#    ./prepare_h200_usb.sh --usb /media/$USER/MYUSB --target-state h200_target_state_x.tar.gz
# =============================================================================
set -Eeuo pipefail
export LC_ALL=C

readonly ZIP_NAME="H200_NVIDIA_615.71.09_Ubuntu26.04_Offline.zip"
readonly BUNDLE_DIRNAME="H200_NVIDIA_615.71.09_Ubuntu26.04_Offline"
readonly INSTALLER_NAME="install_h200_nvidia_offline.sh"
readonly FAT32_MAX_BYTES=4294967295

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
readonly SCRIPT_DIR

USB_DIR=""
OUTPUT_DIR=""
NVIDIA_DEB_ARG=""
NVIDIA_DIR_ARG=""
BUILDER_ARGS=()

say() { printf '\n==== %s ====\n' "$*"; }
die() {
  local code=$1 line
  shift
  printf '\nERROR: %s\n' "$1" >&2
  shift
  for line in "$@"; do printf '       %s\n' "$line" >&2; done
  exit "$code"
}
have() { command -v "$1" >/dev/null 2>&1; }

# Prints the comment block at the top of this file.
usage() { awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "${BASH_SOURCE[0]}"; }

readonly EMPTY_SHA256=e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855

# SHA256 of FILE read from the device rather than from the page cache.
# Prints "<sha256> <method>"; returns 1 if the cache cannot be bypassed.
uncached_sha256() {
  local f=$1 dd_bin sha
  # O_DIRECT read. Ubuntu 26.04's default (uutils) dd rejects iflag=direct; GNU dd is "gnudd" there.
  for dd_bin in gnudd dd; do
    have "$dd_bin" || continue
    if sha=$("$dd_bin" if="$f" iflag=direct bs=4M status=none 2>/dev/null | sha256sum | awk '{print $1}') &&
      [[ -n $sha && $sha != "$EMPTY_SHA256" ]]; then
      printf '%s %s\n' "$sha" "direct read from the drive"
      return 0
    fi
  done
  # Otherwise evict the (already synced, clean) file pages from the cache, then read it again.
  if have python3 && python3 -c 'import os, sys
fd = os.open(sys.argv[1], os.O_RDONLY)
os.posix_fadvise(fd, 0, 0, os.POSIX_FADV_DONTNEED)
os.close(fd)' "$f" 2>/dev/null; then
    sha=$(sha256sum -- "$f" | awk '{print $1}')
    printf '%s %s\n' "$sha" "re-read after evicting it from the page cache"
    return 0
  fi
  return 1
}

while (($#)); do
  case $1 in
    --usb) (($# >= 2)) || die 2 "--usb needs the mount point of the USB drive"; USB_DIR=$2; shift 2 ;;
    --usb=*) USB_DIR=${1#*=}; shift ;;
    --output-dir) (($# >= 2)) || die 2 "--output-dir needs a directory"; OUTPUT_DIR=$2; shift 2 ;;
    --output-dir=*) OUTPUT_DIR=${1#*=}; shift ;;
    --nvidia-repo-deb) (($# >= 2)) || die 2 "--nvidia-repo-deb needs a file"; NVIDIA_DEB_ARG=$2; BUILDER_ARGS+=("$1" "$2"); shift 2 ;;
    --nvidia-repo-deb=*) NVIDIA_DEB_ARG=${1#*=}; BUILDER_ARGS+=("$1"); shift ;;
    --nvidia-download-dir) (($# >= 2)) || die 2 "--nvidia-download-dir needs a directory"; NVIDIA_DIR_ARG=$2; BUILDER_ARGS+=("$1" "$2"); shift 2 ;;
    --nvidia-download-dir=*) NVIDIA_DIR_ARG=${1#*=}; BUILDER_ARGS+=("$1"); shift ;;
    -h | --help) usage; exit 0 ;;
    *) BUILDER_ARGS+=("$1"); shift ;;
  esac
done
OUTPUT_DIR=${OUTPUT_DIR:-$PWD}
[[ $OUTPUT_DIR == /* ]] || OUTPUT_DIR="$PWD/$OUTPUT_DIR"
OUTPUT_DIR=$(realpath -m -s -- "$OUTPUT_DIR")

for f in build_h200_nvidia_offline_bundle.sh "$INSTALLER_NAME" capture_target_state.sh download_nvidia_repo.sh; do
  [[ -f $SCRIPT_DIR/$f ]] || die 2 "$f must be in the same folder as prepare_h200_usb.sh ($SCRIPT_DIR)"
done

# Check the USB target up front, before spending time on downloads.
if [[ -n $USB_DIR ]]; then
  [[ -d $USB_DIR ]] || die 2 "USB folder not found: $USB_DIR" "Plug the drive in and check where it is mounted: lsblk -o NAME,SIZE,FSTYPE,MOUNTPOINTS"
  USB_DIR="$(cd -- "$USB_DIR" && pwd -P)"
  # A mounted USB drive is a different device than the root file system.
  [[ $(stat -c %d -- "$USB_DIR") != "$(stat -c %d -- /)" ]] ||
    die 2 "$USB_DIR is on the system disk, not on a mounted USB drive." \
      "Mount the USB drive (it usually appears under /media/\$USER/) and pass that path to --usb." \
      "Check with: lsblk -o NAME,SIZE,FSTYPE,MOUNTPOINTS"
  if have findmnt; then
    usb_src=$(findmnt -n -o SOURCE --target "$USB_DIR" 2>/dev/null || true)
    usb_fs=$(findmnt -n -o FSTYPE --target "$USB_DIR" 2>/dev/null || true)
    case $usb_fs in
      tmpfs | ramfs | devtmpfs | overlay | squashfs | proc | sysfs)
        die 2 "$USB_DIR is on a $usb_fs file system, not on a USB drive." "Mount the USB drive and pass its mount point to --usb." ;;
    esac
    [[ -z $usb_src || $usb_src == /dev/* ]] ||
      die 2 "$USB_DIR is on '$usb_src', which is not a local block device (USB drive)." "Mount the USB drive and pass its mount point to --usb."
  fi
  [[ -w $USB_DIR ]] || die 2 "$USB_DIR is not writable (mounted read-only, or owned by another user)."
fi

# -----------------------------------------------------------------------------
say "1/4  Build tools"
. /etc/os-release 2>/dev/null || true
if [[ ${ID:-} != ubuntu || ${VERSION_ID:-} != 26.04 || $(uname -m) != x86_64 ]]; then
  die 10 "This must run on Ubuntu 26.04 amd64 (this machine: ${PRETTY_NAME:-unknown}, $(uname -m))." \
    "The NVIDIA file alone can be fetched on any machine with: ./download_nvidia_repo.sh"
fi
declare -A tool_pkg=([zip]=zip [unzip]=unzip [xz]=xz-utils [gzip]=gzip [dpkg-deb]=dpkg [apt-get]=apt [sha256sum]=coreutils)
missing_pkgs=()
for t in "${!tool_pkg[@]}"; do have "$t" || missing_pkgs+=("${tool_pkg[$t]}"); done
have curl || have wget || missing_pkgs+=(curl)
if ((${#missing_pkgs[@]})); then
  echo "Installing missing tools: ${missing_pkgs[*]}"
  sudo_cmd=()
  if ((EUID != 0)); then
    have sudo || die 2 "Missing tools: ${missing_pkgs[*]}" "Install them as root: apt-get install -y ${missing_pkgs[*]}"
    sudo_cmd=(sudo)
  fi
  { "${sudo_cmd[@]}" apt-get update && "${sudo_cmd[@]}" apt-get install -y "${missing_pkgs[@]}"; } ||
    die 2 "Installing the missing tools failed: ${missing_pkgs[*]}" "Fix APT (sudo apt-get update) and run this script again."
  still_missing=()
  for t in "${!tool_pkg[@]}"; do have "$t" || still_missing+=("$t"); done
  have curl || have wget || still_missing+=(curl)
  ((${#still_missing[@]} == 0)) || die 2 "Still missing after installation: ${still_missing[*]}"
else
  echo "All tools present."
fi

# -----------------------------------------------------------------------------
say "2/4  NVIDIA 615.71.09 local repository package"
if [[ -n $NVIDIA_DEB_ARG ]]; then
  echo "Using $NVIDIA_DEB_ARG (given with --nvidia-repo-deb)."
else
  dl_args=()
  [[ -n $NVIDIA_DIR_ARG ]] && dl_args=(--dest "$NVIDIA_DIR_ARG")
  rc=0
  bash "$SCRIPT_DIR/download_nvidia_repo.sh" "${dl_args[@]}" || rc=$?
  ((rc == 0)) || die "$rc" "The NVIDIA package is not available yet - nothing was built." \
    "Follow the instructions above (download it manually, put it in the folder shown), then run this script again."
fi

# -----------------------------------------------------------------------------
say "3/4  Ubuntu packages + bundle build and validation"
rc=0
bash "$SCRIPT_DIR/build_h200_nvidia_offline_bundle.sh" --output-dir "$OUTPUT_DIR" "${BUILDER_ARGS[@]}" || rc=$?
((rc == 0)) || die "$rc" "The bundle build failed (see the messages above). Nothing was copied to the USB drive."
zip_path="$OUTPUT_DIR/$ZIP_NAME"
[[ -f $zip_path ]] || die 1 "The builder reported success but $zip_path does not exist."
zip_sha=$(sha256sum -- "$zip_path" | awk '{print $1}')
zip_size=$(stat -c %s -- "$zip_path")
printf '%s  %s\n' "$zip_sha" "$ZIP_NAME" >"$zip_path.sha256"

# -----------------------------------------------------------------------------
say "4/4  USB drive"
if [[ -z $USB_DIR ]]; then
  echo "No --usb given. Copy BOTH files to the USB drive yourself:"
  echo "  $zip_path"
  echo "  $zip_path.sha256"
  echo "  SHA256 $zip_sha"
else
  fstype=""
  if have findmnt; then fstype=$(findmnt -n -o FSTYPE --target "$USB_DIR" 2>/dev/null || true); fi
  if [[ $fstype == vfat ]] && ((zip_size > FAT32_MAX_BYTES)); then
    die 5 "The ZIP is $((zip_size / 1048576)) MiB but the USB drive is FAT32, which cannot store files larger than 4 GiB." \
      "Reformat the drive as exFAT or ext4, or build for a single kernel (--kernel \$(uname -r of the H200)) to make the ZIP smaller."
  fi
  free_kib=$(df -Pk -- "$USB_DIR" | awk 'NR==2 {print $4}')
  if [[ $free_kib =~ ^[0-9]+$ ]] && ((free_kib * 1024 < zip_size + 16 * 1048576)); then
    die 5 "Not enough space on the USB drive: $((free_kib / 1024)) MiB free, $((zip_size / 1048576 + 16)) MiB needed."
  fi
  echo "Copying to $USB_DIR (${fstype:-unknown file system}) ..."
  cp -f -- "$zip_path" "$USB_DIR/$ZIP_NAME.part"
  mv -f -- "$USB_DIR/$ZIP_NAME.part" "$USB_DIR/$ZIP_NAME"
  printf '%s  %s\n' "$zip_sha" "$ZIP_NAME" >"$USB_DIR/$ZIP_NAME.sha256"
  sync
  echo "Verifying the copy on the USB drive ..."
  if result=$(uncached_sha256 "$USB_DIR/$ZIP_NAME"); then
    usb_sha=${result%% *}
    method=${result#* }
  else
    usb_sha=$(sha256sum -- "$USB_DIR/$ZIP_NAME" | awk '{print $1}')
    method="page-cache read only - re-check on the H200 with sha256sum -c"
  fi
  [[ $usb_sha == "$zip_sha" ]] || die 6 "The copy on the USB drive is corrupt (SHA256 $usb_sha, expected $zip_sha)." \
    "Try another USB drive or port."
  echo "OK: $USB_DIR/$ZIP_NAME"
  echo "    $USB_DIR/$ZIP_NAME.sha256"
  echo "    SHA256 $zip_sha ($method)"
  echo "Eject the drive safely before unplugging it, for example:  udisksctl unmount -b <device>  or  umount $USB_DIR"
fi

cat <<EOF

===============================================================================
 READY - everything that needs the Internet has been downloaded.
 ZIP    : $zip_path
 SHA256 : $zip_sha

 On the offline H200:
   mkdir -p ~/h200-nvidia && cp /path/to/usb/${ZIP_NAME}* ~/h200-nvidia/ && cd ~/h200-nvidia
   sha256sum -c ${ZIP_NAME}.sha256
   unzip ${ZIP_NAME}        # or: python3 -m zipfile -e ${ZIP_NAME} .
   cd ${BUNDLE_DIRNAME}
   sudo bash ./${INSTALLER_NAME} --dry-run
   sudo bash ./${INSTALLER_NAME}
   nvidia-smi
===============================================================================
EOF
