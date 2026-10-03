#!/usr/bin/env bash
# =============================================================================
#  install_h200_nvidia_offline.sh
#
#  Offline installer for the NVIDIA 615.71.09 data center driver (open GPU
#  kernel modules, built with DKMS) on an NVIDIA H200 server running
#  Ubuntu 26.04 amd64.
#
#  It uses ONLY the .deb files shipped in ./packages (as a local APT
#  repository) and never contacts the Internet. The host's APT sources are not
#  modified; nothing is written to /etc/apt.
#
#  Usage:  sudo bash ./install_h200_nvidia_offline.sh [--dry-run]
#                [--replace-existing-driver] [--skip-gpu-check] [--install-kernel]
# =============================================================================
set -Eeuo pipefail
shopt -s nullglob
umask 022
export LC_ALL=C LANG=C
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=l NEEDRESTART_SUSPEND=1
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin${PATH:+:$PATH}"

readonly SCRIPT_VERSION="1.0.0"
readonly EXPECTED_DRIVER_VERSION="615.71.09"
readonly EXPECTED_UBUNTU_VERSION="26.04"
readonly EXPECTED_ARCH="amd64"
readonly EXPECTED_UNAME_M="x86_64"
readonly DRIVER_VERSION_RE="^([0-9]+:)?${EXPECTED_DRIVER_VERSION//./\\.}([-+~].*)?\$"
readonly ANY_DRIVER_VERSION_RE='^([0-9]+:)?[0-9]{3}\.[0-9]+(\.[0-9]+)?([-+~].*)?$'
readonly NOUVEAU_BLACKLIST="/etc/modprobe.d/h200-nvidia-offline-blacklist-nouveau.conf"
readonly FALLBACK_LOG="/var/log/h200_nvidia_offline_install.log"

BUNDLE_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
readonly BUNDLE_DIR
readonly PKG_DIR="$BUNDLE_DIR/packages"

# Exit codes (also documented in README.txt)
readonly E_OK=0 E_GENERIC=1 E_USAGE=2 E_REBOOT=3
readonly E_OS=10 E_KERNEL=11 E_BUNDLE=12 E_CONFLICT=13
readonly E_DEPS=20 E_HEADERS=21
readonly E_DKMS=30 E_SECUREBOOT=31 E_LOAD=32
readonly E_SMI=40 E_NOH200=41 E_FM=42

DRY_RUN=0
REPLACE_EXISTING=0
SKIP_GPU_CHECK=0
INSTALL_KERNEL=0

LOG_FILE=""
TEE_PID=""
TMP_DIR=""
APT_CONF=""
KREL=""
SB_STATE="unknown"
FINAL_EXIT=$E_OK
REPORT_DONE=0
declare -A CONF=()
RESULTS=()
NVIDIA_GPUS=()
NVSWITCHES=()
PHASE_A_PKGS=()
PHASE_B_PKGS=()
PHASE_B_INCOMPLETE=0

# -----------------------------------------------------------------------------
# Output, logging and the final report
# -----------------------------------------------------------------------------
section() { printf '\n==== %s ====\n' "$*"; }
info() { printf '  [INFO] %s\n' "$*"; }
record() {
  local status=$1 check=$2 detail=$3
  RESULTS+=("$status|$check|$detail")
  printf '  [%s] %s: %s\n' "$status" "$check" "$detail"
}
log_only() { if [[ -n $LOG_FILE ]]; then cat >&5; else cat >/dev/null; fi; }

start_logging() {
  local candidate="$BUNDLE_DIR/install.log"
  if ! { : >>"$candidate"; } 2>/dev/null; then
    candidate=$FALLBACK_LOG
    if ! { : >>"$candidate"; } 2>/dev/null; then
      candidate="${TMPDIR:-/tmp}/h200_nvidia_offline_install.log"
      : >>"$candidate"
    fi
  fi
  LOG_FILE=$candidate
  exec 3>&1 4>&2
  exec 5>>"$LOG_FILE"
  exec > >(tee -a -- "$LOG_FILE") 2>&1
  TEE_PID=$!
}

stop_logging() {
  if [[ -n $TEE_PID ]]; then
    exec 1>&3 2>&4
    wait "$TEE_PID" 2>/dev/null || true
    TEE_PID=""
  fi
}

final_report() {
  local overall=$1 r s c d
  ((REPORT_DONE)) && return 0
  REPORT_DONE=1
  printf '\n===============================================================================\n'
  printf ' H200 NVIDIA %s OFFLINE INSTALLATION REPORT\n' "$EXPECTED_DRIVER_VERSION"
  printf '===============================================================================\n'
  printf ' Date     : %s\n' "$(date -u +'%Y-%m-%d %H:%M:%S UTC')"
  printf ' Host     : %s\n' "$(uname -n)"
  printf ' Kernel   : %s\n' "$(uname -r)"
  printf ' Bundle   : %s\n' "$BUNDLE_DIR"
  printf ' Mode     : %s\n' "$( ((DRY_RUN)) && echo 'dry-run (no changes made)' || echo install)"
  printf -- '-------------------------------------------------------------------------------\n'
  for r in "${RESULTS[@]}"; do
    IFS='|' read -r s c d <<<"$r"
    printf ' %-5s %-30s %s\n' "$s" "$c" "$d"
  done
  printf -- '-------------------------------------------------------------------------------\n'
  printf ' RESULT   : %s\n' "$overall"
  printf ' Log file : %s\n' "${LOG_FILE:-none}"
  printf '===============================================================================\n'
}

# finish CODE CHECK DETAIL [extra explanation lines...]
finish() {
  local code=$1 check=$2 detail=$3 line
  shift 3
  if ((code == E_OK)); then
    record PASS "$check" "$detail"
  elif ((code == E_REBOOT)); then
    record ACT "$check" "$detail"
  else
    record FAIL "$check" "$detail"
  fi
  if (($#)); then
    printf '\n'
    for line in "$@"; do printf '  >> %s\n' "$line"; done
  fi
  trap - ERR
  case $code in
    "$E_OK")
      if ((DRY_RUN)); then
        final_report "SUCCESS (dry run) - all checks passed; nothing was installed or changed"
      else
        final_report "SUCCESS - NVIDIA ${EXPECTED_DRIVER_VERSION} is installed and nvidia-smi works"
      fi
      ;;
    "$E_REBOOT") final_report "ACTION REQUIRED - reboot, then run this installer again (exit code $code)" ;;
    *) final_report "FAILED - $check (exit code $code)" ;;
  esac
  FINAL_EXIT=$code
  exit "$code"
}

on_unexpected_error() {
  local rc=$1 line=$2 cmd=$3
  if [[ $BASHPID != "$$" ]]; then exit "$rc"; fi
  trap - ERR
  finish "$E_GENERIC" "Unexpected error" "exit code $rc at line $line: $cmd" \
    "This is not one of the anticipated failure modes. Please keep ${LOG_FILE:-the console output} for analysis."
}
trap 'on_unexpected_error "$?" "$LINENO" "$BASH_COMMAND"' ERR

cleanup() {
  trap - ERR
  set +e
  if [[ -n $TMP_DIR && -d $TMP_DIR && $TMP_DIR == /tmp/h200-nvidia-offline.* ]]; then
    rm -rf -- "$TMP_DIR"
  fi
  stop_logging
  return 0
}
trap cleanup EXIT

usage() {
  cat <<EOF
Usage: sudo bash ./install_h200_nvidia_offline.sh [options]

Installs NVIDIA driver ${EXPECTED_DRIVER_VERSION} (open GPU kernel modules, DKMS) completely
offline from the packages in this bundle, then loads the driver and runs nvidia-smi.

Options:
  --dry-run                  Verify the system and the bundle and simulate the
                             installation. Nothing is changed.
  --replace-existing-driver  Allow replacing an installed NVIDIA driver of another
                             version (otherwise the installer stops).
  --skip-gpu-check           Continue even if no NVIDIA GPU is visible on the PCI bus
                             (the module cannot be loaded in that case).
  --install-kernel           Only install the kernel image shipped in this bundle
                             (bundles built with --with-kernel-image), then reboot.
  -h, --help                 Show this help.
EOF
}

parse_args() {
  while (($#)); do
    case $1 in
      --dry-run) DRY_RUN=1 ;;
      --replace-existing-driver) REPLACE_EXISTING=1 ;;
      --skip-gpu-check) SKIP_GPU_CHECK=1 ;;
      --install-kernel) INSTALL_KERNEL=1 ;;
      -h | --help) usage; exit "$E_OK" ;;
      *) printf 'Unknown option: %s\n\n' "$1" >&2; usage >&2; exit "$E_USAGE" ;;
    esac
    shift
  done
}

have() { command -v "$1" >/dev/null 2>&1; }

os_release_value() {
  local key=$1 k v
  while IFS='=' read -r k v; do
    if [[ $k == "$key" ]]; then
      v=${v#\"}; v=${v%\"}; v=${v#\'}; v=${v%\'}
      printf '%s\n' "$v"
      return 0
    fi
  done </etc/os-release
}

running_kernel() { uname -r; }

word_in() {
  local needle=$1 w
  shift
  for w in "$@"; do [[ $w == "$needle" ]] && return 0; done
  return 1
}

# -----------------------------------------------------------------------------
# Checks: operating system, architecture, bundle integrity, kernel
# -----------------------------------------------------------------------------
check_os_arch() {
  section "Operating system and architecture"
  [[ -r /etc/os-release ]] || finish "$E_OS" "Ubuntu version" "/etc/os-release not found"
  local id ver m darch
  id=$(os_release_value ID)
  ver=$(os_release_value VERSION_ID)
  [[ $id == ubuntu && $ver == "$EXPECTED_UBUNTU_VERSION" ]] ||
    finish "$E_OS" "Ubuntu version" "this system is '$id $ver', the bundle requires Ubuntu ${EXPECTED_UBUNTU_VERSION}" \
      "The packages in this bundle were resolved for Ubuntu ${EXPECTED_UBUNTU_VERSION} only."
  record PASS "Ubuntu version" "Ubuntu $ver ($(os_release_value VERSION_CODENAME))"
  m=$(uname -m)
  darch=$(dpkg --print-architecture)
  [[ $m == "$EXPECTED_UNAME_M" && $darch == "$EXPECTED_ARCH" ]] ||
    finish "$E_OS" "Architecture" "uname -m=$m, dpkg=$darch; the bundle requires ${EXPECTED_UNAME_M}/${EXPECTED_ARCH}"
  record PASS "Architecture" "$m / dpkg $darch"
}

load_bundle_conf() {
  local line
  [[ -r $BUNDLE_DIR/bundle.conf ]] || finish "$E_BUNDLE" "Bundle metadata" "bundle.conf is missing in $BUNDLE_DIR"
  while IFS= read -r line || [[ -n $line ]]; do
    [[ -z $line || $line == \#* ]] && continue
    [[ $line =~ ^([A-Z0-9_]+)=(.*)$ ]] || finish "$E_BUNDLE" "Bundle metadata" "malformed line in bundle.conf: $line"
    CONF[${BASH_REMATCH[1]}]=${BASH_REMATCH[2]}
  done <"$BUNDLE_DIR/bundle.conf"
  local k
  for k in DRIVER_VERSION UBUNTU_VERSION TARGET_ARCH KERNEL_ABIS KERNEL_COMPILER_MAP TOOLCHAIN_PACKAGES NVIDIA_PACKAGES DKMS_MODULE_NAME DKMS_MODULE_VERSION; do
    [[ -n ${CONF[$k]:-} ]] || finish "$E_BUNDLE" "Bundle metadata" "bundle.conf lacks $k"
  done
  [[ ${CONF[DRIVER_VERSION]} == "$EXPECTED_DRIVER_VERSION" && ${CONF[UBUNTU_VERSION]} == "$EXPECTED_UBUNTU_VERSION" && ${CONF[TARGET_ARCH]} == "$EXPECTED_ARCH" ]] ||
    finish "$E_BUNDLE" "Bundle metadata" "bundle.conf is for driver ${CONF[DRIVER_VERSION]} / Ubuntu ${CONF[UBUNTU_VERSION]} / ${CONF[TARGET_ARCH]}, this installer expects ${EXPECTED_DRIVER_VERSION} / ${EXPECTED_UBUNTU_VERSION} / ${EXPECTED_ARCH}"
}

verify_bundle() {
  section "Bundle integrity (SHA256SUMS, packages)"
  local f
  for f in SHA256SUMS bundle.conf MANIFEST.txt packages/Packages packages/Release; do
    [[ -s $BUNDLE_DIR/$f ]] || finish "$E_BUNDLE" "Bundle files" "$f is missing" \
      "Copy the complete unzipped directory ${BUNDLE_DIR##*/} from the USB drive again."
  done
  local out
  if ! out=$(cd -- "$BUNDLE_DIR" && sha256sum -c --quiet SHA256SUMS 2>&1); then
    sed -n 1,40p <<<"$out"
    finish "$E_BUNDLE" "SHA256 checksums" "one or more files are missing or corrupt (see above)" \
      "Re-copy ${BUNDLE_DIR##*/} (or re-extract the ZIP) from the USB drive."
  fi
  record PASS "SHA256 checksums" "$(wc -l <"$BUNDLE_DIR/SHA256SUMS") files verified"

  # Every package referenced by the repository index must be present.
  local missing=() name
  while IFS= read -r name; do
    [[ -f $PKG_DIR/$name ]] || missing+=("$name")
  done < <(awk '/^Filename: /{ sub(/^Filename: (\.\/)?/, ""); print }' "$PKG_DIR/Packages")
  ((${#missing[@]} == 0)) || finish "$E_BUNDLE" "Package files" "${#missing[@]} .deb file(s) missing: ${missing[*]:0:10}"
  local unlisted=()
  for f in "$PKG_DIR"/*.deb; do
    grep -qF -- "  packages/${f##*/}" "$BUNDLE_DIR/SHA256SUMS" || unlisted+=("${f##*/}")
  done
  ((${#unlisted[@]} == 0)) || record WARN "Package files" "ignored files not part of the bundle: ${unlisted[*]:0:10}"
  record PASS "Package files" "$(grep -c '^Package: ' "$PKG_DIR/Packages") .deb files present"
}

check_kernel() {
  section "Running kernel"
  KREL=$(running_kernel)
  local -a abis
  read -r -a abis <<<"${CONF[KERNEL_ABIS]}"
  if word_in "$KREL" "${abis[@]}"; then
    record PASS "Running kernel" "$KREL (supported by this bundle)"
    return 0
  fi
  local lines=("This bundle contains kernel headers (needed by DKMS) only for: ${abis[*]}")
  if [[ -n ${CONF[KERNEL_IMAGE_PACKAGES]:-} ]]; then
    lines+=("This bundle also contains kernel ${abis[0]}. Install it with:"
      "    sudo bash ./$(basename -- "$0") --install-kernel"
      "then reboot into ${abis[0]} and run this installer again.")
  else
    lines+=("Boot the H200 into one of the supported kernels, or rebuild the bundle on the online machine with:"
      "    ./build_h200_nvidia_offline_bundle.sh --kernel $KREL")
  fi
  finish "$E_KERNEL" "Running kernel" "$KREL is not supported by this bundle" "${lines[@]}"
}

# -----------------------------------------------------------------------------
# Hardware, existing drivers, Secure Boot
# -----------------------------------------------------------------------------
scan_pci() {
  NVIDIA_GPUS=()
  NVSWITCHES=()
  local d vendor class dev drv bdf name
  for d in /sys/bus/pci/devices/*; do
    [[ -r $d/vendor && -r $d/class ]] || continue
    vendor=$(<"$d/vendor")
    [[ $vendor == 0x10de ]] || continue
    class=$(<"$d/class")
    dev=$(<"$d/device")
    bdf=${d##*/}
    drv=none
    [[ -L $d/driver ]] && drv=$(basename -- "$(readlink -f -- "$d/driver")")
    name=""
    if have lspci; then name=$(lspci -s "$bdf" 2>/dev/null | sed -E 's/^[^ ]+ [^:]+: //' | sed -n 1p || true); fi
    case $class in
      0x0300* | 0x0302*) NVIDIA_GPUS+=("$bdf [10de:${dev#0x}] driver=$drv${name:+ ($name)}") ;;
      0x0680*) NVSWITCHES+=("$bdf [10de:${dev#0x}] driver=$drv") ;;
    esac
  done
}

check_hardware() {
  section "NVIDIA hardware (PCI)"
  scan_pci
  local g
  for g in "${NVIDIA_GPUS[@]}"; do info "GPU: $g"; done
  for g in "${NVSWITCHES[@]}"; do info "NVSwitch: $g"; done
  if ((${#NVIDIA_GPUS[@]} == 0)); then
    if ((SKIP_GPU_CHECK)); then
      record WARN "NVIDIA GPUs on PCI bus" "none found (continuing because of --skip-gpu-check)"
    else
      finish "$E_NOH200" "H200 detection" "no NVIDIA GPU is visible on the PCI bus" \
        "Check that the H200 is seated/powered and enabled in the BIOS (lspci -nn -d 10de: shows nothing)." \
        "Use --skip-gpu-check to install anyway."
    fi
  else
    record PASS "NVIDIA GPUs on PCI bus" "${#NVIDIA_GPUS[@]} found (model is confirmed by nvidia-smi later)"
  fi
  if ((${#NVSWITCHES[@]})); then
    record INFO "NVSwitch" "${#NVSWITCHES[@]} NVSwitch device(s): HGX system, Fabric Manager required"
  fi
}

check_existing_driver() {
  section "Existing NVIDIA driver installations"
  local conflicts=() same=() pkg ver st
  while IFS=$'\t' read -r st pkg ver; do
    [[ $st =~ ^.[iUFHWt] ]] || continue
    if [[ $pkg =~ ^linux-(modules|objects|signatures)-nvidia- ]]; then
      conflicts+=("$pkg $ver (Ubuntu prebuilt NVIDIA kernel modules)")
    elif [[ $pkg =~ ^(lib)?nvidia ]]; then
      if [[ $ver =~ $DRIVER_VERSION_RE ]]; then
        same+=("$pkg")
      elif [[ $ver =~ $ANY_DRIVER_VERSION_RE ]]; then
        conflicts+=("$pkg $ver")
      fi
    fi
  done < <(dpkg-query -W -f='${db:Status-Abbrev}\t${Package}\t${Version}\n' 2>/dev/null)

  if ((${#same[@]})); then
    record INFO "Existing ${EXPECTED_DRIVER_VERSION} packages" "${#same[@]} already installed (re-run / repair)"
  fi
  if [[ -x /usr/bin/nvidia-uninstall || -x /usr/bin/nvidia-installer ]]; then
    finish "$E_CONFLICT" "Existing NVIDIA driver" "a driver installed with NVIDIA's .run installer is present" \
      "Remove it first with: sudo /usr/bin/nvidia-uninstall   then reboot and run this installer again." \
      "Packages and .run installations must not be mixed."
  fi
  if ((${#conflicts[@]})); then
    if ((REPLACE_EXISTING)); then
      record WARN "Existing NVIDIA driver" "will be replaced: ${conflicts[*]}"
    else
      printf '  installed: %s\n' "${conflicts[@]}"
      finish "$E_CONFLICT" "Existing NVIDIA driver" "another NVIDIA driver version is installed (${#conflicts[@]} package(s))" \
        "The installer does not replace an existing driver unless asked to." \
        "To replace it with ${EXPECTED_DRIVER_VERSION}, run: sudo bash ./$(basename -- "$0") --replace-existing-driver"
    fi
  else
    record PASS "Existing NVIDIA driver" "no conflicting NVIDIA driver installed"
  fi
  if [[ -r /sys/module/nvidia/version ]]; then
    record INFO "Loaded nvidia module" "version $(</sys/module/nvidia/version)"
  fi
}

secure_boot_state() {
  local out f val
  if have mokutil && out=$(mokutil --sb-state 2>&1); then
    case $out in
      *"SecureBoot enabled"*) echo enabled; return ;;
      *"SecureBoot disabled"*) echo disabled; return ;;
    esac
  fi
  f=/sys/firmware/efi/efivars/SecureBoot-8be4df61-93ca-11d2-aa0d-00e098032b8c
  if [[ -r $f ]]; then
    val=$(od -An -t u1 -j 4 -N 1 -- "$f" 2>/dev/null | tr -d ' ' || true)
    if [[ $val == 1 ]]; then echo enabled; else echo disabled; fi
    return
  fi
  if [[ -d /sys/firmware/efi ]]; then echo unknown; else echo "disabled (legacy BIOS boot)"; fi
}

check_secure_boot() {
  section "UEFI Secure Boot"
  SB_STATE=$(secure_boot_state)
  case $SB_STATE in
    enabled) record INFO "Secure Boot" "ENABLED - the DKMS-built module must be signed with an enrolled MOK key" ;;
    unknown) record WARN "Secure Boot" "state could not be determined" ;;
    *) record INFO "Secure Boot" "$SB_STATE" ;;
  esac
  if [[ -r /sys/kernel/security/lockdown ]]; then
    info "Kernel lockdown: $(</sys/kernel/security/lockdown)"
  fi
}

check_disk_space() {
  local free
  free=$(df -Pk /usr | awk 'NR==2 {print $4}')
  if [[ $free =~ ^[0-9]+$ ]] && ((free < 3 * 1024 * 1024)); then
    record WARN "Disk space" "only $((free / 1024)) MiB free on /usr; about 3 GiB is recommended"
  fi
}

# -----------------------------------------------------------------------------
# Offline APT environment (the bundle is the ONLY package source)
# -----------------------------------------------------------------------------
setup_offline_apt() {
  section "Offline package repository (no network access)"
  TMP_DIR=$(mktemp -d /tmp/h200-nvidia-offline.XXXXXX)
  local a="$TMP_DIR/apt"
  mkdir -p -- "$a"/{lists/partial,archives/partial,cache,sources.list.d,preferences.d,log}
  ln -s -- "$PKG_DIR" "$TMP_DIR/repo"
  printf 'Types: deb\nURIs: file:%s\nSuites: ./\nArchitectures: %s\nTrusted: yes\n' "$TMP_DIR/repo" "$EXPECTED_ARCH" \
    >"$a/sources.list.d/h200-offline.sources"
  APT_CONF="$a/apt.conf"
  cat >"$APT_CONF" <<EOF
// Private APT configuration: the bundle in $PKG_DIR is the only package source.
#clear APT::Architecture-Variants;
#clear APT::Update::Pre-Invoke;
#clear APT::Update::Post-Invoke;
#clear APT::Update::Post-Invoke-Success;
#clear Acquire::IndexTargets::deb::DEP-11;
#clear Acquire::IndexTargets::deb::DEP-11-icons;
#clear Acquire::IndexTargets::deb::DEP-11-icons-small;
#clear Acquire::IndexTargets::deb::DEP-11-icons-large;
#clear Acquire::IndexTargets::deb::DEP-11-icons-hidpi;
#clear Acquire::IndexTargets::deb::CNF;
#clear Acquire::IndexTargets::deb::Contents-deb;
Dir::Etc::SourceList "$a/sources.list";
Dir::Etc::SourceParts "$a/sources.list.d";
Dir::Etc::Preferences "$a/preferences";
Dir::Etc::PreferencesParts "$a/preferences.d";
Dir::State::Lists "$a/lists";
Dir::Cache "$a/cache";
Dir::Cache::Archives "$a/archives";
Dir::Cache::pkgcache "";
Dir::Cache::srcpkgcache "";
APT::Sandbox::User "root";
APT::Install-Recommends "false";
APT::Install-Suggests "false";
APT::Get::Assume-Yes "true";
Acquire::Languages "none";
Acquire::Check-Date "false";
Acquire::Check-Valid-Until "false";
DPkg::Lock::Timeout "300";
Dpkg::Use-Pty "false";
DPkg::Options:: "--force-confdef";
DPkg::Options:: "--force-confold";
EOF
  local out
  if ! out=$(apt-get -c "$APT_CONF" -q --error-on=any update 2>&1); then
    printf '%s\n' "$out"
    finish "$E_BUNDLE" "Offline repository" "APT cannot read the bundle repository in $PKG_DIR"
  fi
  printf '%s\n' "$out" | log_only
  record PASS "Offline repository" "bundle packages indexed; host APT sources are not used"
}

apt_offline() { apt-get -c "$APT_CONF" "$@"; }

compiler_for_kernel() {
  local item
  for item in ${CONF[KERNEL_COMPILER_MAP]}; do
    if [[ ${item%%:*} == "$1" ]]; then printf '%s\n' "${item#*:}"; return 0; fi
  done
  return 1
}

plan_packages() {
  local gcc_pkg
  gcc_pkg=$(compiler_for_kernel "$KREL") || finish "$E_BUNDLE" "Bundle metadata" "no compiler recorded for kernel $KREL"
  read -r -a PHASE_A_PKGS <<<"${CONF[TOOLCHAIN_PACKAGES]}"
  PHASE_A_PKGS+=("$gcc_pkg" "linux-headers-$KREL")
  if [[ $SB_STATE == enabled && -n ${CONF[SECUREBOOT_PACKAGES]:-} ]]; then
    local -a sb
    read -r -a sb <<<"${CONF[SECUREBOOT_PACKAGES]}"
    PHASE_A_PKGS+=("${sb[@]}")
  fi
  read -r -a PHASE_B_PKGS <<<"${CONF[NVIDIA_PACKAGES]}"
  if ((${#NVSWITCHES[@]})) && [[ -n ${CONF[NVIDIA_FABRICMANAGER_PACKAGE]:-} ]]; then
    PHASE_B_PKGS+=("${CONF[NVIDIA_FABRICMANAGER_PACKAGE]}")
  fi
}

simulate_install() {
  section "Dependency check (APT simulation against this system, bundle only)"
  local sim="$TMP_DIR/simulation.txt" removals
  if ! apt_offline -s install --no-install-recommends "${PHASE_A_PKGS[@]}" "${PHASE_B_PKGS[@]}" >"$sim" 2>&1; then
    tail -n 40 "$sim"
    log_only <"$sim"
    local holds
    holds=$(apt-mark showhold 2>/dev/null | tr '\n' ' ' || true)
    finish "$E_DEPS" "Dependencies" "APT cannot satisfy all dependencies from the bundle on this system" \
      "${holds:+Held packages: $holds}" \
      "Typical causes: packages on this server are newer than the bundle, held packages, or" \
      "foreign-architecture packages. Run capture_target_state.sh on this server and rebuild the" \
      "bundle with: build_h200_nvidia_offline_bundle.sh --target-state <file>"
  fi
  log_only <"$sim"
  removals=$(awk '/^Remv /{print $2}' "$sim" | tr '\n' ' ')
  if [[ -n $removals ]]; then
    if ((REPLACE_EXISTING)); then
      record WARN "Package removals" "will remove: $removals"
    else
      finish "$E_CONFLICT" "Package removals" "installing would remove: $removals" \
        "Nothing is removed without consent. Re-run with --replace-existing-driver to allow it."
    fi
  fi
  record PASS "Dependencies" "all dependencies satisfiable offline ($(grep -c '^Inst ' "$sim") package(s) to install/upgrade)"
}

repair_dpkg_state() {
  local audit
  audit=$(dpkg --audit 2>&1 || true)
  if [[ -n $audit ]]; then
    printf '%s\n' "$audit" | log_only
    if ((DRY_RUN)); then
      record WARN "dpkg state" "unfinished package operations exist (dpkg --audit); they would be completed first"
      return 0
    fi
    info "Completing interrupted package operations (dpkg --configure -a)"
    if ! dpkg --configure -a; then
      if [[ -d /var/lib/dkms/${CONF[DKMS_MODULE_NAME]}/${CONF[DKMS_MODULE_VERSION]} ]]; then
        info "dpkg --configure -a failed (probably the earlier DKMS build); continuing so it can be diagnosed"
      else
        finish "$E_DEPS" "dpkg state" "dpkg --configure -a failed" "Inspect 'sudo dpkg --audit' and the log."
      fi
    fi
  fi
}

# -----------------------------------------------------------------------------
# Kernel-only mode
# -----------------------------------------------------------------------------
install_kernel_mode() {
  section "Kernel installation from the bundle (--install-kernel)"
  [[ -n ${CONF[KERNEL_IMAGE_PACKAGES]:-} ]] ||
    finish "$E_USAGE" "Kernel installation" "this bundle contains no kernel image (built without --with-kernel-image)"
  local -a abis pkgs
  read -r -a abis <<<"${CONF[KERNEL_ABIS]}"
  read -r -a pkgs <<<"${CONF[KERNEL_IMAGE_PACKAGES]}"
  pkgs+=("linux-headers-${abis[0]}")
  if [[ $(running_kernel) == "${abis[0]}" ]]; then
    finish "$E_OK" "Kernel installation" "already running ${abis[0]}; run the installer without --install-kernel"
  fi
  local sim="$TMP_DIR/kernel-sim.txt"
  apt_offline -s install --no-install-recommends "${pkgs[@]}" >"$sim" 2>&1 ||
    { tail -n 30 "$sim"; finish "$E_DEPS" "Kernel installation" "kernel packages cannot be installed from the bundle"; }
  if ((DRY_RUN)); then finish "$E_OK" "Kernel installation (simulated)" "${pkgs[*]} installable"; fi
  apt_offline install --no-install-recommends "${pkgs[@]}" ||
    finish "$E_DEPS" "Kernel installation" "apt-get failed to install ${pkgs[*]}"
  finish "$E_REBOOT" "Kernel installation" "${abis[0]} installed" \
    "Reboot and select 'Ubuntu, with Linux ${abis[0]}' (GRUB > Advanced options for Ubuntu) if it is not" \
    "the default, verify with 'uname -r', then run: sudo bash ./$(basename -- "$0")"
}

# -----------------------------------------------------------------------------
# Installation phases
# -----------------------------------------------------------------------------
dkms_name() { printf '%s\n' "${CONF[DKMS_MODULE_NAME]}"; }
dkms_ver() { printf '%s\n' "${CONF[DKMS_MODULE_VERSION]}"; }

dkms_installed_for_kernel() {
  dkms status -m "$(dkms_name)" -v "$(dkms_ver)" -k "$KREL" 2>/dev/null | awk '/: installed/ { found = 1 } END { exit !found }'
}

show_dkms_logs() {
  local f shown=0
  for f in "/var/lib/dkms/$(dkms_name)/$(dkms_ver)/build/make.log" "/var/lib/dkms/$(dkms_name)/$(dkms_ver)/$KREL/$(uname -m)/log/make.log"; do
    [[ -f $f ]] || continue
    shown=1
    printf -- '---- %s (last 60 lines; full file in the log) ----\n' "$f"
    tail -n 60 -- "$f"
    { printf -- '---- full %s ----\n' "$f"; cat -- "$f"; } | log_only
  done
  ((shown)) || info "No DKMS make.log found."
}

install_phase_a() {
  section "Phase A: toolchain, DKMS and kernel headers for $KREL"
  info "Installing: ${PHASE_A_PKGS[*]}"
  if ! apt_offline install --no-install-recommends "${PHASE_A_PKGS[@]}"; then
    finish "$E_DEPS" "Toolchain and headers" "apt-get/dpkg failed while installing the toolchain/headers (see above)" \
      "Check 'sudo dpkg --audit' and the log file."
  fi
  record PASS "Toolchain and DKMS" "$(dpkg-query -W -f='dkms ${Version}' dkms 2>/dev/null), $(gcc --version 2>/dev/null | sed -n 1p)"
  if [[ -f /lib/modules/$KREL/build/Makefile && -f /usr/src/linux-headers-$KREL/.config ]]; then
    record PASS "Kernel headers" "linux-headers-$KREL installed (/lib/modules/$KREL/build)"
  else
    finish "$E_HEADERS" "Kernel headers" "headers for $KREL are not usable (/lib/modules/$KREL/build missing)" \
      "Package linux-headers-$KREL is in the bundle but did not install correctly; see the log."
  fi
  local kcc
  kcc=$(sed -n -E '/^CONFIG_CC_VERSION_TEXT=/{s/^CONFIG_CC_VERSION_TEXT="(.*)"$/\1/p;q}' "/usr/src/linux-headers-$KREL/.config")
  info "Kernel was built with: $kcc"
}

install_phase_b() {
  section "Phase B: NVIDIA ${EXPECTED_DRIVER_VERSION} packages (DKMS builds the open kernel module)"
  info "Installing: ${PHASE_B_PKGS[*]}"
  if apt_offline install --no-install-recommends "${PHASE_B_PKGS[@]}"; then
    record PASS "NVIDIA packages" "${PHASE_B_PKGS[*]}"
    return 0
  fi
  if [[ -d /var/lib/dkms/$(dkms_name)/$(dkms_ver) ]] && ! dkms_installed_for_kernel; then
    record INFO "NVIDIA packages" "unpacked; configuration stopped because the DKMS build failed - diagnosing"
    PHASE_B_INCOMPLETE=1
    return 0
  fi
  dpkg --audit 2>&1 | sed -n 1,40p || true
  finish "$E_DEPS" "NVIDIA packages" "apt-get/dpkg failed while installing the NVIDIA packages (see above)"
}

ensure_dkms_module() {
  section "DKMS build of $(dkms_name)/$(dkms_ver) for $KREL"
  [[ -f /usr/src/$(dkms_name)-$(dkms_ver)/dkms.conf ]] ||
    finish "$E_DKMS" "DKMS source" "/usr/src/$(dkms_name)-$(dkms_ver)/dkms.conf is missing after installation"
  if ! dkms status -m "$(dkms_name)" -v "$(dkms_ver)" 2>/dev/null | awk 'NF { found = 1 } END { exit !found }'; then
    dkms add -m "$(dkms_name)" -v "$(dkms_ver)" || true
  fi
  if ! dkms_installed_for_kernel; then
    info "Running: dkms install -m $(dkms_name) -v $(dkms_ver) -k $KREL"
    local out rc=0
    out=$(dkms install -m "$(dkms_name)" -v "$(dkms_ver)" -k "$KREL" 2>&1) || rc=$?
    printf '%s\n' "$out"
    if ((rc != 0)) || ! dkms_installed_for_kernel; then
      show_dkms_logs
      if [[ $out == *"sign-file"* || $out == *"modules won't be signed"* ]] && [[ $SB_STATE == enabled ]]; then
        finish "$E_SECUREBOOT" "DKMS module signing" "DKMS could not sign the module while Secure Boot is enabled" \
          "Make sure shim-signed (update-secureboot-policy) and openssl are installed, then re-run."
      fi
      finish "$E_DKMS" "DKMS build" "building $(dkms_name)/$(dkms_ver) for $KREL failed (exit $rc)" \
        "See the make.log excerpt above. Typical causes: headers/compiler mismatch for $KREL." \
        "Kernel compiler: $(sed -n -E 's/^CONFIG_CC_VERSION_TEXT="(.*)"$/\1/p' "/usr/src/linux-headers-$KREL/.config" 2>/dev/null | sed -n 1p)"
    fi
  fi
  record PASS "DKMS build" "$(dkms status -m "$(dkms_name)" -v "$(dkms_ver)" -k "$KREL" 2>/dev/null | sed -n 1p)"
  if ((PHASE_B_INCOMPLETE)); then
    info "Finishing the package configuration that was interrupted by the DKMS failure"
    dpkg --configure -a || finish "$E_DEPS" "NVIDIA packages" "dpkg --configure -a failed after the DKMS retry"
    record PASS "NVIDIA packages" "configured after the DKMS retry"
  fi

  depmod -a "$KREL"
  record PASS "depmod" "module dependency database updated for $KREL"

  local ver lic file
  ver=$(modinfo -k "$KREL" -F version nvidia 2>/dev/null || true)
  lic=$(modinfo -k "$KREL" -F license nvidia 2>/dev/null || true)
  file=$(modinfo -k "$KREL" -F filename nvidia 2>/dev/null || true)
  [[ $ver == "$EXPECTED_DRIVER_VERSION" ]] ||
    finish "$E_DKMS" "Kernel module" "modinfo reports nvidia version '${ver:-none}' for $KREL (expected ${EXPECTED_DRIVER_VERSION}; file: ${file:-none})" \
      "Another nvidia.ko shadows the DKMS module, or the build did not install it."
  if [[ $lic == "Dual MIT/GPL" ]]; then
    record PASS "Kernel module" "nvidia.ko ${ver} open GPU kernel module (license: $lic) at $file"
  else
    record WARN "Kernel module" "nvidia.ko ${ver} at $file reports license '$lic' (open modules report 'Dual MIT/GPL')"
  fi
}

dkms_mok_certificate() {
  local f v cert=""
  for f in /etc/dkms/framework.conf /etc/dkms/framework.conf.d/*.conf; do
    [[ -r $f ]] || continue
    v=$(sed -n -E "s/^[[:space:]]*mok_certificate=[\"']?([^\"']+)[\"']?.*/\1/p" "$f" | tail -n1)
    [[ -n $v ]] && cert=$v
  done
  if [[ -z $cert ]]; then
    if [[ -f /var/lib/shim-signed/mok/MOK.der ]]; then cert=/var/lib/shim-signed/mok/MOK.der; else cert=/var/lib/dkms/mok.pub; fi
  fi
  printf '%s\n' "$cert"
}

check_module_signing() {
  section "Secure Boot module signing"
  if [[ $SB_STATE != enabled ]]; then
    record PASS "Module signing" "not required (Secure Boot ${SB_STATE})"
    return 0
  fi
  local signer cert out
  signer=$(modinfo -k "$KREL" -F signer nvidia 2>/dev/null || true)
  cert=$(dkms_mok_certificate)
  if [[ -z $signer ]]; then
    finish "$E_SECUREBOOT" "Module signing" "Secure Boot is enabled but nvidia.ko is NOT signed" \
      "DKMS signs modules with $cert; make sure shim-signed and openssl are installed," \
      "then run: sudo dkms install -m $(dkms_name) -v $(dkms_ver) -k $KREL --force  and re-run this installer."
  fi
  info "nvidia.ko signed by: $signer"
  if ! have mokutil; then
    record WARN "MOK enrollment" "mokutil not available; cannot verify that $cert is enrolled"
    return 0
  fi
  out=$(mokutil --test-key "$cert" 2>&1 || true)
  case $out in
    *"already enrolled"*)
      record PASS "MOK enrollment" "$cert is enrolled" ;;
    *"already in the enrollment request"*)
      finish "$E_SECUREBOOT" "MOK enrollment" "$cert is queued for enrollment but not enrolled yet" \
        "Reboot, choose 'Enroll MOK' -> Continue -> Yes in the blue MOK manager screen and enter the" \
        "password you chose, then run: sudo bash ./$(basename -- "$0")" ;;
    *)
      finish "$E_SECUREBOOT" "MOK enrollment" "the DKMS signing key $cert is NOT enrolled - the kernel will reject nvidia.ko" \
        "Enroll it (needs console access for one reboot):" \
        "  1. sudo mokutil --import $cert        (choose a one-time password)" \
        "  2. sudo reboot   -> in the blue 'MOK manager' screen: Enroll MOK -> Continue -> Yes -> password" \
        "  3. sudo bash ./$(basename -- "$0")      (run this installer again)" \
        "(Alternatively disable Secure Boot in the BIOS/UEFI setup.)" ;;
  esac
}

handle_nouveau() {
  [[ -d /sys/module/nouveau ]] || return 0
  section "nouveau driver"
  if ((DRY_RUN)); then
    record WARN "nouveau" "nouveau is loaded; the installer will unload it or require a reboot"
    return 0
  fi
  if modprobe -r nouveau 2>/dev/null; then
    record PASS "nouveau" "nouveau was loaded and has been unloaded"
    return 0
  fi
  if ! modprobe --showconfig 2>/dev/null | grep -qE '^blacklist nouveau$'; then
    printf '# Written by install_h200_nvidia_offline.sh: nouveau must not claim the NVIDIA H200.\nblacklist nouveau\noptions nouveau modeset=0\n' >"$NOUVEAU_BLACKLIST"
    info "Created $NOUVEAU_BLACKLIST"
  fi
  if have update-initramfs; then update-initramfs -u -k "$KREL" || true; fi
  finish "$E_REBOOT" "nouveau" "nouveau is in use and cannot be unloaded; it is now blacklisted" \
    "Reboot, then run: sudo bash ./$(basename -- "$0")"
}

load_driver() {
  section "Loading the NVIDIA kernel module"
  local out rc loaded
  if [[ -r /sys/module/nvidia/version ]]; then
    loaded=$(</sys/module/nvidia/version)
    if [[ $loaded != "$EXPECTED_DRIVER_VERSION" ]]; then
      info "nvidia module $loaded is loaded; trying to unload it"
      if ! modprobe -r nvidia_uvm nvidia_drm nvidia_modeset nvidia 2>/dev/null; then
        finish "$E_REBOOT" "Module load" "an older nvidia module ($loaded) is loaded and in use" \
          "Reboot so that ${EXPECTED_DRIVER_VERSION} is loaded, then run: sudo bash ./$(basename -- "$0")"
      fi
    fi
  fi
  rc=0
  out=$(modprobe nvidia 2>&1) || rc=$?
  [[ -n $out ]] && printf '%s\n' "$out"
  if ((rc != 0)); then
    printf -- '---- kernel messages ----\n'
    dmesg 2>/dev/null | grep -iE 'nvidia|nvrm|nouveau|lockdown|module verification|key was rejected' | tail -n 40 || true
    case $out in
      *"Key was rejected by service"* | *"Required key not available"*)
        finish "$E_SECUREBOOT" "Module load" "the kernel rejected nvidia.ko: module signature not trusted (Secure Boot)" \
          "Enroll the DKMS key: sudo mokutil --import $(dkms_mok_certificate) ; reboot ; Enroll MOK ; re-run." ;;
      *"No such device"*)
        finish "$E_NOH200" "Module load" "nvidia.ko found no GPU it can drive (No such device)" \
          "The H200 is not visible to the driver: check lspci -nn -d 10de:, BIOS settings, and dmesg above." ;;
      *"Invalid module format"* | *"Exec format error"* | *"Unknown symbol"*)
        finish "$E_LOAD" "Module load" "nvidia.ko does not match the running kernel $KREL" \
          "Rebuild with: sudo dkms install -m $(dkms_name) -v $(dkms_ver) -k $KREL --force" ;;
      *)
        finish "$E_LOAD" "Module load" "modprobe nvidia failed (exit $rc): ${out:-no message}" \
          "See the kernel messages above." ;;
    esac
  fi
  if ! modprobe nvidia_uvm 2>/dev/null; then
    record WARN "nvidia_uvm" "nvidia_uvm could not be loaded (CUDA applications need it)"
  fi
  local procver=""
  [[ -r /proc/driver/nvidia/version ]] && procver=$(head -n1 /proc/driver/nvidia/version)
  printf '  %s\n' "$procver"
  if [[ $procver == *"$EXPECTED_DRIVER_VERSION"* ]]; then
    if [[ $procver == *"Open Kernel Module"* ]]; then
      record PASS "Module load" "NVIDIA ${EXPECTED_DRIVER_VERSION} open kernel module loaded"
    else
      record WARN "Module load" "NVIDIA ${EXPECTED_DRIVER_VERSION} loaded, but /proc/driver/nvidia/version does not say 'Open Kernel Module'"
    fi
  else
    finish "$E_LOAD" "Module load" "loaded driver is not ${EXPECTED_DRIVER_VERSION}: ${procver:-/proc/driver/nvidia/version missing}" \
      "Reboot and run the installer again."
  fi
}

start_fabric_manager() {
  ((${#NVSWITCHES[@]})) || return 0
  section "NVIDIA Fabric Manager (NVSwitch system)"
  local fm=${CONF[NVIDIA_FABRICMANAGER_PACKAGE]:-}
  if [[ -z $fm ]]; then
    record FAIL "Fabric Manager" "NVSwitch present but nvidia-fabricmanager ${EXPECTED_DRIVER_VERSION} is not in this bundle"
    FINAL_EXIT=$E_FM
    return 0
  fi
  if ! have systemctl; then
    record FAIL "Fabric Manager" "systemctl not available; start nvidia-fabricmanager manually"
    FINAL_EXIT=$E_FM
    return 0
  fi
  systemctl enable nvidia-fabricmanager.service || true
  systemctl restart nvidia-fabricmanager.service || true
  sleep 5
  if systemctl is-active --quiet nvidia-fabricmanager.service; then
    record PASS "Fabric Manager" "nvidia-fabricmanager.service active and enabled"
  else
    systemctl status --no-pager nvidia-fabricmanager.service 2>&1 | tail -n 20 || true
    record FAIL "Fabric Manager" "nvidia-fabricmanager.service is not running (multi-GPU CUDA will fail on HGX)"
    FINAL_EXIT=$E_FM
  fi
}

run_nvidia_smi() {
  section "nvidia-smi"
  have nvidia-smi || finish "$E_SMI" "nvidia-smi" "nvidia-smi is not installed"
  local out rc=0
  out=$(timeout 300 nvidia-smi 2>&1) || rc=$?
  printf '%s\n' "$out"
  if ((rc != 0)); then
    dmesg 2>/dev/null | grep -iE 'nvidia|nvrm' | tail -n 30 || true
    finish "$E_SMI" "nvidia-smi" "nvidia-smi failed (exit $rc)" "See the output and kernel messages above."
  fi
  timeout 300 nvidia-smi -q 2>&1 | log_only || true

  local q
  q=$(timeout 120 nvidia-smi --query-gpu=index,name,pci.bus_id,driver_version,memory.total --format=csv,noheader 2>&1) ||
    finish "$E_SMI" "nvidia-smi" "nvidia-smi --query-gpu failed: $q"
  printf '%s\n' "$q" | sed 's/^/  GPU /'
  local total h200 badver
  total=$(grep -c . <<<"$q" || true)
  h200=$(grep -cE '(^|[^G])H200' <<<"$q" || true)
  badver=$(awk -F', *' -v v="$EXPECTED_DRIVER_VERSION" '$4 != v' <<<"$q" | grep -c . || true)
  ((badver == 0)) || finish "$E_SMI" "nvidia-smi" "nvidia-smi reports a driver version other than ${EXPECTED_DRIVER_VERSION}"
  record PASS "nvidia-smi" "driver ${EXPECTED_DRIVER_VERSION}, ${total} GPU(s) visible"
  if ((h200 == 0)); then
    finish "$E_NOH200" "H200 detection" "no NVIDIA H200 among the GPUs reported by nvidia-smi" \
      "GPUs found: $(cut -d, -f2 <<<"$q" | sed 's/^ *//' | sort | uniq -c | tr -s ' ' | tr '\n' ';')" \
      "The driver itself is installed and working."
  fi
  record PASS "H200 detection" "${h200} x NVIDIA H200 detected"
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------
main() {
  parse_args "$@"
  if ((EUID != 0)) && ((DRY_RUN == 0)); then
    printf 'This installer must run as root: sudo bash ./%s\n(--dry-run can run without root)\n' "$(basename -- "$0")" >&2
    exit "$E_USAGE"
  fi
  start_logging
  printf '\n###############################################################################\n'
  printf '# install_h200_nvidia_offline.sh %s - %s\n' "$SCRIPT_VERSION" "$(date -u +'%Y-%m-%d %H:%M:%S UTC')"
  printf '# Bundle: %s\n' "$BUNDLE_DIR"
  printf '# Command: %s %s\n' "$0" "$*"
  printf '###############################################################################\n'

  check_os_arch
  load_bundle_conf
  verify_bundle
  check_secure_boot
  if ((INSTALL_KERNEL)); then
    setup_offline_apt
    install_kernel_mode
  fi
  check_kernel
  check_hardware
  check_existing_driver
  check_disk_space
  setup_offline_apt
  plan_packages
  repair_dpkg_state
  simulate_install

  if ((DRY_RUN)); then
    record INFO "Planned phase A" "${PHASE_A_PKGS[*]}"
    record INFO "Planned phase B" "${PHASE_B_PKGS[*]}"
    finish "$E_OK" "Dry run" "the system and the bundle are ready; nothing was changed"
  fi

  install_phase_a
  install_phase_b
  ensure_dkms_module
  check_module_signing
  handle_nouveau
  load_driver
  start_fabric_manager
  run_nvidia_smi

  if ((FINAL_EXIT == E_FM)); then
    trap - ERR
    final_report "FAILED - Fabric Manager is not running (exit code $E_FM); nvidia-smi works"
    exit "$E_FM"
  fi
  finish "$E_OK" "Installation" "NVIDIA ${EXPECTED_DRIVER_VERSION} open kernel module driver installed offline"
}

main "$@"
