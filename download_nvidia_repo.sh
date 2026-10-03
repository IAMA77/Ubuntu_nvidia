#!/usr/bin/env bash
# =============================================================================
#  download_nvidia_repo.sh
#
#  Downloads the official NVIDIA local repository package
#      nvidia-driver-local-repo-ubuntu2604-615.71.09_1.0-1_amd64.deb
#  into ./nvidia-downloads/ (next to this script). build_h200_nvidia_offline_bundle.sh
#  and prepare_h200_usb.sh pick it up from there automatically.
#
#  Works on any Internet-connected Linux, macOS or Windows (WSL) machine with
#  bash and curl or wget - it does not have to be the Ubuntu build machine.
#
#  Usage:
#    ./download_nvidia_repo.sh                download it (or re-verify an existing copy)
#    ./download_nvidia_repo.sh --dest DIR     save it into DIR instead of ./nvidia-downloads
#    ./download_nvidia_repo.sh --verify FILE  verify a copy you downloaded yourself (browser)
#                                             and put it into the download folder
#    ./download_nvidia_repo.sh --links        only print the official links and the target path
#
#  Exit codes: 0 ok, 2 usage, 3 not downloadable from NVIDIA, 4 invalid file
# =============================================================================
set -Eeuo pipefail
export LC_ALL=C

readonly DRIVER_VERSION="615.71.09"
readonly UBUNTU_REPO_TAG="ubuntu2604"
readonly ARCH="amd64"
readonly REPO_PACKAGE="nvidia-driver-local-repo-${UBUNTU_REPO_TAG}-${DRIVER_VERSION}"
readonly REPO_PACKAGE_VERSION="1.0-1"
readonly DEB="${REPO_PACKAGE}_${REPO_PACKAGE_VERSION}_${ARCH}.deb"
# Official NVIDIA locations (same list as build_h200_nvidia_offline_bundle.sh).
readonly -a URLS=(
  "https://developer.download.nvidia.com/compute/nvidia-driver/${DRIVER_VERSION}/local_installers/${DEB}"
  "https://us.download.nvidia.com/tesla/${DRIVER_VERSION}/${DEB}"
  "https://international.download.nvidia.com/tesla/${DRIVER_VERSION}/${DEB}"
)
readonly DOWNLOAD_PAGE="https://developer.nvidia.com/datacenter-driver-downloads?target_os=Linux&target_arch=x86_64&Distribution=Ubuntu&target_version=26.04&target_type=deb_local"
readonly RELEASE_NOTES="https://docs.nvidia.com/datacenter/tesla/tesla-release-notes-615-71-09/index.html"
readonly INSTALL_GUIDE="https://docs.nvidia.com/datacenter/tesla/driver-installation-guide/615/ubuntu.html"

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
readonly SCRIPT_DIR
DEST="$SCRIPT_DIR/nvidia-downloads"
MODE=download
VERIFY_FILE=""

die() {
  local code=$1 line
  shift
  printf '\nERROR: %s\n' "$1" >&2
  shift
  for line in "$@"; do printf '       %s\n' "$line" >&2; done
  exit "$code"
}

usage() { sed -n '3,22p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

while (($#)); do
  case $1 in
    --dest) (($# >= 2)) || die 2 "--dest needs a directory"; DEST=$2; shift 2 ;;
    --dest=*) DEST=${1#*=}; shift ;;
    --verify) (($# >= 2)) || die 2 "--verify needs a file"; MODE=verify; VERIFY_FILE=$2; shift 2 ;;
    --verify=*) MODE=verify; VERIFY_FILE=${1#*=}; shift ;;
    --links) MODE=links; shift ;;
    -h | --help) usage; exit 0 ;;
    *) die 2 "unknown option: $1" "Run with --help for usage." ;;
  esac
done
[[ $DEST == /* ]] || DEST="$PWD/${DEST#./}"
readonly TARGET="$DEST/$DEB"

have() { command -v "$1" >/dev/null 2>&1; }

sha256_file() {
  if have sha256sum; then sha256sum -- "$1" | awk '{print $1}'
  else shasum -a 256 -- "$1" | awk '{print $1}'
  fi
}

human_size() { awk -v b="$(wc -c <"$1" | tr -d ' ')" 'BEGIN { printf "%.1f MiB", b / 1048576 }'; }

# A .deb is an 'ar' archive whose first member is "debian-binary". When dpkg-deb
# is available (Ubuntu/Debian/WSL) the control fields are checked as well.
valid_deb() {
  local f=$1 pkg ver arch
  [[ -s $f ]] || { echo "empty or missing file"; return 1; }
  [[ $(head -c 7 -- "$f") == '!<arch>' ]] || { echo "not a Debian package (an HTML error page or an incomplete download?)"; return 1; }
  head -c 80 -- "$f" | grep -aq 'debian-binary' || { echo "not a Debian package (no debian-binary member)"; return 1; }
  if have dpkg-deb; then
    dpkg-deb --info -- "$f" >/dev/null 2>&1 || { echo "dpkg-deb cannot read it (truncated download?)"; return 1; }
    pkg=$(dpkg-deb -f -- "$f" Package)
    ver=$(dpkg-deb -f -- "$f" Version)
    arch=$(dpkg-deb -f -- "$f" Architecture)
    [[ $pkg == "$REPO_PACKAGE" ]] || { echo "Package is '$pkg', expected $REPO_PACKAGE"; return 1; }
    [[ $ver == "$REPO_PACKAGE_VERSION" ]] || { echo "Version is '$ver', expected $REPO_PACKAGE_VERSION"; return 1; }
    [[ $arch == "$ARCH" ]] || { echo "Architecture is '$arch', expected $ARCH"; return 1; }
  fi
  return 0
}

write_sidecars() {
  local source=$1
  (cd -- "$DEST" && printf '%s  %s\n' "$(sha256_file "$DEB")" "$DEB") >"$TARGET.sha256"
  printf 'url=%s\ndownloaded_utc=%s\n' "$source" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >"$TARGET.source.txt"
}

print_links() {
  cat <<EOF

Official NVIDIA download links for ${DEB}
(any one of them; the file is the same):
$(printf '  %s\n' "${URLS[@]}")

NVIDIA pages:
  Download page : ${DOWNLOAD_PAGE}
                  (choose Linux > x86_64 > Ubuntu > 26.04 > deb (local))
  Release notes : ${RELEASE_NOTES}
  Install guide : ${INSTALL_GUIDE}

Where to put it - keep the file name exactly as it is:
  ${TARGET}

From a browser download, check and file it with:
  ${SCRIPT_DIR}/download_nvidia_repo.sh --verify ~/Downloads/${DEB}

Windows PowerShell (then copy the file into the folder above):
  Invoke-WebRequest -Uri "${URLS[0]}" -OutFile "${DEB}"
  Get-FileHash -Algorithm SHA256 "${DEB}"
EOF
}

http_status() {
  if have curl; then
    curl -s -o /dev/null -I -L --max-time 30 -w '%{http_code}' "$1" 2>/dev/null || true
  else
    wget --spider --server-response --timeout=30 --tries=1 "$1" 2>&1 | awk '/^  HTTP\//{c=$2} END{print c+0}'
  fi
}

explain_status() {
  case $1 in
    200) echo "available" ;;
    404) echo "not published at this location (404)" ;;
    403) echo "forbidden (403) - often a corporate proxy/firewall blocking nvidia.com" ;;
    000 | 0 | "") echo "no connection (DNS, firewall or proxy problem)" ;;
    *) echo "HTTP $1" ;;
  esac
}

diagnose() {
  local url code alt alt_url
  printf '\nDiagnosis:\n'
  for url in "${URLS[@]}"; do
    code=$(http_status "$url")
    printf '  %-28s %s\n' "$(explain_status "$code")" "$url"
  done
  # Information only - another Ubuntu release is never used instead.
  for alt in ubuntu2404 ubuntu2204; do
    alt_url="https://developer.download.nvidia.com/compute/nvidia-driver/${DRIVER_VERSION}/local_installers/nvidia-driver-local-repo-${alt}-${DRIVER_VERSION}_${REPO_PACKAGE_VERSION}_${ARCH}.deb"
    if [[ $(http_status "$alt_url") == 200 ]]; then
      printf '  Note: %s is published for %s, but NOT for this request - it is not used (the H200 runs Ubuntu 26.04).\n' "$DRIVER_VERSION" "$alt"
    fi
  done
}

fetch() {
  local url=$1 out=$2
  rm -f -- "$out"
  if have curl; then
    local progress=(--silent --show-error)
    [[ -t 2 ]] && progress=(--progress-bar)
    curl --fail --location --proto '=https' --proto-redir '=https' --tlsv1.2 \
      --retry 5 --retry-delay 5 --connect-timeout 30 "${progress[@]}" --output "$out" "$url"
  elif have wget; then
    local progress=(--quiet)
    [[ -t 2 ]] && progress=(--progress=bar:force:noscroll)
    wget --https-only --tries=5 --timeout=60 "${progress[@]}" --output-document="$out" "$url"
  else
    die 2 "neither curl nor wget is installed"
  fi
}

case $MODE in
  links)
    print_links
    exit 0
    ;;
  verify)
    [[ -f $VERIFY_FILE ]] || die 4 "file not found: $VERIFY_FILE"
    [[ $(basename -- "$VERIFY_FILE") == "$DEB" ]] ||
      die 4 "the file must be named exactly $DEB" "got: $(basename -- "$VERIFY_FILE") - a different driver version is never used"
    if ! reason=$(valid_deb "$VERIFY_FILE"); then die 4 "$VERIFY_FILE is not valid: $reason" "Download it again."; fi
    mkdir -p -- "$DEST"
    if [[ "$(cd -- "$(dirname -- "$VERIFY_FILE")" && pwd -P)/$DEB" != "$TARGET" ]]; then
      cp -f -- "$VERIFY_FILE" "$TARGET.part"
      mv -f -- "$TARGET.part" "$TARGET"
    fi
    write_sidecars "manual download, verified with --verify"
    printf 'OK: %s (%s)\n    SHA256 %s\n    The bundle builder will use it automatically.\n' "$TARGET" "$(human_size "$TARGET")" "$(sha256_file "$TARGET")"
    exit 0
    ;;
esac

printf 'NVIDIA %s local repository for Ubuntu 26.04 (%s)\n' "$DRIVER_VERSION" "$ARCH"
printf 'Target: %s\n' "$TARGET"
mkdir -p -- "$DEST"

if [[ -f $TARGET ]]; then
  if [[ -f $TARGET.sha256 && $(awk 'NR==1{print $1}' "$TARGET.sha256") != "$(sha256_file "$TARGET")" ]]; then
    printf 'Existing copy does not match its .sha256 - downloading again.\n'
  elif reason=$(valid_deb "$TARGET"); then
    [[ -f $TARGET.sha256 ]] || write_sidecars "existing file"
    printf 'Already downloaded and valid (%s), SHA256 %s\n' "$(human_size "$TARGET")" "$(sha256_file "$TARGET")"
    exit 0
  else
    printf 'Existing copy is not valid (%s) - downloading again.\n' "$reason"
  fi
fi

for url in "${URLS[@]}"; do
  printf '\nTrying %s\n' "$url"
  if fetch "$url" "$TARGET.part"; then
    if reason=$(valid_deb "$TARGET.part"); then
      mv -f -- "$TARGET.part" "$TARGET"
      write_sidecars "$url"
      printf '\nOK: downloaded %s (%s)\n    SHA256 %s\n    Saved in %s - the bundle builder will use it automatically.\n' \
        "$DEB" "$(human_size "$TARGET")" "$(sha256_file "$TARGET")" "$DEST"
      exit 0
    fi
    printf '  downloaded file is not valid: %s\n' "$reason"
  fi
  rm -f -- "$TARGET.part"
done

diagnose
print_links
die 3 "$DEB could not be downloaded automatically from NVIDIA." \
  "Download it manually from one of the links above and place it at:" "  $TARGET"
