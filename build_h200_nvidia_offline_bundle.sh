#!/usr/bin/env bash
# =============================================================================
#  build_h200_nvidia_offline_bundle.sh
#
#  Builds a self-contained, verified OFFLINE installation bundle for the
#  NVIDIA 615.71.09 data center driver (open GPU kernel modules, DKMS) for an
#  NVIDIA H200 server running Ubuntu 26.04 amd64 with a 7.0.0-*-generic kernel.
#
#  Run it on an Internet-connected Ubuntu 26.04 amd64 machine. Root is NOT
#  required and nothing is installed or reconfigured on the build machine:
#  every APT operation runs in a private, throw-away APT environment that lives
#  inside the working directory.
#
#  Result (exactly one file):
#      H200_NVIDIA_615.71.09_Ubuntu26.04_Offline.zip
#
#  Files that must sit next to this script:
#      install_h200_nvidia_offline.sh   (copied into the bundle)
#      capture_target_state.sh          (copied into the bundle)
# =============================================================================
set -Eeuo pipefail
shopt -s nullglob
umask 022
export LC_ALL=C LANG=C
export DEBIAN_FRONTEND=noninteractive

# -----------------------------------------------------------------------------
# Fixed build parameters. They are deliberately NOT command-line options so the
# driver version, Ubuntu release and architecture can never drift silently.
# -----------------------------------------------------------------------------
readonly SCRIPT_VERSION="1.0.0"
readonly SCRIPT_NAME="build_h200_nvidia_offline_bundle.sh"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
readonly SCRIPT_DIR

readonly DRIVER_VERSION="615.71.09"
readonly DRIVER_BRANCH="${DRIVER_VERSION%%.*}"
readonly UBUNTU_VERSION="26.04"
readonly UBUNTU_REPO_TAG="ubuntu2604"
readonly TARGET_ARCH="amd64"
readonly TARGET_UNAME_M="x86_64"
readonly DEFAULT_KERNEL_SPEC="7.0.0-generic"

readonly NVIDIA_REPO_PACKAGE="nvidia-driver-local-repo-${UBUNTU_REPO_TAG}-${DRIVER_VERSION}"
readonly NVIDIA_REPO_PACKAGE_VERSION="1.0-1"
readonly NVIDIA_REPO_DEB="${NVIDIA_REPO_PACKAGE}_${NVIDIA_REPO_PACKAGE_VERSION}_${TARGET_ARCH}.deb"
# Official NVIDIA download locations for data center driver local repositories,
# tried in this order. Only https:// URLs on nvidia.com hosts are used.
readonly -a NVIDIA_REPO_URLS=(
  "https://developer.download.nvidia.com/compute/nvidia-driver/${DRIVER_VERSION}/local_installers/${NVIDIA_REPO_DEB}"
  "https://us.download.nvidia.com/tesla/${DRIVER_VERSION}/${NVIDIA_REPO_DEB}"
  "https://international.download.nvidia.com/tesla/${DRIVER_VERSION}/${NVIDIA_REPO_DEB}"
)
# Pre-downloaded NVIDIA files are looked up here first (see download_nvidia_repo.sh).
readonly NVIDIA_DOWNLOAD_DIRNAME="nvidia-downloads"

# Official Ubuntu archive (all three pockets of the release; no -proposed,
# no -backports, no PPAs).
readonly UBUNTU_ARCHIVE_URL="http://archive.ubuntu.com/ubuntu"
readonly UBUNTU_SECURITY_URL="http://security.ubuntu.com/ubuntu"
readonly UBUNTU_KEYRING="/usr/share/keyrings/ubuntu-archive-keyring.gpg"
readonly UBUNTU_COMPONENTS="main restricted universe multiverse"

readonly BUNDLE_NAME="H200_NVIDIA_${DRIVER_VERSION}_Ubuntu${UBUNTU_VERSION}_Offline"
readonly ZIP_NAME="${BUNDLE_NAME}.zip"
readonly INSTALLER_NAME="install_h200_nvidia_offline.sh"
readonly CAPTURE_NAME="capture_target_state.sh"
readonly WORKDIR_MARKER=".h200-nvidia-bundle-workdir"
readonly MIN_FREE_KIB=$((5 * 1024 * 1024))

# Version strings that belong to this exact driver release, e.g. 615.71.09-1,
# 615.71.09-0ubuntu1 (optionally with an epoch).
readonly DRIVER_VERSION_RE="^([0-9]+:)?${DRIVER_VERSION//./\\.}([-+~].*)?\$"
# Anything that looks like *some* NVIDIA driver release (NNN.NN[.NN]).
readonly ANY_DRIVER_VERSION_RE='^([0-9]+:)?[0-9]{3}\.[0-9]+(\.[0-9]+)?([-+~].*)?$'

# NVIDIA package roles. The first five are mandatory (requested explicitly);
# the others are added when the local repository provides them.
readonly -a NVIDIA_REQUIRED_ROLES=(nvidia-dkms-open nvidia-kernel-source-open nvidia-kernel-common libnvidia-compute nvidia-open)
readonly -a NVIDIA_OPTIONAL_ROLES=(nvidia-utils nvidia-compute-utils nvidia-firmware nvidia-driver-pinning)

# Ubuntu toolchain packages that are bundled and installed explicitly (their
# dependencies are collected recursively). gcc-NN matching the compiler that
# built each target kernel is added automatically.
readonly -a TOOLCHAIN_REQUIRED=(dkms build-essential make kmod openssl)
readonly -a SECUREBOOT_PACKAGES=(mokutil)

# -----------------------------------------------------------------------------
# Runtime state
# -----------------------------------------------------------------------------
STEP_NO=0
BUILD_OK=0
TEE_PID=""
BUILD_LOG=""
WARNINGS=()

KERNEL_SPECS=()
NVIDIA_REPO_DEB_ARG=""
NVIDIA_DOWNLOAD_DIR=""
TARGET_STATE_ARG=""
WITH_KERNEL_IMAGE=0
KEEP_WORKDIR=0
WORKDIR=""
OUTPUT_DIR=""

UBUNTU_CODENAME=""
NVIDIA_REPO_DEB_PATH=""
NVIDIA_REPO_SOURCE=""
NVIDIA_REPO_SHA256=""
NV_ROOT=""
NV_REPO_DIR=""
NV_SUITE=""
NV_COMPONENTS=""
NV_KEYRING=""
NV_TRUSTED=0

APT_DIR=""
APT_CONF=""
VERIFY_DIR=""
VERIFY_CONF=""
STAGE_DIR=""
PKG_DIR=""

TARGET_STATE_DIR=""
TARGET_KERNEL=""
TARGET_STATUS=""

declare -A NV_VER=()            # NVIDIA local repo: package -> version (amd64/all)
declare -A NV_FILE=()           # NVIDIA local repo: package -> Filename (relative to the repo)
declare -A ROLE_PKG=()          # role -> real package name
declare -A ROOT_ROLE=()         # explicitly requested package -> category
declare -A HEADERS_COMMON=()    # kernel ABI -> linux-headers common package
declare -A KERNEL_GCC_PKG=()    # kernel ABI -> gcc-NN package
declare -A KERNEL_CC_TEXT=()    # kernel ABI -> CONFIG_CC_VERSION_TEXT
declare -A PKG_VER=()           # resolved package -> version
declare -A PKG_ARCH=()          # resolved package -> architecture
declare -A PKG_REL=()           # resolved package -> release string reported by APT
declare -A PKG_FILE=()          # resolved package -> .deb file name in packages/
SELECTED_ABIS=()
NVIDIA_ROOTS=()
EXTRA_NVIDIA_ROOTS=()
FABRICMANAGER_PKG=""
TOOLCHAIN_ROOTS=()
SECUREBOOT_ROOTS=()
KERNEL_ROOTS=()
KERNEL_IMAGE_PKGS=()
RESOLUTION_PASSES=()
DKMS_MODULE_NAME=""
DKMS_MODULE_VERSION=""
DKMS_CONF_PKG=""
NVIDIA_SMI_PKG=""
GSP_FIRMWARE_PKG=""
NVML_PKG=""
LIBCUDA_PKG=""

# -----------------------------------------------------------------------------
# Output helpers
# -----------------------------------------------------------------------------
step() { STEP_NO=$((STEP_NO + 1)); printf '\n==== [%02d] %s ====\n' "$STEP_NO" "$*"; }
info() { printf '  [INFO] %s\n' "$*"; }
ok()   { printf '  [ OK ] %s\n' "$*"; }
warn() { printf '  [WARN] %s\n' "$*" >&2; WARNINGS+=("$*"); }
die() {
  local first=$1 line
  shift
  printf '\n[FATAL] %s\n' "$first" >&2
  for line in "$@"; do printf '        %s\n' "$line" >&2; done
  printf '\nBUILD FAILED - no ZIP was created.\n' >&2
  if [[ -n $BUILD_LOG ]]; then printf 'Build log: %s\n' "$BUILD_LOG" >&2; fi
  exit 1
}

on_error() {
  local rc=$1 line=$2 cmd=$3
  # Failures inside subshells/process substitutions are reported by the caller.
  [[ $BASHPID == "$$" ]] || return 0
  printf '\n[FATAL] Unexpected error (exit code %s) at line %s: %s\n' "$rc" "$line" "$cmd" >&2
  if [[ -n $BUILD_LOG ]]; then printf 'Build log: %s\n' "$BUILD_LOG" >&2; fi
}
trap 'on_error "$?" "$LINENO" "$BASH_COMMAND"' ERR

start_logging() {
  BUILD_LOG=$1
  exec 3>&1 4>&2
  exec > >(tee -a -- "$BUILD_LOG") 2>&1
  TEE_PID=$!
}

stop_logging() {
  if [[ -n $TEE_PID ]]; then
    exec 1>&3 2>&4
    wait "$TEE_PID" 2>/dev/null || true
    TEE_PID=""
  fi
}

on_exit() {
  local rc=$?
  trap - ERR
  set +e
  if ((rc == 0 && BUILD_OK == 1 && KEEP_WORKDIR == 0)) && [[ -n $WORKDIR && -f $WORKDIR/$WORKDIR_MARKER ]]; then
    stop_logging
    rm -rf -- "$WORKDIR"
  else
    if ((rc != 0)) && [[ -n $WORKDIR && -d $WORKDIR ]]; then
      printf 'Working directory kept for inspection: %s\n' "$WORKDIR" >&2
    fi
    stop_logging
  fi
}
trap on_exit EXIT

usage() {
  cat <<EOF
Usage: ${SCRIPT_NAME} [options]

Builds ${ZIP_NAME}
on an Internet-connected Ubuntu ${UBUNTU_VERSION} ${TARGET_ARCH} machine. Root is not required.

Options:
  --kernel SPEC          Target kernel. Either a kernel family such as
                         "${DEFAULT_KERNEL_SPEC}" (default: every Ubuntu ${UBUNTU_VERSION}
                         7.0.0-NN-generic ABI found in the archive is bundled and
                         reported) or an exact ABI such as "7.0.0-38-generic"
                         (recommended: run 'uname -r' on the H200). Can be
                         repeated or given as a comma separated list.
  --target-state FILE    Archive produced by ${CAPTURE_NAME} on the H200.
                         The H200's running kernel is then selected
                         automatically and dependencies are additionally
                         resolved against the exact package set installed on
                         the H200.
  --nvidia-repo-deb FILE Use an already downloaded copy of
                         ${NVIDIA_REPO_DEB}
                         (from nvidia.com) instead of downloading it.
  --nvidia-download-dir DIR
                         Folder for the NVIDIA download (default:
                         ./${NVIDIA_DOWNLOAD_DIRNAME} next to this script). A file
                         already there is verified and reused; a new download is
                         saved there so re-runs do not download it again.
  --with-kernel-image    Also bundle linux-image/linux-modules for the single
                         selected kernel ABI, so the H200 can be moved to that
                         kernel offline (installer option --install-kernel).
  --workdir DIR          Working directory (default: ./h200_nvidia_bundle_work).
                         It is deleted after a successful build.
  --output-dir DIR       Where the ZIP is written (default: current directory).
  --keep-workdir         Do not delete the working directory after success.
  -h, --help             Show this help.

Fixed parameters: NVIDIA ${DRIVER_VERSION} (open kernel modules), Ubuntu ${UBUNTU_VERSION}, ${TARGET_ARCH}.
EOF
}

# -----------------------------------------------------------------------------
# Generic helpers
# -----------------------------------------------------------------------------
# Canonical absolute path ("/.", "//", "a/../b" normalised); the path need not exist.
abs_path() {
  local p=$1
  [[ $p == /* ]] || p="$PWD/$p"
  realpath -m -s -- "$p"
}

# True if path $1 is $2 or inside $2.
path_within() { [[ $1 == "$2" || $1 == "$2"/* ]]; }

os_release_value() {
  local key=$1 file=$2 k v
  while IFS='=' read -r k v; do
    if [[ $k == "$key" ]]; then
      v=${v#\"}; v=${v%\"}; v=${v#\'}; v=${v%\'}
      printf '%s\n' "$v"
      return 0
    fi
  done <"$file"
  return 0
}

have() { command -v "$1" >/dev/null 2>&1; }

in_list() {
  local needle=$1 item
  shift
  for item in "$@"; do [[ $item == "$needle" ]] && return 0; done
  return 1
}

fetch_to_stdout() {
  if have curl; then
    curl --fail --location --silent --show-error --retry 3 --retry-delay 3 \
      --connect-timeout 20 --max-time 180 "$1"
  else
    wget --quiet --tries=3 --timeout=30 --output-document=- "$1"
  fi
}

download_https() {
  local url=$1 dest=$2
  rm -f -- "$dest"
  if have curl; then
    curl --fail --location --proto '=https' --proto-redir '=https' --tlsv1.2 \
      --retry 3 --retry-delay 5 --connect-timeout 30 \
      --silent --show-error --output "$dest" "$url"
  else
    wget --https-only --secure-protocol=TLSv1_2 --tries=3 --timeout=60 \
      --quiet --output-document="$dest" "$url"
  fi
}

sha256_of() { sha256sum -- "$1" | awk '{print $1}'; }
size_of() { stat -c %s -- "$1"; }
human_mib() { awk -v b="$1" 'BEGIN { printf "%.1f MiB", b / 1048576 }'; }

deb_field() { dpkg-deb -f -- "$1" "$2" 2>/dev/null || true; }

# File name APT uses when downloading package=version (epoch ':' -> %3a).
deb_filename() {
  local name=$1 ver=$2 arch=$3
  printf '%s_%s_%s.deb\n' "$name" "${ver//:/%3a}" "$arch"
}

join_by() {
  local sep=$1 out="" item
  shift
  for item in "$@"; do out+="${out:+$sep}$item"; done
  printf '%s\n' "$out"
}

decompress_index() {
  case $1 in
    *.gz) gzip -dc -- "$1" ;;
    *.xz) xz -dc -- "$1" ;;
    *.bz2) bzip2 -dc -- "$1" ;;
    *.zst) zstd -qdc -- "$1" ;;
    *) cat -- "$1" ;;
  esac
}

# Prints "name<TAB>version<TAB>architecture<TAB>filename" for every stanza of a Packages index.
parse_packages_index() {
  awk 'BEGIN { RS = ""; FS = "\n" }
       {
         p = v = a = f = ""
         for (i = 1; i <= NF; i++) {
           if ($i ~ /^Package:/)           { p = $i; sub(/^Package:[ \t]*/, "", p) }
           else if ($i ~ /^Version:/)      { v = $i; sub(/^Version:[ \t]*/, "", v) }
           else if ($i ~ /^Architecture:/) { a = $i; sub(/^Architecture:[ \t]*/, "", a) }
           else if ($i ~ /^Filename:/)     { f = $i; sub(/^Filename:[ \t]*/, "", f) }
         }
         if (p != "") print p "\t" v "\t" a "\t" f
       }'
}

apt_get() { apt-get -c "$APT_CONF" "$@"; }
apt_cache() { apt-cache -c "$APT_CONF" "$@"; }

# Prints "name<TAB>candidate" for every given package APT knows about.
apt_candidates() {
  apt-cache -c "$1" policy "${@:2}" 2>/dev/null | awk '
    /^[^ ].*:$/      { name = $0; sub(/:$/, "", name); next }
    /^  Candidate: / { c = $0; sub(/^  Candidate: /, "", c); print name "\t" c }'
}

# Parses "apt-get -s" output into "Inst|Remv<TAB>name<TAB>version<TAB>arch<TAB>release".
parse_simulation() {
  awk '
    /^Inst / {
      name = $2; line = $0
      sub(/^Inst [^ ]+ /, "", line)
      if (substr(line, 1, 1) == "[") sub(/^\[[^]]*\] /, "", line)
      if (substr(line, 1, 1) != "(") next
      line = substr(line, 2)
      ver = line; sub(/ .*$/, "", ver)
      rest = line; sub(/^[^ ]+ ?/, "", rest)
      arch = ""; rel = rest
      if (match(rest, /\[[^]]*\]\)/)) {
        arch = substr(rest, RSTART + 1, RLENGTH - 3)
        rel = substr(rest, 1, RSTART - 1)
      }
      sub(/[ ,]+$/, "", rel)
      sub(/:.*$/, "", name)
      print "Inst\t" name "\t" ver "\t" arch "\t" rel
    }
    /^Remv / {
      name = $2
      ver = $3; gsub(/[][]/, "", ver)
      print "Remv\t" name "\t" ver "\t\t"
    }' "$1"
}

# -----------------------------------------------------------------------------
# Argument parsing
# -----------------------------------------------------------------------------
parse_args() {
  local -a parts
  while (($#)); do
    case $1 in
      --kernel)
        (($# >= 2)) || die "--kernel requires a value"
        IFS=',' read -r -a parts <<<"$2"
        KERNEL_SPECS+=("${parts[@]}")
        shift 2
        ;;
      --kernel=*)
        IFS=',' read -r -a parts <<<"${1#*=}"
        KERNEL_SPECS+=("${parts[@]}")
        shift
        ;;
      --target-state)
        (($# >= 2)) || die "--target-state requires a file"
        TARGET_STATE_ARG=$2; shift 2 ;;
      --target-state=*) TARGET_STATE_ARG=${1#*=}; shift ;;
      --nvidia-repo-deb)
        (($# >= 2)) || die "--nvidia-repo-deb requires a file"
        NVIDIA_REPO_DEB_ARG=$2; shift 2 ;;
      --nvidia-repo-deb=*) NVIDIA_REPO_DEB_ARG=${1#*=}; shift ;;
      --nvidia-download-dir)
        (($# >= 2)) || die "--nvidia-download-dir requires a directory"
        NVIDIA_DOWNLOAD_DIR=$2; shift 2 ;;
      --nvidia-download-dir=*) NVIDIA_DOWNLOAD_DIR=${1#*=}; shift ;;
      --with-kernel-image) WITH_KERNEL_IMAGE=1; shift ;;
      --workdir)
        (($# >= 2)) || die "--workdir requires a directory"
        WORKDIR=$2; shift 2 ;;
      --workdir=*) WORKDIR=${1#*=}; shift ;;
      --output-dir)
        (($# >= 2)) || die "--output-dir requires a directory"
        OUTPUT_DIR=$2; shift 2 ;;
      --output-dir=*) OUTPUT_DIR=${1#*=}; shift ;;
      --keep-workdir) KEEP_WORKDIR=1; shift ;;
      -h | --help) usage; exit 0 ;;
      *) die "Unknown option: $1" "Run '${SCRIPT_NAME} --help' for usage." ;;
    esac
  done

  local cleaned=() s
  for s in "${KERNEL_SPECS[@]}"; do
    s=${s//[[:space:]]/}
    [[ -n $s ]] && cleaned+=("$s")
  done
  KERNEL_SPECS=("${cleaned[@]}")
  ((${#KERNEL_SPECS[@]})) || KERNEL_SPECS=("$DEFAULT_KERNEL_SPEC")

  WORKDIR=$(abs_path "${WORKDIR:-./h200_nvidia_bundle_work}")
  OUTPUT_DIR=$(abs_path "${OUTPUT_DIR:-.}")
  [[ -n $NVIDIA_REPO_DEB_ARG ]] && NVIDIA_REPO_DEB_ARG=$(abs_path "$NVIDIA_REPO_DEB_ARG")
  NVIDIA_DOWNLOAD_DIR=$(abs_path "${NVIDIA_DOWNLOAD_DIR:-$SCRIPT_DIR/$NVIDIA_DOWNLOAD_DIRNAME}")
  [[ -n $TARGET_STATE_ARG ]] && TARGET_STATE_ARG=$(abs_path "$TARGET_STATE_ARG")

  # APT source entries cannot contain whitespace in paths.
  [[ $WORKDIR =~ [[:space:]] ]] && die "The working directory path must not contain whitespace: '$WORKDIR'" "Use --workdir with a path without spaces."
  [[ -z $WORKDIR || $WORKDIR == / ]] && die "Refusing to use / as working directory."
  # The working directory is wiped when a build starts and deleted after success.
  local what path
  for what in "--output-dir:$OUTPUT_DIR" "--nvidia-download-dir:$NVIDIA_DOWNLOAD_DIR" "--nvidia-repo-deb:$NVIDIA_REPO_DEB_ARG" "--target-state:$TARGET_STATE_ARG"; do
    path=${what#*:}
    [[ -n $path ]] || continue
    if path_within "$path" "$WORKDIR"; then
      die "${what%%:*} ($path) is inside the working directory $WORKDIR," \
        "which is wiped when a build starts and deleted after a successful build. Use a location outside it."
    fi
  done
  return 0
}

# -----------------------------------------------------------------------------
# Step 1 - build machine verification
# -----------------------------------------------------------------------------
check_build_host() {
  step "Verifying the build machine (Ubuntu ${UBUNTU_VERSION}, ${TARGET_ARCH}, tools, Internet)"

  [[ -r /etc/os-release ]] || die "/etc/os-release is missing; cannot verify the Ubuntu version."
  local id version_id
  id=$(os_release_value ID /etc/os-release)
  version_id=$(os_release_value VERSION_ID /etc/os-release)
  UBUNTU_CODENAME=$(os_release_value VERSION_CODENAME /etc/os-release)
  [[ $id == ubuntu ]] || die "This machine is not Ubuntu (ID='$id'). Run the builder on Ubuntu ${UBUNTU_VERSION} ${TARGET_ARCH}."
  [[ $version_id == "$UBUNTU_VERSION" ]] || die "This machine runs Ubuntu '$version_id', but Ubuntu ${UBUNTU_VERSION} is required." \
    "The dependency set must be resolved by the same APT/dpkg release that the H200 runs."
  [[ -n $UBUNTU_CODENAME ]] || die "VERSION_CODENAME is missing from /etc/os-release."
  ok "Ubuntu ${version_id} (${UBUNTU_CODENAME})"

  local m
  m=$(uname -m)
  [[ $m == "$TARGET_UNAME_M" ]] || die "Machine architecture is '$m'; ${TARGET_UNAME_M} (${TARGET_ARCH}) is required."
  have dpkg || die "dpkg is not installed."
  local darch
  darch=$(dpkg --print-architecture)
  [[ $darch == "$TARGET_ARCH" ]] || die "dpkg architecture is '$darch'; ${TARGET_ARCH} is required."
  ok "Architecture ${m} / dpkg ${darch}"

  local -a tools=(apt-get apt-cache dpkg dpkg-deb dpkg-query sha256sum gzip xz zip unzip awk sed grep sort uniq find tar mktemp xargs stat df head tail cut tr wc date uname tee bash)
  local missing=() t
  for t in "${tools[@]}"; do have "$t" || missing+=("$t"); done
  have curl || have wget || missing+=("curl-or-wget")
  if ((${#missing[@]})); then
    die "Required tools are missing: ${missing[*]}" \
      "Install them first, for example:" \
      "  sudo apt-get update && sudo apt-get install -y apt dpkg coreutils gzip xz-utils zip unzip gawk sed grep findutils tar curl"
  fi
  ok "Required tools present (apt $(apt-get --version | awk 'NR==1{print $2}'), dpkg $(dpkg-query -W -f='${Version}' dpkg 2>/dev/null))"

  [[ -r $UBUNTU_KEYRING ]] || die "Ubuntu archive keyring $UBUNTU_KEYRING is missing (package ubuntu-keyring)."
  ok "Ubuntu archive keyring: $UBUNTU_KEYRING"

  local free_kib parent
  parent=$(dirname -- "$WORKDIR")
  mkdir -p -- "$parent" "$OUTPUT_DIR" 2>/dev/null || true
  [[ -d $OUTPUT_DIR && -w $OUTPUT_DIR ]] || die "The output directory $OUTPUT_DIR cannot be created or is not writable."
  [[ -d $parent && -w $parent ]] || die "Cannot create the working directory under $parent (not writable)."
  free_kib=$(df -Pk -- "$parent" | awk 'NR==2 {print $4}')
  if [[ $free_kib =~ ^[0-9]+$ ]] && ((free_kib < MIN_FREE_KIB)); then
    die "Not enough free disk space in $parent: $((free_kib / 1024)) MiB free, at least $((MIN_FREE_KIB / 1024)) MiB needed."
  fi
  ok "Free space in $parent: $((free_kib / 1024)) MiB"

  local release
  if ! release=$(fetch_to_stdout "${UBUNTU_ARCHIVE_URL}/dists/${UBUNTU_CODENAME}/Release"); then
    die "Cannot reach the official Ubuntu archive (${UBUNTU_ARCHIVE_URL})." \
      "This machine must have Internet access. If a proxy is required, export http_proxy/https_proxy" \
      "(and configure Acquire::http::Proxy for APT) and run the script again."
  fi
  grep -qx "Version: ${UBUNTU_VERSION}" <<<"$release" ||
    die "The archive suite '${UBUNTU_CODENAME}' does not report 'Version: ${UBUNTU_VERSION}'."
  ok "Internet access verified: ${UBUNTU_ARCHIVE_URL} serves ${UBUNTU_CODENAME} (${UBUNTU_VERSION})"

  local f
  for f in "$INSTALLER_NAME" "$CAPTURE_NAME"; do
    [[ -f $SCRIPT_DIR/$f ]] || die "$f must be located next to ${SCRIPT_NAME} (expected $SCRIPT_DIR/$f)."
    bash -n "$SCRIPT_DIR/$f" || die "$SCRIPT_DIR/$f has a shell syntax error."
  done
  ok "Companion scripts found: $INSTALLER_NAME, $CAPTURE_NAME"

  if [[ -n $NVIDIA_REPO_DEB_ARG ]]; then
    [[ -f $NVIDIA_REPO_DEB_ARG ]] || die "--nvidia-repo-deb: file not found: $NVIDIA_REPO_DEB_ARG"
  fi
  if [[ -n $TARGET_STATE_ARG ]]; then
    [[ -f $TARGET_STATE_ARG ]] || die "--target-state: file not found: $TARGET_STATE_ARG"
  fi
  if ((EUID == 0)); then
    info "Running as root is not required; nothing will be installed on this machine either way."
  fi
}

# -----------------------------------------------------------------------------
# Step 2 - clean working directory
# -----------------------------------------------------------------------------
prepare_workdir() {
  step "Creating a clean working directory"
  if [[ -e $WORKDIR ]]; then
    if [[ -f $WORKDIR/$WORKDIR_MARKER ]]; then
      info "Removing the previous working directory created by this script: $WORKDIR"
      rm -rf -- "$WORKDIR"
    elif [[ -d $WORKDIR && -z $(ls -A -- "$WORKDIR") ]]; then
      :
    else
      die "'$WORKDIR' already exists and was not created by this script; refusing to delete it." \
        "Remove it yourself or choose another location with --workdir."
    fi
  fi
  mkdir -p -- "$WORKDIR"/{download,tmp,stage}
  : >"$WORKDIR/$WORKDIR_MARKER"

  # Move the early console log into the working directory and keep logging there.
  local early_log=$BUILD_LOG
  stop_logging
  cat -- "$early_log" >"$WORKDIR/build.log"
  rm -f -- "$early_log"
  start_logging "$WORKDIR/build.log"

  STAGE_DIR="$WORKDIR/stage/$BUNDLE_NAME"
  PKG_DIR="$STAGE_DIR/packages"
  mkdir -p -- "$PKG_DIR"
  ok "Working directory: $WORKDIR"
  ok "Build log: $BUILD_LOG"
}

# -----------------------------------------------------------------------------
# Steps 3/4 - obtain and verify the NVIDIA local repository package
# -----------------------------------------------------------------------------
verify_nvidia_repo_deb() {
  local f=$1 pkg ver arch
  [[ -s $f ]] || return 1
  dpkg-deb --info -- "$f" >/dev/null 2>&1 || return 1
  # Reads the whole data archive: catches truncated / partially downloaded files.
  if ! dpkg-deb --fsys-tarfile -- "$f" >/dev/null 2>&1; then
    warn "$f is truncated or corrupt (incomplete download?)"
    return 1
  fi
  pkg=$(deb_field "$f" Package)
  ver=$(deb_field "$f" Version)
  arch=$(deb_field "$f" Architecture)
  [[ $pkg == "$NVIDIA_REPO_PACKAGE" ]] || { warn "Unexpected package name in $f: '$pkg' (expected $NVIDIA_REPO_PACKAGE)"; return 1; }
  [[ $ver == "$NVIDIA_REPO_PACKAGE_VERSION" ]] || { warn "Unexpected package version in $f: '$ver' (expected $NVIDIA_REPO_PACKAGE_VERSION)"; return 1; }
  [[ $arch == "$TARGET_ARCH" ]] || { warn "Package architecture in $f is '$arch', expected ${TARGET_ARCH}"; return 1; }
  return 0
}

# If FILE.sha256 exists next to FILE (written by download_nvidia_repo.sh), it must match.
check_sidecar_sha256() {
  local f=$1 expected actual
  [[ -f $f.sha256 ]] || return 0
  expected=$(awk 'NR == 1 { print $1 }' "$f.sha256")
  actual=$(sha256_of "$f")
  [[ $expected == "$actual" ]]
}

nvidia_manual_download_help() {
  printf '%s\n' \
    "Download it on any computer with Internet access (browser, curl, wget or download_nvidia_repo.sh):" \
    "${NVIDIA_REPO_URLS[@]/#/  }" \
    "  (NVIDIA download page: https://developer.nvidia.com/datacenter-driver-downloads?target_os=Linux&target_arch=x86_64&Distribution=Ubuntu&target_version=26.04&target_type=deb_local)" \
    "and save it, without renaming it, as:" \
    "  ${NVIDIA_DOWNLOAD_DIR}/${NVIDIA_REPO_DEB}" \
    "then run this builder again (or pass --nvidia-repo-deb /path/to/${NVIDIA_REPO_DEB})."
}

obtain_nvidia_repo_deb() {
  step "Obtaining ${NVIDIA_REPO_DEB}"
  NVIDIA_REPO_DEB_PATH=""

  if [[ -n $NVIDIA_REPO_DEB_ARG ]]; then
    [[ $(basename -- "$NVIDIA_REPO_DEB_ARG") == "$NVIDIA_REPO_DEB" ]] ||
      die "--nvidia-repo-deb must point to a file named exactly ${NVIDIA_REPO_DEB}" \
        "Got: $(basename -- "$NVIDIA_REPO_DEB_ARG"). A different driver version is never substituted."
    check_sidecar_sha256 "$NVIDIA_REPO_DEB_ARG" ||
      die "$NVIDIA_REPO_DEB_ARG does not match its checksum file $NVIDIA_REPO_DEB_ARG.sha256 (corrupt or incomplete copy)."
    NVIDIA_REPO_DEB_PATH=$NVIDIA_REPO_DEB_ARG
    NVIDIA_REPO_SOURCE="file supplied with --nvidia-repo-deb ($NVIDIA_REPO_DEB_ARG)"
    info "Using the supplied file $NVIDIA_REPO_DEB_ARG"
  else
    # 1. A copy that was downloaded before (manually or by download_nvidia_repo.sh).
    local candidate
    for candidate in "$NVIDIA_DOWNLOAD_DIR/$NVIDIA_REPO_DEB" "$PWD/$NVIDIA_REPO_DEB" "$SCRIPT_DIR/$NVIDIA_REPO_DEB"; do
      [[ -f $candidate ]] || continue
      if ! check_sidecar_sha256 "$candidate"; then
        warn "$candidate does not match $candidate.sha256 (incomplete or corrupt) - ignoring it"
        continue
      fi
      if verify_nvidia_repo_deb "$candidate"; then
        NVIDIA_REPO_DEB_PATH=$candidate
        NVIDIA_REPO_SOURCE="pre-downloaded file $candidate"
        if [[ -f $candidate.source.txt ]]; then
          NVIDIA_REPO_SOURCE+=" ($(sed -n 's/^url=//p' "$candidate.source.txt" | sed -n 1p))"
        fi
        ok "Found a pre-downloaded copy: $candidate"
        break
      fi
      warn "$candidate exists but is not a valid ${NVIDIA_REPO_PACKAGE} package - ignoring it"
    done

    # 2. Otherwise download it from NVIDIA into the download folder (kept for re-runs).
    if [[ -z $NVIDIA_REPO_DEB_PATH ]]; then
      local dir=$NVIDIA_DOWNLOAD_DIR url
      if ! mkdir -p -- "$dir" 2>/dev/null || [[ ! -w $dir ]]; then
        dir="$WORKDIR/download"
        info "$NVIDIA_DOWNLOAD_DIR is not writable; downloading into $dir"
      fi
      for url in "${NVIDIA_REPO_URLS[@]}"; do
        info "Downloading from official NVIDIA location: $url"
        info "(the file is large; this can take several minutes)"
        if download_https "$url" "$dir/$NVIDIA_REPO_DEB.part" && verify_nvidia_repo_deb "$dir/$NVIDIA_REPO_DEB.part"; then
          mv -f -- "$dir/$NVIDIA_REPO_DEB.part" "$dir/$NVIDIA_REPO_DEB"
          (cd -- "$dir" && sha256sum -- "$NVIDIA_REPO_DEB") >"$dir/$NVIDIA_REPO_DEB.sha256"
          printf 'url=%s\ndownloaded_utc=%s\n' "$url" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >"$dir/$NVIDIA_REPO_DEB.source.txt"
          NVIDIA_REPO_DEB_PATH="$dir/$NVIDIA_REPO_DEB"
          NVIDIA_REPO_SOURCE=$url
          if [[ $dir == "$NVIDIA_DOWNLOAD_DIR" ]]; then
            ok "Saved to $NVIDIA_REPO_DEB_PATH (reused by later builds)"
          else
            ok "Saved to $NVIDIA_REPO_DEB_PATH (inside the working directory: deleted after the build; make $NVIDIA_DOWNLOAD_DIR writable to keep it)"
          fi
          break
        fi
        rm -f -- "$dir/$NVIDIA_REPO_DEB.part"
        info "Not available (or not a valid package) at: $url"
      done
    fi
    if [[ -z $NVIDIA_REPO_DEB_PATH ]]; then
      local help
      mapfile -t help < <(nvidia_manual_download_help)
      die "The NVIDIA package ${NVIDIA_REPO_DEB} could not be downloaded from any official NVIDIA location." \
        "Possible causes: a firewall/proxy blocks *.nvidia.com, or NVIDIA has not published driver" \
        "${DRIVER_VERSION} as a local repository for Ubuntu ${UBUNTU_VERSION} (${UBUNTU_REPO_TAG}) at these URLs." \
        "" "${help[@]}" "" \
        "The builder never substitutes another driver version or the .run installer."
    fi
  fi

  verify_nvidia_repo_deb "$NVIDIA_REPO_DEB_PATH" ||
    die "${NVIDIA_REPO_DEB_PATH} is not a valid ${TARGET_ARCH} package named ${NVIDIA_REPO_PACKAGE} ${NVIDIA_REPO_PACKAGE_VERSION}."
  NVIDIA_REPO_SHA256=$(sha256_of "$NVIDIA_REPO_DEB_PATH")
  ok "Present: $NVIDIA_REPO_DEB_PATH ($(human_mib "$(size_of "$NVIDIA_REPO_DEB_PATH")"))"
  ok "Package=${NVIDIA_REPO_PACKAGE}  Version=${NVIDIA_REPO_PACKAGE_VERSION}  Architecture=${TARGET_ARCH}"
  ok "SHA256 ${NVIDIA_REPO_SHA256}"
}

# -----------------------------------------------------------------------------
# Step 5 - extract the NVIDIA local repository (no installation on this host)
# -----------------------------------------------------------------------------
extract_nvidia_repo() {
  step "Extracting the NVIDIA local repository into the working directory (not installed on this machine)"
  NV_ROOT="$WORKDIR/nvidia-local-repo"
  mkdir -p -- "$NV_ROOT"
  dpkg-deb -x -- "$NVIDIA_REPO_DEB_PATH" "$NV_ROOT" ||
    die "Cannot extract $NVIDIA_REPO_DEB_PATH (truncated or corrupt?)." \
      "Delete it (and its .sha256 file) and run the builder again to download it anew."

  # Use the APT source definition shipped inside the package itself.
  local re='^[[:space:]]*deb[[:space:]]+(\[([^]]*)\][[:space:]]+)?([^[:space:]]+)[[:space:]]+([^[:space:]]+)([[:space:]]+(.*))?$'
  local f line opts="" uri="" p signed_by=""
  for f in "$NV_ROOT"/etc/apt/sources.list.d/*.list; do
    while IFS= read -r line || [[ -n $line ]]; do
      line=${line%%#*}
      [[ $line =~ $re ]] || continue
      opts=${BASH_REMATCH[2]}
      uri=${BASH_REMATCH[3]}
      NV_SUITE=${BASH_REMATCH[4]}
      NV_COMPONENTS=${BASH_REMATCH[6]}
      break 2
    done <"$f"
  done

  if [[ -n $uri ]]; then
    [[ $uri == file:* ]] || die "Unexpected repository URI in the NVIDIA package: $uri (expected file:...)"
    p=${uri#file:}
    p=${p#//}
    NV_REPO_DIR="$NV_ROOT${p%/}"
    if [[ $opts =~ (^|[[:space:]])signed-by=([^[:space:]]+) ]]; then signed_by=${BASH_REMATCH[2]}; fi
    if [[ $opts =~ (^|[[:space:]])trusted=yes ]]; then NV_TRUSTED=1; fi
    info "APT source shipped by NVIDIA: deb [${opts}] ${uri} ${NV_SUITE} ${NV_COMPONENTS}"
  else
    # Fallback: flat repository = directory that contains the Packages index.
    local idx
    idx=$(find "$NV_ROOT" -type f \( -name Packages -o -name Packages.gz -o -name Packages.xz \) | awk '{print length($0) "\t" $0}' | sort -n | sed -n 1p | cut -f2-)
    [[ -n $idx ]] || die "No APT repository (Packages index) found inside ${NVIDIA_REPO_DEB}."
    NV_REPO_DIR=$(dirname -- "$idx")
    NV_SUITE="/"
    NV_COMPONENTS=""
    info "No APT source file found in the package; using flat repository $NV_REPO_DIR"
  fi
  [[ -d $NV_REPO_DIR ]] || die "Repository directory referenced by the NVIDIA package does not exist after extraction: $NV_REPO_DIR"

  # Keyring: the package ships it inside the repository directory and asks the
  # user to copy it to /usr/share/keyrings - we use it in place instead.
  if [[ -n $signed_by ]]; then
    NV_KEYRING=$(find "$NV_ROOT" -type f -name "$(basename -- "$signed_by")" | sed -n 1p)
  fi
  if [[ -z $NV_KEYRING ]]; then
    NV_KEYRING=$(find "$NV_ROOT" -type f \( -name '*keyring*.gpg' -o -name '*keyring*.asc' \) | sed -n 1p)
  fi

  local signed=0 base=$NV_REPO_DIR
  if [[ $NV_SUITE != */ ]]; then base="$NV_REPO_DIR/dists/$NV_SUITE"; fi
  if [[ -f $base/InRelease || -f $base/Release.gpg ]]; then signed=1; fi
  if ((NV_TRUSTED == 0)); then
    if ((signed)) && [[ -n $NV_KEYRING ]]; then
      ok "NVIDIA repository is signed; verifying with keyring $(basename -- "$NV_KEYRING")"
    elif ((signed)); then
      die "The NVIDIA repository is signed but its keyring was not found inside ${NVIDIA_REPO_DEB}."
    else
      NV_TRUSTED=1
      warn "The NVIDIA local repository has no signed Release file; its packages are trusted because ${NVIDIA_REPO_DEB} was obtained from NVIDIA (SHA256 ${NVIDIA_REPO_SHA256})."
    fi
  fi

  # Inventory of the NVIDIA repository.
  local -a indexes=()
  local d
  while IFS= read -r d; do
    if [[ -f $d/Packages ]]; then indexes+=("$d/Packages")
    elif [[ -f $d/Packages.gz ]]; then indexes+=("$d/Packages.gz")
    elif [[ -f $d/Packages.xz ]]; then indexes+=("$d/Packages.xz")
    fi
  done < <(find "$NV_REPO_DIR" -type f \( -name Packages -o -name Packages.gz -o -name Packages.xz \) -exec dirname {} \; | sort -u)
  ((${#indexes[@]})) || die "The NVIDIA repository at $NV_REPO_DIR contains no Packages index."

  local name ver arch file other=0 total=0 matching=0
  while IFS=$'\t' read -r name ver arch file; do
    total=$((total + 1))
    if [[ $arch != "$TARGET_ARCH" && $arch != all ]]; then other=$((other + 1)); continue; fi
    if [[ -n ${NV_VER[$name]:-} ]] && dpkg --compare-versions "${NV_VER[$name]}" ge "$ver"; then continue; fi
    NV_VER[$name]=$ver
    NV_FILE[$name]=$file
  done < <(for f in "${indexes[@]}"; do decompress_index "$f"; printf '\n'; done | parse_packages_index)

  for name in "${!NV_VER[@]}"; do
    [[ ${NV_VER[$name]} =~ $DRIVER_VERSION_RE ]] && matching=$((matching + 1))
  done
  ((${#NV_VER[@]})) || die "The NVIDIA repository contains no ${TARGET_ARCH} packages."
  ((matching)) || die "The NVIDIA repository contains no packages with version ${DRIVER_VERSION}." \
    "Versions found: $(for name in "${!NV_VER[@]}"; do printf '%s ' "${NV_VER[$name]}"; done | tr ' ' '\n' | sort -u | sed -n 1,10p | tr '\n' ' ')"
  ok "NVIDIA repository: $total package entries, ${#NV_VER[@]} for ${TARGET_ARCH}/all, $matching with version ${DRIVER_VERSION} ($other other-architecture entries ignored)"
}

# -----------------------------------------------------------------------------
# Private APT environments
# -----------------------------------------------------------------------------
write_apt_conf() {
  local dir=$1 conf=$2
  mkdir -p -- "$dir"/{lists/partial,archives/partial,cache,state,log,sources.list.d,preferences.d,trusted.gpg.d}
  : >"$dir/status-empty"
  {
    echo '// Private APT configuration generated by '"$SCRIPT_NAME"'. It does not touch the host APT setup.'
    echo '#clear APT::Architectures;'
    echo '#clear APT::Architecture-Variants;'
    echo '#clear APT::Update::Pre-Invoke;'
    echo '#clear APT::Update::Post-Invoke;'
    echo '#clear APT::Update::Post-Invoke-Success;'
    echo '#clear Acquire::IndexTargets::deb::DEP-11;'
    echo '#clear Acquire::IndexTargets::deb::DEP-11-icons;'
    echo '#clear Acquire::IndexTargets::deb::DEP-11-icons-small;'
    echo '#clear Acquire::IndexTargets::deb::DEP-11-icons-large;'
    echo '#clear Acquire::IndexTargets::deb::DEP-11-icons-hidpi;'
    echo '#clear Acquire::IndexTargets::deb::CNF;'
    echo '#clear Acquire::IndexTargets::deb::Contents-deb;'
    echo '#clear Acquire::IndexTargets::deb::Contents-udeb;'
    echo "APT::Architecture \"${TARGET_ARCH}\";"
    echo "APT::Architectures { \"${TARGET_ARCH}\"; };"
    echo 'APT::Install-Recommends "false";'
    echo 'APT::Install-Suggests "false";'
    echo 'APT::Get::AllowUnauthenticated "false";'
    echo 'Acquire::Languages "none";'
    echo 'Acquire::Retries "3";'
    echo "Dir::Etc::SourceList \"$dir/sources.list\";"
    echo "Dir::Etc::SourceParts \"$dir/sources.list.d\";"
    echo "Dir::Etc::Preferences \"$dir/preferences\";"
    echo "Dir::Etc::PreferencesParts \"$dir/preferences.d\";"
    echo "Dir::Etc::Trusted \"$dir/trusted.gpg\";"
    echo "Dir::Etc::TrustedParts \"$dir/trusted.gpg.d\";"
    echo "Dir::State \"$dir/state\";"
    echo "Dir::State::Lists \"$dir/lists\";"
    echo "Dir::State::status \"$dir/status-empty\";"
    echo "Dir::State::extended_states \"$dir/state/extended_states\";"
    echo "Dir::Cache \"$dir/cache\";"
    echo "Dir::Cache::Archives \"$dir/archives\";"
    echo 'Dir::Cache::pkgcache "";'
    echo 'Dir::Cache::srcpkgcache "";'
    echo "Dir::Log \"$dir/log\";"
    if ((EUID == 0)); then echo 'APT::Sandbox::User "root";'; fi
  } >"$conf"
}

setup_private_apt() {
  step "Creating a private APT environment (official Ubuntu ${UBUNTU_VERSION} archive + extracted NVIDIA repository)"
  APT_DIR="$WORKDIR/apt"
  APT_CONF="$APT_DIR/apt.conf"
  write_apt_conf "$APT_DIR" "$APT_CONF"

  local nv_auth
  if ((NV_TRUSTED)); then nv_auth="Trusted: yes"; else nv_auth="Signed-By: $NV_KEYRING"; fi
  {
    printf 'Types: deb\nURIs: %s\nSuites: %s %s-updates\nComponents: %s\nArchitectures: %s\nSigned-By: %s\n\n' \
      "$UBUNTU_ARCHIVE_URL" "$UBUNTU_CODENAME" "$UBUNTU_CODENAME" "$UBUNTU_COMPONENTS" "$TARGET_ARCH" "$UBUNTU_KEYRING"
    printf 'Types: deb\nURIs: %s\nSuites: %s-security\nComponents: %s\nArchitectures: %s\nSigned-By: %s\n\n' \
      "$UBUNTU_SECURITY_URL" "$UBUNTU_CODENAME" "$UBUNTU_COMPONENTS" "$TARGET_ARCH" "$UBUNTU_KEYRING"
    printf 'Types: deb\nURIs: file:%s\nSuites: %s\n' "$NV_REPO_DIR" "$NV_SUITE"
    [[ -n $NV_COMPONENTS ]] && printf 'Components: %s\n' "$NV_COMPONENTS"
    printf 'Architectures: %s\n%s\n' "$TARGET_ARCH" "$nv_auth"
  } >"$APT_DIR/sources.list.d/h200-bundle.sources"

  # Pin every package of the NVIDIA local repository to the exact version it
  # ships, so Ubuntu's own NVIDIA packages (other driver versions with
  # overlapping names) can never be selected instead.
  local name
  {
    echo "# NVIDIA ${DRIVER_VERSION}: always prefer the exact versions from the NVIDIA local repository."
    for name in $(printf '%s\n' "${!NV_VER[@]}" | sort); do
      printf 'Package: %s\nPin: version %s\nPin-Priority: 1001\n\n' "$name" "${NV_VER[$name]}"
    done
  } >"$APT_DIR/preferences"

  info "Downloading package indexes (Ubuntu ${UBUNTU_CODENAME}, ${UBUNTU_CODENAME}-updates, ${UBUNTU_CODENAME}-security; NVIDIA local)"
  if ! apt_get -q --error-on=any update; then
    die "APT could not download/verify the package indexes." "Check Internet/proxy access to ${UBUNTU_ARCHIVE_URL} and ${UBUNTU_SECURITY_URL}."
  fi
  ok "Package indexes downloaded and signature-verified"

  # Every NVIDIA package must now resolve to the version shipped by NVIDIA.
  local -a names
  mapfile -t names < <(printf '%s\n' "${!NV_VER[@]}" | sort)
  local cand bad=()
  declare -A seen=()
  while IFS=$'\t' read -r name cand; do
    seen[$name]=1
    [[ $cand == "${NV_VER[$name]}" ]] || bad+=("$name: candidate '$cand' != NVIDIA '${NV_VER[$name]}'")
  done < <(apt_candidates "$APT_CONF" "${names[@]}")
  for name in "${names[@]}"; do [[ -n ${seen[$name]:-} ]] || bad+=("$name: not visible to APT"); done
  ((${#bad[@]} == 0)) || die "APT does not select the NVIDIA local repository versions:" "${bad[@]}"
  ok "All ${#names[@]} NVIDIA repository packages are pinned to their NVIDIA ${DRIVER_VERSION} versions"
}

# -----------------------------------------------------------------------------
# Step 6 - NVIDIA package selection
# -----------------------------------------------------------------------------
role_candidates() {
  local b=$DRIVER_BRANCH v=$DRIVER_VERSION
  case $1 in
    nvidia-dkms-open) echo "nvidia-dkms-open nvidia-dkms-$b-open" ;;
    nvidia-kernel-source-open) echo "nvidia-kernel-source-open nvidia-kernel-source-$b-open" ;;
    nvidia-kernel-common) echo "nvidia-kernel-common nvidia-kernel-common-$b" ;;
    libnvidia-compute) echo "libnvidia-compute libnvidia-compute-$b" ;;
    nvidia-open) echo "nvidia-open nvidia-open-$b" ;;
    nvidia-utils) echo "nvidia-utils nvidia-utils-$b" ;;
    nvidia-compute-utils) echo "nvidia-compute-utils nvidia-compute-utils-$b" ;;
    nvidia-firmware) echo "nvidia-firmware nvidia-firmware-$b nvidia-firmware-$b-$v" ;;
    nvidia-fabricmanager) echo "nvidia-fabricmanager nvidia-fabricmanager-$b" ;;
    nvidia-driver-pinning) echo "nvidia-driver-pinning-$v nvidia-driver-pinning-$b" ;;
    *) return 1 ;;
  esac
}

match_role() {
  local c
  for c in $(role_candidates "$1"); do
    if [[ -n ${NV_VER[$c]:-} && ${NV_VER[$c]} =~ $DRIVER_VERSION_RE ]]; then
      printf '%s\n' "$c"
      return 0
    fi
  done
  return 1
}

similar_nvidia_names() {
  local stem=$1 out
  out=$(printf '%s\n' "${!NV_VER[@]}" | grep -F -- "$stem" | sort | sed -n 1,15p | tr '\n' ' ' || true)
  printf '%s\n' "${out:-none}"
}

select_nvidia_packages() {
  step "Selecting the NVIDIA ${DRIVER_VERSION} open GPU kernel module package set (headless / compute)"
  local role pkg missing=()
  for role in "${NVIDIA_REQUIRED_ROLES[@]}"; do
    if pkg=$(match_role "$role"); then
      ROLE_PKG[$role]=$pkg
      NVIDIA_ROOTS+=("$pkg")
      ROOT_ROLE[$pkg]="nvidia (requested: $role)"
      ok "$(printf '%-27s -> %s %s' "$role" "$pkg" "${NV_VER[$pkg]}")"
    else
      missing+=("$role")
    fi
  done
  if ((${#missing[@]})); then
    local lines=() stem
    for role in "${missing[@]}"; do
      stem=${role#lib}
      stem=${stem#nvidia-}
      [[ $stem == open ]] || stem=${stem%-open}
      lines+=("$role: none of [$(role_candidates "$role")] exists with version ${DRIVER_VERSION} in ${NVIDIA_REPO_DEB}")
      lines+=("    similar packages in the NVIDIA repository: $(similar_nvidia_names "$stem")")
    done
    die "Required NVIDIA ${DRIVER_VERSION} packages are unavailable:" "${lines[@]}" \
      "No package names are invented and no other driver version is substituted."
  fi

  for role in "${NVIDIA_OPTIONAL_ROLES[@]}"; do
    if pkg=$(match_role "$role"); then
      ROLE_PKG[$role]=$pkg
      NVIDIA_ROOTS+=("$pkg")
      ROOT_ROLE[$pkg]="nvidia (auxiliary: $role)"
      ok "$(printf '%-27s -> %s %s' "$role" "$pkg" "${NV_VER[$pkg]}")"
    else
      info "$(printf '%-27s -> not shipped as a separate package (dependencies decide)' "$role")"
    fi
  done

  if pkg=$(match_role nvidia-fabricmanager); then
    ROLE_PKG[nvidia-fabricmanager]=$pkg
    FABRICMANAGER_PKG=$pkg
    ROOT_ROLE[$pkg]="nvidia (Fabric Manager, installed only on NVSwitch/HGX systems)"
    ok "$(printf '%-27s -> %s %s (installed only if NVSwitch is detected)' nvidia-fabricmanager "$pkg" "${NV_VER[$pkg]}")"
  else
    warn "nvidia-fabricmanager ${DRIVER_VERSION} is not in the NVIDIA local repository. HGX H200 8-GPU (NVSwitch) systems need it for multi-GPU CUDA; nvidia-smi works without it."
  fi
}

# -----------------------------------------------------------------------------
# Optional: state captured on the H200 by capture_target_state.sh
# -----------------------------------------------------------------------------
load_target_state() {
  [[ -n $TARGET_STATE_ARG ]] || return 0
  step "Loading the H200 target state: $(basename -- "$TARGET_STATE_ARG")"
  local dir="$WORKDIR/target-state"
  mkdir -p -- "$dir"
  tar -xzf "$TARGET_STATE_ARG" -C "$dir" || die "Cannot extract $TARGET_STATE_ARG"
  local fmt
  fmt=$(find "$dir" -maxdepth 2 -type f -name FORMAT | sed -n 1p)
  [[ -n $fmt ]] || die "$TARGET_STATE_ARG was not created by ${CAPTURE_NAME} (FORMAT file missing)."
  TARGET_STATE_DIR=$(dirname -- "$fmt")
  local f
  for f in os-release uname-r dpkg-architecture dpkg-status; do
    [[ -s $TARGET_STATE_DIR/$f ]] || die "Target state is incomplete: $f is missing."
  done
  local tv ta
  tv=$(os_release_value VERSION_ID "$TARGET_STATE_DIR/os-release")
  ta=$(head -n1 "$TARGET_STATE_DIR/dpkg-architecture")
  TARGET_KERNEL=$(head -n1 "$TARGET_STATE_DIR/uname-r")
  TARGET_STATUS="$TARGET_STATE_DIR/dpkg-status"
  [[ $tv == "$UBUNTU_VERSION" ]] || die "The H200 runs Ubuntu '$tv', but this bundle targets Ubuntu ${UBUNTU_VERSION}."
  [[ $ta == "$TARGET_ARCH" ]] || die "The H200 dpkg architecture is '$ta', expected ${TARGET_ARCH}."
  ok "H200: Ubuntu $tv, $ta, running kernel $TARGET_KERNEL, $(grep -c '^Package: ' "$TARGET_STATUS") dpkg entries"
  if [[ -s $TARGET_STATE_DIR/dpkg-foreign-architectures ]]; then
    warn "The H200 has foreign dpkg architectures ($(tr '\n' ' ' <"$TARGET_STATE_DIR/dpkg-foreign-architectures")); only ${TARGET_ARCH} packages are bundled."
  fi
}

# -----------------------------------------------------------------------------
# Step 8/9 - exact kernel ABI discovery (never guessed)
# -----------------------------------------------------------------------------
select_kernels() {
  step "Determining the exact Ubuntu ${UBUNTU_VERSION} kernel header packages for: ${KERNEL_SPECS[*]}"
  local -a all_headers
  mapfile -t all_headers < <(apt_cache pkgnames linux-headers- | grep -E '^linux-headers-[0-9]+\.[0-9]+\.[0-9]+-[0-9]+-[a-z0-9-]+$' | sort -V)
  ((${#all_headers[@]})) || die "No versioned linux-headers packages are visible in the Ubuntu ${UBUNTU_VERSION} archive."

  local -a picked=()
  local spec base flav n abi re
  for spec in "${KERNEL_SPECS[@]}"; do
    if [[ $spec =~ ^([0-9]+\.[0-9]+\.[0-9]+)-([0-9]+)-([a-z][a-z0-9-]*)$ ]]; then
      if in_list "linux-headers-$spec" "${all_headers[@]}"; then
        picked+=("$spec")
        ok "Exact kernel ABI requested and available: $spec"
      else
        base=${BASH_REMATCH[1]}
        flav=${BASH_REMATCH[3]}
        re="^linux-headers-${base//./\\.}-[0-9]+-${flav}\$"
        die "Kernel '$spec' is not available: package linux-headers-$spec does not exist in Ubuntu ${UBUNTU_VERSION} (${UBUNTU_CODENAME}, -updates, -security)." \
          "Available ${base}-*-${flav} header packages: $(printf '%s\n' "${all_headers[@]}" | grep -E "$re" | sed 's/^linux-headers-//' | tr '\n' ' ')" \
          "No other kernel is substituted."
      fi
    elif [[ $spec =~ ^([0-9]+\.[0-9]+\.[0-9]+)-([a-z][a-z0-9-]*)$ ]]; then
      base=${BASH_REMATCH[1]}
      flav=${BASH_REMATCH[2]}
      re="^linux-headers-${base//./\\.}-[0-9]+-${flav}\$"
      local -a fam=()
      mapfile -t fam < <(printf '%s\n' "${all_headers[@]}" | grep -E "$re" | sed 's/^linux-headers-//')
      if ((${#fam[@]} == 0)); then
        local flavours others
        flavours=$(printf '%s\n' "${all_headers[@]}" | sed -n -E "s/^linux-headers-${base//./\\.}-[0-9]+-//p" | sort -u | tr '\n' ' ')
        others=$(printf '%s\n' "${all_headers[@]}" | sed -n -E "s/^linux-headers-([0-9]+\\.[0-9]+\\.[0-9]+)-[0-9]+-${flav}\$/\\1/p" | sort -uV | tr '\n' ' ')
        die "Kernel family '$spec' does not exist in Ubuntu ${UBUNTU_VERSION}: there is no linux-headers-${base}-NN-${flav} package." \
          "Flavours available for ${base}: ${flavours:-none}" \
          "Kernel versions available for flavour ${flav}: ${others:-none}" \
          "The bundle was NOT built. Re-run with --kernel set to one of the available kernels if appropriate."
      fi
      info "'$spec' is a kernel family, not an installable ABI. Ubuntu ${UBUNTU_VERSION} provides these exact ABIs:"
      for n in "${fam[@]}"; do info "    $n"; done
      picked+=("${fam[@]}")
    else
      die "Invalid --kernel value '$spec'. Use a family like 7.0.0-generic or an exact ABI like 7.0.0-38-generic."
    fi
  done
  mapfile -t picked < <(printf '%s\n' "${picked[@]}" | sort -uV)

  if [[ -n $TARGET_KERNEL ]]; then
    if in_list "$TARGET_KERNEL" "${picked[@]}"; then
      ok "The H200 runs $TARGET_KERNEL, which matches the requested kernel(s); only this ABI is bundled."
      picked=("$TARGET_KERNEL")
    elif in_list "linux-headers-$TARGET_KERNEL" "${all_headers[@]}"; then
      die "The H200 runs kernel $TARGET_KERNEL, which is not part of the requested kernel(s): ${KERNEL_SPECS[*]}" \
        "Re-run with --kernel $TARGET_KERNEL (or move the H200 to a requested kernel). Nothing is substituted silently."
    elif ((WITH_KERNEL_IMAGE)); then
      warn "The H200 runs $TARGET_KERNEL, whose headers are no longer in the Ubuntu archive. The bundle will contain kernel ${picked[*]} which the installer can install (--install-kernel)."
    else
      die "The H200 runs kernel $TARGET_KERNEL, but linux-headers-$TARGET_KERNEL is not available in the Ubuntu ${UBUNTU_VERSION} archive." \
        "DKMS cannot build for a kernel without its headers. Options:" \
        "  1. Update the H200 to an available kernel and capture the state again, or" \
        "  2. Re-run with --with-kernel-image --kernel <one available ABI> and use the installer's --install-kernel option." \
        "Available: ${picked[*]}"
    fi
  fi

  if ((WITH_KERNEL_IMAGE)) && ((${#picked[@]} != 1)); then
    die "--with-kernel-image requires exactly one kernel ABI, but ${#picked[@]} were selected: ${picked[*]}" \
      "Choose one with --kernel 7.0.0-NN-generic."
  fi

  # Verify each ABI is installable and find its common headers package from
  # the real dependency information.
  local -a hdr_pkgs=()
  for abi in "${picked[@]}"; do hdr_pkgs+=("linux-headers-$abi"); done
  declare -A cand=()
  local name c
  while IFS=$'\t' read -r name c; do cand[$name]=$c; done < <(apt_candidates "$APT_CONF" "${hdr_pkgs[@]}")
  for abi in "${picked[@]}"; do
    c=${cand[linux-headers-$abi]:-}
    [[ -n $c && $c != "(none)" ]] || die "linux-headers-$abi exists by name but has no installable candidate in Ubuntu ${UBUNTU_VERSION}."
    local deps common=""
    deps=$(apt_cache show --no-all-versions "linux-headers-$abi" | awk '!done && /^Depends:/ { sub(/^Depends:[ ]*/, ""); print; done = 1 }')
    local item
    while IFS= read -r item; do
      item=${item## }
      item=${item%% *}
      if [[ $item =~ ^linux-([a-z0-9.-]+-)?headers-[0-9] && $item != "linux-headers-$abi" ]]; then common=$item; break; fi
    done < <(tr ',' '\n' <<<"$deps")
    [[ -n $common ]] || die "Could not determine the common headers package of linux-headers-$abi from its Depends: $deps"
    HEADERS_COMMON[$abi]=$common
    SELECTED_ABIS+=("$abi")
    KERNEL_ROOTS+=("linux-headers-$abi")
    ROOT_ROLE[linux-headers-$abi]="kernel headers ($abi)"
    ROOT_ROLE[$common]="kernel headers common ($abi)"
    ok "$(printf '%-20s linux-headers-%s %s  (common: %s)' "$abi" "$abi" "$c" "$common")"
  done

  if ((WITH_KERNEL_IMAGE)); then
    abi=${SELECTED_ABIS[0]}
    local -a want=("linux-image-$abi" "linux-modules-extra-$abi")
    declare -A icand=()
    while IFS=$'\t' read -r name c; do icand[$name]=$c; done < <(apt_candidates "$APT_CONF" "${want[@]}")
    c=${icand[linux-image-$abi]:-}
    [[ -n $c && $c != "(none)" ]] || die "--with-kernel-image: linux-image-$abi is not available in Ubuntu ${UBUNTU_VERSION}."
    KERNEL_IMAGE_PKGS+=("linux-image-$abi")
    ROOT_ROLE[linux-image-$abi]="kernel image ($abi)"
    c=${icand[linux-modules-extra-$abi]:-}
    if [[ -n $c && $c != "(none)" ]]; then
      KERNEL_IMAGE_PKGS+=("linux-modules-extra-$abi")
      ROOT_ROLE[linux-modules-extra-$abi]="kernel extra modules ($abi)"
    fi
    KERNEL_ROOTS+=("${KERNEL_IMAGE_PKGS[@]}")
    ok "Kernel image packages bundled: ${KERNEL_IMAGE_PKGS[*]}"
  fi
}

detect_kernel_compilers() {
  step "Detecting the compiler used to build each target kernel (DKMS must use the same one)"
  local dir="$WORKDIR/tmp/kernel-inspect"
  mkdir -p -- "$dir"
  local -a hdr=()
  local abi
  for abi in "${SELECTED_ABIS[@]}"; do hdr+=("linux-headers-$abi"); done
  (cd -- "$dir" && apt_get -q download "${hdr[@]}") >/dev/null ||
    die "Could not download the kernel header packages for inspection: ${hdr[*]}"

  local deb x cfg gccver major cc_text pkg
  declare -A gcc_needed=()
  for abi in "${SELECTED_ABIS[@]}"; do
    deb=$(find "$dir" -maxdepth 1 -name "linux-headers-${abi}_*.deb" | sed -n 1p)
    [[ -n $deb ]] || die "Downloaded headers for $abi not found."
    x="$dir/x-$abi"
    mkdir -p -- "$x"
    dpkg-deb -x -- "$deb" "$x"
    cfg="$x/usr/src/linux-headers-$abi/.config"
    [[ -f $cfg ]] || cfg=$(find "$x" -path '*/linux-headers-*/.config' | sed -n 1p)
    [[ -n $cfg && -f $cfg ]] || die "linux-headers-$abi contains no kernel .config; cannot determine its compiler."
    cc_text=$(sed -n -E '/^CONFIG_CC_VERSION_TEXT=/{s/^CONFIG_CC_VERSION_TEXT="(.*)"$/\1/p;q}' "$cfg")
    KERNEL_CC_TEXT[$abi]=$cc_text
    if grep -qx 'CONFIG_CC_IS_GCC=y' "$cfg"; then
      gccver=$(sed -n -E '/^CONFIG_GCC_VERSION=/{s/^CONFIG_GCC_VERSION=([0-9]+)$/\1/p;q}' "$cfg")
      [[ $gccver =~ ^[0-9]+$ ]] || die "Cannot parse CONFIG_GCC_VERSION of $abi."
      major=$((gccver / 10000))
      pkg="gcc-$major"
      KERNEL_GCC_PKG[$abi]=$pkg
      gcc_needed[$pkg]=1
      ok "$(printf '%-20s built with: %s  -> bundling %s' "$abi" "$cc_text" "$pkg")"
    elif grep -qx 'CONFIG_CC_IS_CLANG=y' "$cfg"; then
      gccver=$(sed -n -E '/^CONFIG_CLANG_VERSION=/{s/^CONFIG_CLANG_VERSION=([0-9]+)$/\1/p;q}' "$cfg")
      major=$((gccver / 10000))
      pkg="clang-$major"
      KERNEL_GCC_PKG[$abi]=$pkg
      gcc_needed[$pkg]=1
      warn "$abi was built with clang ($cc_text); bundling $pkg."
    else
      die "Cannot determine the compiler of kernel $abi from its .config."
    fi
  done
  rm -rf -- "$dir"

  local -a gccs
  mapfile -t gccs < <(printf '%s\n' "${!gcc_needed[@]}" | sort -V)
  TOOLCHAIN_ROOTS=("${TOOLCHAIN_REQUIRED[@]}" "${gccs[@]}")
  for pkg in "${TOOLCHAIN_REQUIRED[@]}"; do ROOT_ROLE[$pkg]="toolchain"; done
  for pkg in "${gccs[@]}"; do ROOT_ROLE[$pkg]="toolchain (kernel compiler)"; done
}

verify_roots_available() {
  step "Verifying that every requested package exists in the configured official repositories"
  local -a all=("${NVIDIA_ROOTS[@]}" "${TOOLCHAIN_ROOTS[@]}" "${KERNEL_ROOTS[@]}" "${SECUREBOOT_PACKAGES[@]}")
  [[ -n $FABRICMANAGER_PKG ]] && all+=("$FABRICMANAGER_PKG")
  declare -A cand=()
  local name c missing=()
  while IFS=$'\t' read -r name c; do cand[$name]=$c; done < <(apt_candidates "$APT_CONF" "${all[@]}")
  for name in "${all[@]}"; do
    c=${cand[$name]:-}
    if [[ -z $c || $c == "(none)" ]]; then
      if in_list "$name" "${SECUREBOOT_PACKAGES[@]}"; then
        warn "$name is not available; Secure Boot key enrollment tools will not be bundled."
      else
        missing+=("$name")
      fi
      continue
    fi
    if in_list "$name" "${SECUREBOOT_PACKAGES[@]}"; then
      SECUREBOOT_ROOTS+=("$name")
      ROOT_ROLE[$name]="secure boot (MOK enrollment)"
    fi
  done
  ((${#missing[@]} == 0)) || die "These required packages are not available in Ubuntu ${UBUNTU_VERSION} / the NVIDIA repository:" "${missing[@]}"
  ok "${#all[@]} requested packages available"
}

# -----------------------------------------------------------------------------
# Step 7/10 - recursive dependency resolution with APT
# -----------------------------------------------------------------------------
merge_simulation() {
  local tsv=$1 label=$2 kind name ver arch rel added=0 removals=()
  while IFS=$'\t' read -r kind name ver arch rel; do
    if [[ $kind == Remv ]]; then removals+=("$name"); continue; fi
    if [[ -n ${PKG_VER[$name]:-} ]]; then
      [[ ${PKG_VER[$name]} == "$ver" ]] ||
        die "Dependency resolution produced two versions of $name: ${PKG_VER[$name]} and $ver ($label)."
      continue
    fi
    PKG_VER[$name]=$ver
    PKG_ARCH[$name]=$arch
    PKG_REL[$name]=$rel
    added=$((added + 1))
  done <"$tsv"
  info "$label: +$added new packages (total ${#PKG_VER[@]})"
  if ((${#removals[@]})); then
    warn "$label: installing on that system would REMOVE: ${removals[*]}"
  fi
}

resolve_dependencies() {
  step "Resolving the complete recursive dependency closure with APT"
  local -a roots=("${NVIDIA_ROOTS[@]}" "${TOOLCHAIN_ROOTS[@]}" "${KERNEL_ROOTS[@]}" "${SECUREBOOT_ROOTS[@]}")
  [[ -n $FABRICMANAGER_PKG ]] && roots+=("$FABRICMANAGER_PKG")
  info "Explicit packages (${#roots[@]}): ${roots[*]}"
  local sim tsv
  RESOLUTION_PASSES=()

  # Pass 1: against an EMPTY dpkg database. Nothing is assumed to be installed,
  # so every Depends/Pre-Depends of every package is followed recursively.
  sim="$WORKDIR/resolve-1-empty.txt"
  if ! apt_get -s install --no-install-recommends --no-install-suggests -o Dir::State::status="$APT_DIR/status-empty" "${roots[@]}" >"$sim" 2>&1; then
    tail -n 40 "$sim" >&2
    die "APT could not resolve the dependencies of the requested packages (full output: $sim)."
  fi
  parse_simulation "$sim" >"$sim.tsv"
  merge_simulation "$sim.tsv" "Pass 1 (empty system - full closure)"
  RESOLUTION_PASSES+=("Pass 1: full recursive closure against an empty dpkg database (nothing assumed installed)")

  # Pass 2: against this build machine's real dpkg database (a genuine Ubuntu
  # 26.04 system). Adds packages that APT would have to upgrade alongside on a
  # populated system (exact-version sibling packages). Best effort.
  if [[ -r /var/lib/dpkg/status ]]; then
    sim="$WORKDIR/resolve-2-buildhost.txt"
    if apt_get -s install --no-install-recommends --no-install-suggests -o Dir::State::status=/var/lib/dpkg/status "${roots[@]}" >"$sim" 2>&1; then
      parse_simulation "$sim" >"$sim.tsv"
      merge_simulation "$sim.tsv" "Pass 2 (this Ubuntu ${UBUNTU_VERSION} system as a reference target)"
      RESOLUTION_PASSES+=("Pass 2: resolution against the build machine's installed packages (upgrade siblings)")
    else
      warn "Pass 2 (resolution against this machine's installed packages) failed and was skipped; see $sim"
    fi
  fi

  # Pass 3: against the H200's own dpkg database, if it was captured.
  if [[ -n $TARGET_STATUS ]]; then
    sim="$WORKDIR/resolve-3-h200.txt"
    if ! apt_get -s install --no-install-recommends --no-install-suggests -o Dir::State::status="$TARGET_STATUS" "${roots[@]}" >"$sim" 2>&1; then
      tail -n 40 "$sim" >&2
      die "APT cannot install the package set on the H200 as captured (full output: $sim)."
    fi
    parse_simulation "$sim" >"$sim.tsv"
    merge_simulation "$sim.tsv" "Pass 3 (exact H200 package state)"
    RESOLUTION_PASSES+=("Pass 3: resolution against the exact dpkg database captured on the H200")
  fi
  ok "Dependency closure: ${#PKG_VER[@]} packages"
}

# -----------------------------------------------------------------------------
# Download and per-package verification
# -----------------------------------------------------------------------------
download_packages() {
  step "Downloading ${#PKG_VER[@]} packages (APT verifies every file against the signed indexes)"
  local -a specs
  local name
  mapfile -t specs < <(for name in "${!PKG_VER[@]}"; do
    [[ -f $PKG_DIR/$(deb_filename "$name" "${PKG_VER[$name]}" "${PKG_ARCH[$name]}") ]] || printf '%s=%s\n' "$name" "${PKG_VER[$name]}"
  done | sort)
  if ((${#specs[@]})); then
    if ! (cd -- "$PKG_DIR" && printf '%s\0' "${specs[@]}" | xargs -0 -n 40 apt-get -c "$APT_CONF" -q download); then
      die "Downloading packages failed (see the APT messages above)."
    fi
  fi

  local f ver arch problems=()
  for name in "${!PKG_VER[@]}"; do
    ver=${PKG_VER[$name]}
    arch=${PKG_ARCH[$name]}
    f=$(deb_filename "$name" "$ver" "$arch")
    if [[ ! -f $PKG_DIR/$f ]]; then problems+=("missing file $f"); continue; fi
    PKG_FILE[$name]=$f
    [[ $(deb_field "$PKG_DIR/$f" Package) == "$name" ]] || problems+=("$f: Package field mismatch")
    [[ $(deb_field "$PKG_DIR/$f" Version) == "$ver" ]] || problems+=("$f: Version field mismatch")
    case $(deb_field "$PKG_DIR/$f" Architecture) in
      "$TARGET_ARCH" | all) ;;
      *) problems+=("$f: architecture is not ${TARGET_ARCH}/all") ;;
    esac
    [[ -z $(deb_field "$PKG_DIR/$f" Architecture-Variant) && $f != *_amd64v3.deb ]] ||
      problems+=("$f: is an architecture variant build, not baseline ${TARGET_ARCH}")
  done
  local extra
  for f in "$PKG_DIR"/*.deb; do
    extra=1
    for name in "${!PKG_FILE[@]}"; do [[ ${PKG_FILE[$name]} == "$(basename -- "$f")" ]] && { extra=0; break; }; done
    ((extra)) && problems+=("unexpected file $(basename -- "$f")")
  done
  ((${#problems[@]} == 0)) || die "Downloaded packages failed verification:" "${problems[@]}"
  local total=0
  for f in "$PKG_DIR"/*.deb; do total=$((total + $(size_of "$f"))); done
  ok "${#PKG_FILE[@]} packages downloaded and verified ($(human_mib "$total"))"
}

deb_listing() { dpkg-deb -c -- "$1" | awk '{ for (i = 6; i <= NF; i++) if ($i ~ /^\.\//) { print $i; break } }'; }

# What the NVIDIA part of the bundle must contain, as patterns on .deb file lists.
payload_pattern() {
  case $1 in
    dkms) printf '%s\n' '^\./usr/src/[^/]+/dkms\.conf$' ;;
    smi) printf '%s\n' '^\./usr/bin/nvidia-smi$' ;;
    gsp) printf '%s\n' "^\\./(usr/)?lib/firmware/nvidia/${DRIVER_VERSION//./\\.}/gsp[^/]*\\.bin\$" ;;
    nvml) printf '%s\n' '/libnvidia-ml\.so\.[0-9]' ;;
    cuda) printf '%s\n' '/libcuda\.so\.[0-9]' ;;
  esac
}
payload_label() {
  case $1 in
    dkms) echo "DKMS kernel module source (/usr/src/*/dkms.conf)" ;;
    smi) echo "/usr/bin/nvidia-smi" ;;
    gsp) echo "GSP firmware /lib/firmware/nvidia/${DRIVER_VERSION}/gsp*.bin (mandatory for open kernel modules on H200)" ;;
    nvml) echo "NVML library libnvidia-ml.so.1 (needed by nvidia-smi)" ;;
    cuda) echo "CUDA driver library libcuda.so.1 (CUDA compute)" ;;
  esac
}
readonly -a PAYLOAD_KEYS=(dkms smi gsp nvml cuda)
declare -A PAYLOAD_PKG=()
PAYLOAD_MISSING=()
DKMS_CONF_PATH=""

scan_payload() {
  local name f listing key
  PAYLOAD_PKG=()
  PAYLOAD_MISSING=()
  for name in $(printf '%s\n' "${!PKG_FILE[@]}" | sort); do
    [[ -n ${NV_VER[$name]:-} ]] || continue
    f="$PKG_DIR/${PKG_FILE[$name]}"
    listing=$(deb_listing "$f")
    for key in "${PAYLOAD_KEYS[@]}"; do
      [[ -z ${PAYLOAD_PKG[$key]:-} ]] || continue
      if grep -qE "$(payload_pattern "$key")" <<<"$listing"; then
        PAYLOAD_PKG[$key]=$name
        [[ $key == dkms ]] && DKMS_CONF_PATH=$(grep -E "$(payload_pattern dkms)" <<<"$listing" | sed -n 1p)
      fi
    done
  done
  for key in "${PAYLOAD_KEYS[@]}"; do
    [[ -n ${PAYLOAD_PKG[$key]:-} ]] || PAYLOAD_MISSING+=("$key")
  done
}

# Looks inside the NVIDIA repository for the packages that ship what is missing.
repair_payload() {
  local name f listing key added=()
  declare -A resolved=()
  info "Searching all NVIDIA ${DRIVER_VERSION} packages for: ${PAYLOAD_MISSING[*]}"
  for name in $(printf '%s\n' "${!NV_VER[@]}" | sort); do
    [[ ${NV_VER[$name]} =~ $DRIVER_VERSION_RE ]] || continue
    [[ -z ${PKG_FILE[$name]:-} && -n ${NV_FILE[$name]:-} ]] || continue
    f="$NV_REPO_DIR/${NV_FILE[$name]#./}"
    [[ -f $f ]] || continue
    listing=$(deb_listing "$f")
    for key in "${PAYLOAD_MISSING[@]}"; do
      [[ -z ${resolved[$key]:-} ]] || continue
      if grep -qE "$(payload_pattern "$key")" <<<"$listing"; then
        resolved[$key]=$name
        if ! in_list "$name" "${added[@]}"; then
          added+=("$name")
          ROOT_ROLE[$name]="nvidia (provides $(payload_label "$key"))"
        fi
        ok "$(payload_label "$key") is shipped by $name"
      fi
    done
  done
  ((${#added[@]})) || return 1
  NVIDIA_ROOTS+=("${added[@]}")
  EXTRA_NVIDIA_ROOTS+=("${added[@]}")
  return 0
}

inspect_nvidia_payload() {
  step "Inspecting the NVIDIA packages (DKMS source, nvidia-smi, GSP firmware, NVML, CUDA driver library)"
  scan_payload
  if ((${#PAYLOAD_MISSING[@]})); then
    info "Not provided by the selected packages and their dependencies: ${PAYLOAD_MISSING[*]}"
    if repair_payload; then
      info "Adding NVIDIA package(s) ${EXTRA_NVIDIA_ROOTS[*]} and resolving their dependencies"
      resolve_dependencies
      download_packages
      step "Re-inspecting the NVIDIA packages"
      scan_payload
    fi
  fi

  local key problems=()
  for key in "${PAYLOAD_KEYS[@]}"; do
    if [[ -n ${PAYLOAD_PKG[$key]:-} ]]; then
      ok "$(payload_label "$key"): ${PAYLOAD_PKG[$key]}"
    else
      problems+=("not found in any NVIDIA ${DRIVER_VERSION} package: $(payload_label "$key")")
    fi
  done
  ((${#problems[@]} == 0)) || die "The NVIDIA package set is incomplete:" "${problems[@]}"

  DKMS_CONF_PKG=${PAYLOAD_PKG[dkms]}
  NVIDIA_SMI_PKG=${PAYLOAD_PKG[smi]}
  GSP_FIRMWARE_PKG=${PAYLOAD_PKG[gsp]}
  NVML_PKG=${PAYLOAD_PKG[nvml]}
  LIBCUDA_PKG=${PAYLOAD_PKG[cuda]}
  local tmpd="$WORKDIR/tmp/dkms-inspect"
  mkdir -p -- "$tmpd"
  dpkg-deb -x -- "$PKG_DIR/${PKG_FILE[$DKMS_CONF_PKG]}" "$tmpd"
  local conf="$tmpd/${DKMS_CONF_PATH#./}" srcdir pn pv
  srcdir=$(basename -- "$(dirname -- "$conf")")
  pn=$(sed -n -E "/^[[:space:]]*PACKAGE_NAME=/{s/^[[:space:]]*PACKAGE_NAME=[\"']?([^\"' ]+)[\"']?.*/\1/p;q}" "$conf")
  pv=$(sed -n -E "/^[[:space:]]*PACKAGE_VERSION=/{s/^[[:space:]]*PACKAGE_VERSION=[\"']?([^\"' ]+)[\"']?.*/\1/p;q}" "$conf")
  [[ -n $pn && $pn != *'$'* && $pn != *'#'* ]] || pn=${srcdir%-*}
  [[ -n $pv && $pv != *'$'* && $pv != *'#'* ]] || pv=${srcdir##*-}
  DKMS_MODULE_NAME=$pn
  DKMS_MODULE_VERSION=$pv
  rm -rf -- "$tmpd"
  [[ $DKMS_MODULE_VERSION == "$DRIVER_VERSION"* ]] ||
    die "The DKMS module version is '$DKMS_MODULE_VERSION' (${DKMS_CONF_PATH#.} in ${DKMS_CONF_PKG}), expected ${DRIVER_VERSION}."
  ok "DKMS module ${DKMS_MODULE_NAME}/${DKMS_MODULE_VERSION} (${DKMS_CONF_PATH#.} in ${DKMS_CONF_PKG})"
}

# -----------------------------------------------------------------------------
# Bundle repository index (flat APT repository inside packages/)
# -----------------------------------------------------------------------------
build_repo_index() {
  step "Generating the offline APT repository index (packages/Packages, Packages.gz, Release)"
  local f out="$PKG_DIR/Packages"
  : >"$out.tmp"
  for f in "$PKG_DIR"/*.deb; do
    dpkg-deb -f -- "$f" >>"$out.tmp"
    printf 'Filename: ./%s\nSize: %s\nSHA256: %s\n\n' "$(basename -- "$f")" "$(size_of "$f")" "$(sha256_of "$f")" >>"$out.tmp"
  done
  mv -f -- "$out.tmp" "$out"
  gzip -9nc -- "$out" >"$out.gz"
  {
    printf 'Origin: %s\nLabel: %s\nSuite: h200-offline\nCodename: h200-offline\n' "$BUNDLE_NAME" "$BUNDLE_NAME"
    printf 'Date: %s\n' "$(date -u '+%a, %d %b %Y %H:%M:%S UTC')"
    printf 'Architectures: %s all\nDescription: NVIDIA %s offline bundle for Ubuntu %s %s\n' "$TARGET_ARCH" "$DRIVER_VERSION" "$UBUNTU_VERSION" "$TARGET_ARCH"
    printf 'SHA256:\n'
    printf ' %s %s Packages\n' "$(sha256_of "$out")" "$(size_of "$out")"
    printf ' %s %s Packages.gz\n' "$(sha256_of "$out.gz")" "$(size_of "$out.gz")"
  } >"$PKG_DIR/Release"
  ok "$(grep -c '^Package: ' "$out") packages indexed"
}

# -----------------------------------------------------------------------------
# Bundle metadata, installer, README, MANIFEST
# -----------------------------------------------------------------------------
# NVIDIA packages the installer installs (Fabric Manager is handled separately).
nvidia_install_list() {
  local role out=()
  for role in "${NVIDIA_REQUIRED_ROLES[@]}" "${NVIDIA_OPTIONAL_ROLES[@]}"; do
    [[ -n ${ROLE_PKG[$role]:-} ]] && out+=("${ROLE_PKG[$role]}")
  done
  out+=("${EXTRA_NVIDIA_ROOTS[@]}")
  printf '%s\n' "${out[@]}"
}

kernel_compiler_map() {
  local abi out=()
  for abi in "${SELECTED_ABIS[@]}"; do out+=("$abi:${KERNEL_GCC_PKG[$abi]}"); done
  join_by ' ' "${out[@]}"
}

write_bundle_conf() {
  local -a nv_install
  mapfile -t nv_install < <(nvidia_install_list)
  cat >"$STAGE_DIR/bundle.conf" <<EOF
# Generated by ${SCRIPT_NAME} ${SCRIPT_VERSION}. Read by ${INSTALLER_NAME}. Do not edit
# (the file is covered by SHA256SUMS).
BUNDLE_FORMAT=1
BUNDLE_NAME=${BUNDLE_NAME}
BUILD_DATE_UTC=$(date -u +%Y-%m-%dT%H:%M:%SZ)
DRIVER_VERSION=${DRIVER_VERSION}
UBUNTU_VERSION=${UBUNTU_VERSION}
UBUNTU_CODENAME=${UBUNTU_CODENAME}
TARGET_ARCH=${TARGET_ARCH}
KERNEL_ABIS=${SELECTED_ABIS[*]}
KERNEL_COMPILER_MAP=$(kernel_compiler_map)
KERNEL_IMAGE_PACKAGES=${KERNEL_IMAGE_PKGS[*]}
TOOLCHAIN_PACKAGES=${TOOLCHAIN_REQUIRED[*]}
SECUREBOOT_PACKAGES=${SECUREBOOT_ROOTS[*]}
NVIDIA_PACKAGES=${nv_install[*]}
NVIDIA_FABRICMANAGER_PACKAGE=${FABRICMANAGER_PKG}
DKMS_MODULE_NAME=${DKMS_MODULE_NAME}
DKMS_MODULE_VERSION=${DKMS_MODULE_VERSION}
NVIDIA_REPO_DEB=${NVIDIA_REPO_DEB}
NVIDIA_REPO_SHA256=${NVIDIA_REPO_SHA256}
EOF
}

copy_scripts() {
  install -m 0755 -- "$SCRIPT_DIR/$INSTALLER_NAME" "$STAGE_DIR/$INSTALLER_NAME"
  install -m 0755 -- "$SCRIPT_DIR/$CAPTURE_NAME" "$STAGE_DIR/$CAPTURE_NAME"
}

write_readme() {
  local abi kl=""
  for abi in "${SELECTED_ABIS[@]}"; do kl+="      ${abi}"$'\n'; done
  local -a nv_install
  mapfile -t nv_install < <(nvidia_install_list)
  local kimg_text="This bundle does not contain kernel images."
  if ((${#KERNEL_IMAGE_PKGS[@]})); then
    kimg_text="This bundle also contains kernel ${SELECTED_ABIS[0]} (${KERNEL_IMAGE_PKGS[*]}).
  If the H200 runs another kernel, install it offline with:
      sudo bash ./${INSTALLER_NAME} --install-kernel
  then reboot into ${SELECTED_ABIS[0]} and run the installer again."
  fi
  cat >"$STAGE_DIR/README.txt" <<EOF
===============================================================================
 ${BUNDLE_NAME}
 NVIDIA data center driver ${DRIVER_VERSION} - open GPU kernel modules (DKMS)
 for NVIDIA H200 on Ubuntu ${UBUNTU_VERSION} (${UBUNTU_CODENAME}) ${TARGET_ARCH}
 Built: $(date -u +'%Y-%m-%d %H:%M UTC') by ${SCRIPT_NAME} ${SCRIPT_VERSION}
===============================================================================

WHAT THIS BUNDLE CONTAINS
  install_h200_nvidia_offline.sh   offline installer (run on the H200)
  capture_target_state.sh          optional helper: captures the H200 package state
  README.txt                       this file
  MANIFEST.txt                     every package: version, arch, source, SHA256, deps
  SHA256SUMS                       SHA256 of every file in the bundle
  bundle.conf                      machine-readable bundle metadata
  build.log                        log of the online build
  packages/                        $(find "$PKG_DIR" -maxdepth 1 -name '*.deb' | wc -l) .deb files + local APT index
                                   (Packages, Packages.gz, Release)

  Kernel ABIs supported (the H200 must run one of them - check with: uname -r):
${kl}
  NVIDIA packages installed: ${nv_install[*]}
  Toolchain installed:       ${TOOLCHAIN_REQUIRED[*]} $(for abi in "${SELECTED_ABIS[@]}"; do printf '%s\n' "${KERNEL_GCC_PKG[$abi]}"; done | sort -u | tr '\n' ' ')+ linux-headers-\$(uname -r)
  Fabric Manager:            ${FABRICMANAGER_PKG:-not included} (installed only when NVSwitch hardware is detected)
  ${kimg_text}

REQUIREMENTS ON THE H200
  - Ubuntu ${UBUNTU_VERSION} ${TARGET_ARCH}, root access (sudo)
  - running kernel listed above
  - about 3 GB free disk space
  - no other NVIDIA driver installed (or use --replace-existing-driver)
  - NO Internet access is needed or used.

OFFLINE INSTALLATION - EXACT STEPS
  1. Copy ${ZIP_NAME} to a USB drive.

  2. On the H200, mount the USB drive and copy the ZIP to local disk
     (USB file systems such as FAT/exFAT do not keep the executable bit):
         lsblk
         sudo mkdir -p /mnt/usb
         sudo mount /dev/sdX1 /mnt/usb          # replace sdX1 with your USB partition
         mkdir -p ~/h200-nvidia && cp /mnt/usb/${ZIP_NAME}* ~/h200-nvidia/
         sudo umount /mnt/usb

  3. Check and unzip:
         cd ~/h200-nvidia
         sha256sum -c ${ZIP_NAME}.sha256      # must print OK (file written by prepare_h200_usb.sh;
                                              # otherwise compare 'sha256sum ${ZIP_NAME}' with the build value)
         unzip ${ZIP_NAME}
     If 'unzip' is not installed on the H200, use Python (always present on Ubuntu Server):
         python3 -m zipfile -e ${ZIP_NAME} .
     Then change into the bundle directory (all following commands run there):
         cd ${BUNDLE_NAME}

  4. (Optional, changes nothing) check the bundle and simulate the installation:
         sudo bash ./${INSTALLER_NAME} --dry-run

  5. Install:
         sudo bash ./${INSTALLER_NAME}

     The installer verifies Ubuntu/arch/kernel/checksums, installs the toolchain and
     kernel headers, installs the NVIDIA packages, builds the kernel module with DKMS,
     runs depmod, loads the module, runs nvidia-smi and prints a PASS/FAIL report.
     Log file: ${BUNDLE_NAME}/install.log
     (or /var/log/h200_nvidia_offline_install.log if the bundle directory is read-only)

  6. Verify:
         nvidia-smi
         cat /proc/driver/nvidia/version

SECURE BOOT
  If UEFI Secure Boot is enabled, DKMS signs the module with the machine owner key
  /var/lib/shim-signed/mok/MOK.der. If that key is not yet enrolled the installer
  stops with exit code 31 and prints the exact commands, which are:
         sudo mokutil --import /var/lib/shim-signed/mok/MOK.der
             (choose a one-time password)
         sudo reboot
             (blue "MOK manager" screen: Enroll MOK -> Continue -> Yes -> password)
         sudo bash ./${INSTALLER_NAME}
             (run again after the reboot)

INSTALLER OPTIONS
  --dry-run                  verify everything and simulate; change nothing
  --replace-existing-driver  allow replacing an installed NVIDIA driver of another version
  --skip-gpu-check           install even if no NVIDIA GPU is visible on the PCI bus
  --install-kernel           install the kernel image shipped in the bundle (if any)

INSTALLER EXIT CODES
   0 success                         20 dependency/apt/dpkg failure
   1 unexpected error (see log)      21 kernel headers missing
   2 bad usage / not root
   3 reboot required                 30 DKMS build failure
  10 wrong Ubuntu version/arch       31 Secure Boot / module signing problem
  11 wrong running kernel            32 NVIDIA module failed to load
  12 bundle incomplete/corrupt       40 nvidia-smi failed
  13 conflicting NVIDIA driver       41 H200 not detected
                                     42 Fabric Manager not running (NVSwitch systems)

FULL PACKAGE LIST: see MANIFEST.txt
EOF
}

write_manifest() {
  step "Writing MANIFEST.txt"
  local m="$STAGE_DIR/MANIFEST.txt" tsv="$WORKDIR/manifest.tsv" name f role src total=0
  : >"$tsv"
  for name in $(printf '%s\n' "${!PKG_FILE[@]}" | sort); do
    f="$PKG_DIR/${PKG_FILE[$name]}"
    role=${ROOT_ROLE[$name]:-dependency}
    if [[ -n ${NV_VER[$name]:-} ]]; then
      src="NVIDIA local repo ${NVIDIA_REPO_PACKAGE}"
    else
      src="${PKG_REL[$name]:-Ubuntu archive}"
    fi
    total=$((total + $(size_of "$f")))
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$name" "${PKG_VER[$name]}" "${PKG_ARCH[$name]}" "$role" "$src" "$(sha256_of "$f")" "${PKG_FILE[$name]}" >>"$tsv"
  done

  {
    echo "==============================================================================="
    echo " MANIFEST - ${BUNDLE_NAME}"
    echo "==============================================================================="
    echo "Built (UTC)        : $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "Builder            : ${SCRIPT_NAME} ${SCRIPT_VERSION} on $(uname -n) (Ubuntu ${UBUNTU_VERSION} ${UBUNTU_CODENAME}, $(dpkg --print-architecture))"
    echo "Target             : NVIDIA H200, Ubuntu ${UBUNTU_VERSION} (${UBUNTU_CODENAME}) ${TARGET_ARCH}"
    echo "NVIDIA driver      : ${DRIVER_VERSION}, open GPU kernel modules built by DKMS"
    echo "NVIDIA source      : ${NVIDIA_REPO_DEB}"
    echo "                     obtained from: ${NVIDIA_REPO_SOURCE}"
    echo "                     SHA256: ${NVIDIA_REPO_SHA256}"
    echo "Ubuntu sources     : ${UBUNTU_ARCHIVE_URL} ${UBUNTU_CODENAME} ${UBUNTU_CODENAME}-updates"
    echo "                     ${UBUNTU_SECURITY_URL} ${UBUNTU_CODENAME}-security"
    echo "                     components: ${UBUNTU_COMPONENTS}; signed by ${UBUNTU_KEYRING}"
    echo "Kernel ABIs        : ${SELECTED_ABIS[*]}"
    local abi
    for abi in "${SELECTED_ABIS[@]}"; do
      printf '  %-20s headers: linux-headers-%s + %s; compiler: %s (%s)\n' "$abi" "$abi" "${HEADERS_COMMON[$abi]}" "${KERNEL_GCC_PKG[$abi]}" "${KERNEL_CC_TEXT[$abi]}"
    done
    [[ -n ${TARGET_KERNEL} ]] && echo "H200 target state  : running kernel ${TARGET_KERNEL} (captured with ${CAPTURE_NAME})"
    echo "DKMS module        : ${DKMS_MODULE_NAME}/${DKMS_MODULE_VERSION} (from ${DKMS_CONF_PKG})"
    echo "nvidia-smi         : ${NVIDIA_SMI_PKG}"
    echo "GSP firmware       : ${GSP_FIRMWARE_PKG}"
    echo "NVML / libcuda     : ${NVML_PKG} / ${LIBCUDA_PKG}"
    echo "Packages           : ${#PKG_FILE[@]} files, $(human_mib "$total")"
    echo "Dependency resolution (APT, Depends + Pre-Depends, Recommends/Suggests excluded):"
    local p
    for p in "${RESOLUTION_PASSES[@]}"; do echo "  - $p"; done
    echo
    echo "REQUESTED NVIDIA PACKAGE ROLES -> ACTUAL PACKAGES"
    local role2
    for role2 in "${NVIDIA_REQUIRED_ROLES[@]}" "${NVIDIA_OPTIONAL_ROLES[@]}" nvidia-fabricmanager; do
      if [[ -n ${ROLE_PKG[$role2]:-} ]]; then
        printf '  %-27s -> %s %s\n' "$role2" "${ROLE_PKG[$role2]}" "${NV_VER[${ROLE_PKG[$role2]}]}"
      else
        printf '  %-27s -> (not a separate package in this NVIDIA release)\n' "$role2"
      fi
    done
    local extra
    for extra in "${EXTRA_NVIDIA_ROOTS[@]}"; do
      printf '  %-27s -> %s %s\n' "(found by content)" "$extra" "${NV_VER[$extra]}"
    done
    echo
    echo "PACKAGES (columns separated by ' | ')"
    echo "PACKAGE | VERSION | ARCH | ROLE | SOURCE REPOSITORY | SHA256 | FILE"
    awk -F'\t' '{ printf "%s | %s | %s | %s | %s | %s | packages/%s\n", $1, $2, $3, $4, $5, $6, $7 }' "$tsv"
    echo
    echo "DEPENDENCY INFORMATION (Pre-Depends / Depends of every bundled package)"
    for name in $(printf '%s\n' "${!PKG_FILE[@]}" | sort); do
      f="$PKG_DIR/${PKG_FILE[$name]}"
      printf '%s %s\n' "$name" "${PKG_VER[$name]}"
      local pd d
      pd=$(deb_field "$f" Pre-Depends)
      d=$(deb_field "$f" Depends)
      [[ -n $pd ]] && printf '    Pre-Depends: %s\n' "$pd"
      if [[ -n $d ]]; then printf '    Depends: %s\n' "$d"; else printf '    Depends: (none)\n'; fi
    done
  } >"$m"
  ok "MANIFEST.txt: ${#PKG_FILE[@]} packages"
}

# -----------------------------------------------------------------------------
# Step 18 - validation before the ZIP is created
# -----------------------------------------------------------------------------
VALIDATION_FAILURES=()
vfail() { printf '  [FAIL] %s\n' "$*" >&2; VALIDATION_FAILURES+=("$*"); }

setup_verify_apt() {
  VERIFY_DIR="$WORKDIR/apt-verify"
  VERIFY_CONF="$VERIFY_DIR/apt.conf"
  write_apt_conf "$VERIFY_DIR" "$VERIFY_CONF"
  printf 'Types: deb\nURIs: file:%s\nSuites: ./\nArchitectures: %s\nTrusted: yes\n' "$PKG_DIR" "$TARGET_ARCH" \
    >"$VERIFY_DIR/sources.list.d/bundle.sources"
  apt-get -c "$VERIFY_CONF" -q --error-on=any update >"$VERIFY_DIR/update.log" 2>&1 ||
    { cat "$VERIFY_DIR/update.log" >&2; die "APT cannot read the bundle repository index."; }
}

simulate_bundle_only() {
  local status_file=$1 result_file=$2
  shift 2
  apt-get -c "$VERIFY_CONF" -s install --no-install-recommends --no-install-suggests \
    -o Dir::State::status="$status_file" "$@" >"$result_file" 2>&1
}

validate_bundle() {
  step "Validating the bundle (offline installability, completeness, duplicates, versions)"
  local name ver f

  # 1. duplicates / conflicting versions
  local dups
  dups=$(awk '/^Package: /{print $2}' "$PKG_DIR/Packages" | sort | uniq -d | tr '\n' ' ')
  if [[ -n $dups ]]; then vfail "Duplicate packages: $dups"; else ok "No duplicate packages (one version per package)"; fi

  # 2. architecture
  local badarch
  badarch=$(awk '/^Architecture: /{ if ($2 != "'"$TARGET_ARCH"'" && $2 != "all") print }' "$PKG_DIR/Packages" | sort -u | tr '\n' ' ')
  if [[ -n $badarch ]]; then vfail "Non-${TARGET_ARCH} packages present: $badarch"; else ok "All packages are ${TARGET_ARCH} or arch:all (no amd64v3 variants, no arm64/i386)"; fi

  # 3. requested NVIDIA packages present with the exact driver version
  local role pkg
  for role in "${NVIDIA_REQUIRED_ROLES[@]}"; do
    pkg=${ROLE_PKG[$role]:-}
    if [[ -n $pkg && -n ${PKG_FILE[$pkg]:-} && ${PKG_VER[$pkg]} =~ $DRIVER_VERSION_RE ]]; then
      ok "NVIDIA $role -> $pkg ${PKG_VER[$pkg]}"
    else
      vfail "NVIDIA package for role $role missing or wrong version"
    fi
  done

  # 4. no NVIDIA component of another driver version, all NVIDIA-repo packages at NVIDIA's version
  local foreign=()
  for name in "${!PKG_VER[@]}"; do
    ver=${PKG_VER[$name]}
    if [[ -n ${NV_VER[$name]:-} ]]; then
      [[ $ver == "${NV_VER[$name]}" ]] || foreign+=("$name $ver (NVIDIA repo has ${NV_VER[$name]})")
    elif [[ $name =~ ^(lib)?nvidia ]] && [[ $ver =~ $ANY_DRIVER_VERSION_RE ]] && ! [[ $ver =~ $DRIVER_VERSION_RE ]]; then
      foreign+=("$name $ver (from Ubuntu archive - different driver version)")
    fi
  done
  if ((${#foreign[@]})); then vfail "NVIDIA packages of another driver version: ${foreign[*]}"; else ok "No NVIDIA packages of any other driver version"; fi

  # 5. kernel headers, common headers, compiler and toolchain
  local abi
  for abi in "${SELECTED_ABIS[@]}"; do
    for pkg in "linux-headers-$abi" "${HEADERS_COMMON[$abi]}" "${KERNEL_GCC_PKG[$abi]}"; do
      [[ -n ${PKG_FILE[$pkg]:-} ]] || vfail "Missing $pkg for kernel $abi"
    done
  done
  ((${#VALIDATION_FAILURES[@]})) || ok "Kernel headers + common headers + kernel compiler present for: ${SELECTED_ABIS[*]}"
  local missing_tc=()
  for pkg in dkms build-essential gcc g++ make libc6-dev kmod openssl patch dpkg-dev "${KERNEL_IMAGE_PKGS[@]}"; do
    [[ -n ${PKG_FILE[$pkg]:-} ]] || missing_tc+=("$pkg")
  done
  if ((${#missing_tc[@]})); then vfail "Missing toolchain packages: ${missing_tc[*]}"; else ok "Toolchain present: dkms build-essential gcc g++ make libc6-dev kmod openssl patch dpkg-dev"; fi

  # 6. offline installability using ONLY the bundle as package source
  setup_verify_apt
  local -a nv_install
  mapfile -t nv_install < <(nvidia_install_list)
  local -a base=("${TOOLCHAIN_REQUIRED[@]}" "${nv_install[@]}" "${SECUREBOOT_ROOTS[@]}")
  [[ -n $FABRICMANAGER_PKG ]] && base+=("$FABRICMANAGER_PKG")
  local out
  for abi in "${SELECTED_ABIS[@]}"; do
    out="$WORKDIR/verify-$abi-empty.txt"
    if simulate_bundle_only "$VERIFY_DIR/status-empty" "$out" "${base[@]}" "${KERNEL_GCC_PKG[$abi]}" "linux-headers-$abi"; then
      ok "Offline install simulation (bundle only, bare system) for kernel $abi: OK ($(grep -c '^Inst ' "$out") packages)"
    else
      tail -n 30 "$out" >&2
      vfail "Offline install simulation for kernel $abi FAILED using only the bundle (see $out)"
    fi
  done
  if ((${#KERNEL_IMAGE_PKGS[@]})); then
    out="$WORKDIR/verify-kernel-image.txt"
    if simulate_bundle_only "$VERIFY_DIR/status-empty" "$out" "${KERNEL_IMAGE_PKGS[@]}" "linux-headers-${SELECTED_ABIS[0]}"; then
      ok "Offline kernel image install simulation: OK"
    else
      tail -n 30 "$out" >&2
      vfail "Offline kernel image install simulation FAILED (see $out)"
    fi
  fi
  if [[ -n $TARGET_STATUS ]]; then
    abi=${SELECTED_ABIS[0]}
    out="$WORKDIR/verify-h200-state.txt"
    if simulate_bundle_only "$TARGET_STATUS" "$out" "${base[@]}" "${KERNEL_GCC_PKG[$abi]}" "linux-headers-$abi"; then
      local removed_other removed_nv
      removed_other=$(awk '/^Remv / && $2 !~ /^(lib)?nvidia/ { printf "%s ", $2 }' "$out")
      removed_nv=$(awk '/^Remv / && $2 ~ /^(lib)?nvidia/ { printf "%s ", $2 }' "$out")
      if [[ -n $removed_other ]]; then
        vfail "On the captured H200 the installation would REMOVE non-NVIDIA packages: $removed_other(upgrade or remove them on the H200 first, e.g. foreign-architecture :i386 packages)"
      else
        ok "Offline install simulation against the captured H200 package state: OK"
      fi
      [[ -z $removed_nv ]] || warn "On the H200 these NVIDIA packages of another driver would be removed: $removed_nv(the installer requires --replace-existing-driver for that)"
    else
      tail -n 30 "$out" >&2
      vfail "Offline install simulation against the captured H200 state FAILED (see $out)"
    fi
  fi
  if [[ -r /var/lib/dpkg/status ]]; then
    abi=${SELECTED_ABIS[-1]}
    out="$WORKDIR/verify-buildhost-state.txt"
    if simulate_bundle_only /var/lib/dpkg/status "$out" "${base[@]}" "${KERNEL_GCC_PKG[$abi]}" "linux-headers-$abi"; then
      ok "Offline install simulation against this machine's Ubuntu ${UBUNTU_VERSION} package state: OK"
    else
      warn "Offline install simulation against this build machine's package state failed (informational only, see $out)."
    fi
  fi

  # 7. all bundled packages co-installable (no internal conflicts)
  local -a allnames
  mapfile -t allnames < <(printf '%s\n' "${!PKG_FILE[@]}" | sort)
  out="$WORKDIR/verify-all-coinstallable.txt"
  if simulate_bundle_only "$VERIFY_DIR/status-empty" "$out" "${allnames[@]}"; then
    ok "All ${#allnames[@]} bundled packages are co-installable (no conflicts)"
  else
    warn "Not all bundled packages are co-installable at the same time (see $out). This is informational."
  fi

  # 8. bundle files
  for f in "$INSTALLER_NAME" "$CAPTURE_NAME" README.txt MANIFEST.txt bundle.conf packages/Packages packages/Packages.gz packages/Release; do
    [[ -s $STAGE_DIR/$f ]] || vfail "Bundle file missing: $f"
  done
  bash -n "$STAGE_DIR/$INSTALLER_NAME" || vfail "Installer has a syntax error"
  [[ -x $STAGE_DIR/$INSTALLER_NAME ]] || vfail "Installer is not executable"
  local mcount
  mcount=$(grep -cE '^[^ ]+ \| [^|]+ \| (amd64|all) \|' "$STAGE_DIR/MANIFEST.txt" || true)
  [[ $mcount == "${#PKG_FILE[@]}" ]] || vfail "MANIFEST lists $mcount packages, bundle has ${#PKG_FILE[@]}"

  if ((${#VALIDATION_FAILURES[@]})); then
    die "Bundle validation failed (${#VALIDATION_FAILURES[@]} problem(s)):" "${VALIDATION_FAILURES[@]}"
  fi
  ok "Bundle validation passed"
}

write_checksums() {
  step "Generating and verifying SHA256SUMS"
  cp -f -- "$BUILD_LOG" "$STAGE_DIR/build.log"
  local sums="$WORKDIR/tmp/SHA256SUMS"
  (cd -- "$STAGE_DIR" && find . -type f ! -name SHA256SUMS -print | sed 's|^\./||' | sort | while IFS= read -r f; do sha256sum -- "$f"; done) >"$sums"
  mv -f -- "$sums" "$STAGE_DIR/SHA256SUMS"
  (cd -- "$STAGE_DIR" && sha256sum -c --quiet SHA256SUMS) || die "SHA256SUMS verification failed."
  ok "SHA256SUMS: $(wc -l <"$STAGE_DIR/SHA256SUMS") files verified"
}

create_zip() {
  step "Creating ${ZIP_NAME}"
  local tmpzip="$WORKDIR/$ZIP_NAME"
  rm -f -- "$tmpzip"
  (cd -- "$WORKDIR/stage" && zip -r -X -q -n .deb:.gz:.xz:.zst "$tmpzip" "$BUNDLE_NAME") || die "zip failed."
  unzip -tq "$tmpzip" >/dev/null || die "ZIP integrity test failed."
  local entries need missing=()
  entries=$(unzip -Z1 "$tmpzip")
  for need in "$INSTALLER_NAME" "$CAPTURE_NAME" MANIFEST.txt SHA256SUMS README.txt bundle.conf packages/Packages packages/Release; do
    grep -qx -- "$BUNDLE_NAME/$need" <<<"$entries" || missing+=("$need")
  done
  local debs_in_zip
  debs_in_zip=$(grep -c "^$BUNDLE_NAME/packages/.*\.deb\$" <<<"$entries" || true)
  [[ $debs_in_zip == "${#PKG_FILE[@]}" ]] || missing+=("packages/*.deb ($debs_in_zip of ${#PKG_FILE[@]})")
  ((${#missing[@]} == 0)) || die "The ZIP is missing: ${missing[*]}"
  ok "ZIP integrity test passed; installer, manifest, README, SHA256SUMS and ${debs_in_zip} packages present"
  if [[ -e $OUTPUT_DIR/$ZIP_NAME ]]; then info "Replacing existing $OUTPUT_DIR/$ZIP_NAME"; fi
  mv -f -- "$tmpzip" "$OUTPUT_DIR/$ZIP_NAME"
}

summary() {
  local z="$OUTPUT_DIR/$ZIP_NAME"
  printf '\n===============================================================================\n'
  printf ' BUILD SUCCEEDED\n'
  printf '===============================================================================\n'
  printf ' Output       : %s\n' "$z"
  printf ' Size         : %s\n' "$(human_mib "$(size_of "$z")")"
  printf ' SHA256       : %s\n' "$(sha256_of "$z")"
  printf ' Driver       : NVIDIA %s (open kernel modules, DKMS)\n' "$DRIVER_VERSION"
  printf ' Kernel ABIs  : %s\n' "${SELECTED_ABIS[*]}"
  printf ' Packages     : %s\n' "${#PKG_FILE[@]}"
  if ((${#WARNINGS[@]})); then
    printf ' Warnings     :\n'
    local w
    for w in "${WARNINGS[@]}"; do printf '   - %s\n' "$w"; done
  fi
  printf '\n Next: copy the ZIP to a USB drive; on the H200 run:\n'
  printf '   unzip %s && cd %s && sudo bash ./%s\n' "$ZIP_NAME" "$BUNDLE_NAME" "$INSTALLER_NAME"
  printf '===============================================================================\n'
}

main() {
  parse_args "$@"
  start_logging "$(mktemp "${TMPDIR:-/tmp}/h200-bundle-build.XXXXXX")"
  printf '%s %s - NVIDIA %s offline bundle builder for H200 / Ubuntu %s %s\n' "$SCRIPT_NAME" "$SCRIPT_VERSION" "$DRIVER_VERSION" "$UBUNTU_VERSION" "$TARGET_ARCH"
  printf 'Started %s\n' "$(date -u +'%Y-%m-%d %H:%M:%S UTC')"

  check_build_host
  prepare_workdir
  obtain_nvidia_repo_deb
  extract_nvidia_repo
  setup_private_apt
  select_nvidia_packages
  load_target_state
  select_kernels
  detect_kernel_compilers
  verify_roots_available
  resolve_dependencies
  download_packages
  inspect_nvidia_payload
  build_repo_index
  write_bundle_conf
  copy_scripts
  write_readme
  write_manifest
  validate_bundle
  write_checksums
  create_zip
  BUILD_OK=1
  summary
}

main "$@"
