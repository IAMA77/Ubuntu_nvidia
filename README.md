# H200 NVIDIA 615.71.09 offline driver bundle builder (Ubuntu 26.04, amd64)

This repository builds **one ZIP file** that installs the NVIDIA **615.71.09** data center
driver with the **open GPU kernel modules** (DKMS) on a **completely offline NVIDIA H200
server** running **Ubuntu 26.04 amd64**. The ZIP is carried to the server on a USB drive.

```
ONLINE MACHINE (Ubuntu 26.04 amd64, Internet)
  ./build_h200_nvidia_offline_bundle.sh
        |
        v
  H200_NVIDIA_615.71.09_Ubuntu26.04_Offline.zip
        |
        v   USB drive
OFFLINE H200 SERVER
  unzip H200_NVIDIA_615.71.09_Ubuntu26.04_Offline.zip
  cd H200_NVIDIA_615.71.09_Ubuntu26.04_Offline
  sudo bash ./install_h200_nvidia_offline.sh
        |
        v
  nvidia-smi
```

## Deliverables

| File | Runs on | Purpose |
|---|---|---|
| `prepare_h200_usb.sh` | online Ubuntu 26.04 amd64 machine | **One command for everything that needs Internet.** Installs missing tools, downloads the NVIDIA file, downloads every Ubuntu package, builds and validates the ZIP, and copies it to the USB drive with a verified `.sha256`. |
| `download_nvidia_repo.sh` | any Internet machine (Linux, macOS, Windows WSL) | Downloads the official NVIDIA local repository `.deb` into `nvidia-downloads/`, or checks a copy you downloaded with a browser (`--verify`). |
| `build_h200_nvidia_offline_bundle.sh` | online Ubuntu 26.04 amd64 machine | Downloads, resolves, verifies, and packages everything into the ZIP. Root is **not** required, and nothing is installed or reconfigured on the build machine. |
| `install_h200_nvidia_offline.sh` | offline H200 | Offline installer. The builder copies it into the ZIP. |
| `capture_target_state.sh` | offline H200 (optional) | Read-only helper. Captures the H200's kernel and installed-package database so the bundle can be resolved against that exact system. The builder copies it into the ZIP. |

Keep all scripts in the same directory. The builder copies the installer and
`capture_target_state.sh` into the bundle.

**Output file (exactly one):** `H200_NVIDIA_615.71.09_Ubuntu26.04_Offline.zip`

```
H200_NVIDIA_615.71.09_Ubuntu26.04_Offline/
├── install_h200_nvidia_offline.sh
├── capture_target_state.sh
├── README.txt          exact offline installation instructions
├── MANIFEST.txt        package | version | arch | role | source repository | SHA256 | file, plus Depends of every package
├── SHA256SUMS          SHA256 of every file in the bundle
├── bundle.conf         machine-readable metadata read by the installer
├── build.log           log of the online build
└── packages/
    ├── *.deb
    └── Packages, Packages.gz, Release   (local APT repository index)
```

## 1. Commands on the online Ubuntu 26.04 machine

### Everything in one command (recommended)

Plug in and mount the USB drive (`lsblk -o NAME,SIZE,FSTYPE,MOUNTPOINTS` shows where), then:

```bash
cd /path/to/these/scripts
./prepare_h200_usb.sh --usb /media/$USER/<USB-LABEL> --kernel 7.0.0-38-generic
#   --kernel: the value of `uname -r` on the H200; omit it to bundle every 7.0.0-NN-generic ABI
```

It runs these four steps and stops with a clear message if any step fails:

1. **Tools.** Installs `curl zip unzip xz-utils` with `sudo apt-get` if they are missing.
2. **NVIDIA file.** Runs `download_nvidia_repo.sh`, which downloads `nvidia-driver-local-repo-ubuntu2604-615.71.09_1.0-1_amd64.deb` into `nvidia-downloads/`. A valid copy already there is reused.
3. **Build.** Runs `build_h200_nvidia_offline_bundle.sh`, which downloads every Ubuntu package and builds and validates the ZIP.
4. **USB.** Copies the ZIP and `<ZIP>.sha256` to the USB drive and checks the copy's SHA256.
   * It reads the copy back from the drive itself, not from the page cache: `gnudd iflag=direct` if possible, otherwise it evicts the file from the cache first, and it says which method was used.
   * It refuses a path on the root file system, on tmpfs/overlay or not on a `/dev` block device. Make sure you pass the USB drive's mount point (`lsblk -o NAME,SIZE,FSTYPE,MOUNTPOINTS`).
   * It refuses a FAT32 drive if the ZIP is 4 GiB or larger.

   The `<ZIP>.sha256` file is also written next to the ZIP in the output directory, so you have it even without `--usb`.

When it prints `READY`, nothing else has to be downloaded. Eject the drive and take it to the H200.

### Step by step

```bash
# Tools (normally already present on Ubuntu 26.04)
sudo apt-get update
sudo apt-get install -y git curl zip unzip xz-utils

# Get the scripts (or copy the .sh files into one folder)
git clone https://github.com/IAMA77/Ubuntu_nvidia.git
cd Ubuntu_nvidia

# NVIDIA file (optional: the builder downloads it itself if it is missing)
./download_nvidia_repo.sh

# Recommended: build for the exact kernel the H200 runs (value of `uname -r` on the H200)
./build_h200_nvidia_offline_bundle.sh --kernel 7.0.0-38-generic

# Or: bundle headers for EVERY Ubuntu 26.04 7.0.0-NN-generic ABI (the default)
./build_h200_nvidia_offline_bundle.sh

# Result
ls -lh H200_NVIDIA_615.71.09_Ubuntu26.04_Offline.zip
sha256sum H200_NVIDIA_615.71.09_Ubuntu26.04_Offline.zip | tee H200_NVIDIA_615.71.09_Ubuntu26.04_Offline.zip.sha256
# copy BOTH the .zip and the .zip.sha256 to the USB drive
```

Builder options:

| Option | Meaning |
|---|---|
| `--kernel SPEC` | `7.0.0-generic` (family, default) or an exact ABI such as `7.0.0-38-generic`. Repeatable or comma-separated. |
| `--target-state FILE` | Archive from `capture_target_state.sh`. Selects the H200's running kernel automatically and resolves dependencies against the H200's exact package database. |
| `--nvidia-repo-deb FILE` | Use a copy of `nvidia-driver-local-repo-ubuntu2604-615.71.09_1.0-1_amd64.deb` that you already downloaded from nvidia.com. The filename must match exactly. |
| `--nvidia-download-dir DIR` | Folder for the NVIDIA file (default `nvidia-downloads/` next to the scripts). A valid copy there is reused; a new download is saved there. |
| `--with-kernel-image` | Also bundle `linux-image` for the single selected ABI, so the H200 can switch to that kernel offline (installer `--install-kernel`). |
| `--workdir DIR`, `--output-dir DIR`, `--keep-workdir` | Locations. The work directory is deleted after a successful build unless you pass `--keep-workdir`. |

The driver version, Ubuntu release and architecture are fixed constants at the top of the
builder. They are deliberately not command-line options, so they can never drift silently.

### Most precise build (optional)

```bash
# On the H200 (read-only, offline). The helper is also inside the ZIP.
bash ./capture_target_state.sh /tmp
# Copy /tmp/h200_target_state_<host>_<time>.tar.gz to the online machine, then:
./build_h200_nvidia_offline_bundle.sh --target-state h200_target_state_<host>_<time>.tar.gz
```

## NVIDIA download: links, and where to put the file

`download_nvidia_repo.sh` (and the builder itself) download the file automatically from
these official NVIDIA locations. They are tried in order; the file is the same at each:

* https://developer.download.nvidia.com/compute/nvidia-driver/615.71.09/local_installers/nvidia-driver-local-repo-ubuntu2604-615.71.09_1.0-1_amd64.deb
* https://us.download.nvidia.com/tesla/615.71.09/nvidia-driver-local-repo-ubuntu2604-615.71.09_1.0-1_amd64.deb
* https://international.download.nvidia.com/tesla/615.71.09/nvidia-driver-local-repo-ubuntu2604-615.71.09_1.0-1_amd64.deb

NVIDIA pages:

* **Download page:** [Data Center Driver downloads](https://developer.nvidia.com/datacenter-driver-downloads?target_os=Linux&target_arch=x86_64&Distribution=Ubuntu&target_version=26.04&target_type=deb_local). Choose Linux > x86_64 > Ubuntu > 26.04 > deb (local).
* **Release notes:** [615.71.09 release notes](https://docs.nvidia.com/datacenter/tesla/tesla-release-notes-615-71-09/index.html)
* **Install guide:** [Driver Installation Guide 615, Ubuntu](https://docs.nvidia.com/datacenter/tesla/driver-installation-guide/615/ubuntu.html)

**If the automatic download is blocked** (corporate proxy, firewall), download the file
yourself on any computer and put it, **without renaming it**, here:

```
<folder with the scripts>/nvidia-downloads/nvidia-driver-local-repo-ubuntu2604-615.71.09_1.0-1_amd64.deb
```

Or let the script check it and move it there:

```bash
./download_nvidia_repo.sh --verify ~/Downloads/nvidia-driver-local-repo-ubuntu2604-615.71.09_1.0-1_amd64.deb
```

Windows PowerShell:

```powershell
Invoke-WebRequest -Uri "https://developer.download.nvidia.com/compute/nvidia-driver/615.71.09/local_installers/nvidia-driver-local-repo-ubuntu2604-615.71.09_1.0-1_amd64.deb" -OutFile "nvidia-driver-local-repo-ubuntu2604-615.71.09_1.0-1_amd64.deb"
Get-FileHash -Algorithm SHA256 "nvidia-driver-local-repo-ubuntu2604-615.71.09_1.0-1_amd64.deb"
```

Then run `./prepare_h200_usb.sh` (or the builder) again. It finds the file automatically.

If all three URLs fail, `download_nvidia_repo.sh` prints a diagnosis per URL:
`404` means not published there, `403` means blocked, `000` means no connection. It also
reports, for information only, whether 615.71.09 is published for another Ubuntu release.
Another release or driver version is never used.

## 2. Commands on the offline H200

```bash
# Copy the ZIP from the USB drive to local disk. FAT/exFAT drops the executable bit.
lsblk
sudo mkdir -p /mnt/usb
sudo mount /dev/sdX1 /mnt/usb                     # your USB partition
mkdir -p ~/h200-nvidia
cp /mnt/usb/H200_NVIDIA_615.71.09_Ubuntu26.04_Offline.zip ~/h200-nvidia/
cp /mnt/usb/H200_NVIDIA_615.71.09_Ubuntu26.04_Offline.zip.sha256 ~/h200-nvidia/   # written by prepare_h200_usb.sh
sudo umount /mnt/usb
cd ~/h200-nvidia
sha256sum -c H200_NVIDIA_615.71.09_Ubuntu26.04_Offline.zip.sha256   # must print: OK

unzip H200_NVIDIA_615.71.09_Ubuntu26.04_Offline.zip
# (without unzip:  python3 -m zipfile -e H200_NVIDIA_615.71.09_Ubuntu26.04_Offline.zip . )
cd H200_NVIDIA_615.71.09_Ubuntu26.04_Offline

uname -r                                          # must be one of the ABIs in README.txt
sudo bash ./install_h200_nvidia_offline.sh --dry-run   # optional: verify + simulate, changes nothing
sudo bash ./install_h200_nvidia_offline.sh             # install

nvidia-smi
cat /proc/driver/nvidia/version                   # "NVIDIA UNIX Open Kernel Module ... 615.71.09"
```

Installer options: `--dry-run`, `--replace-existing-driver`, `--skip-gpu-check`, `--install-kernel`.
With `--replace-existing-driver` the bundle's 615.71.09 packages are pinned so APT also
downgrades a *newer* installed NVIDIA driver; without it, any other driver version stops
the installer (exit 13) before anything is changed.
The log is written to `install.log` in the bundle directory, or to
`/var/log/h200_nvidia_offline_install.log` if that directory is read-only.

| Exit | Meaning | Exit | Meaning |
|---|---|---|---|
| 0 | success | 21 | kernel headers missing |
| 1 | unexpected error (see `install.log`) | | |
| 2 | bad usage / not root | 30 | DKMS build failure |
| 3 | reboot required (nouveau in use, old module loaded, kernel installed) | 31 | Secure Boot / module signing / MOK not enrolled |
| 10 | wrong Ubuntu version or architecture | 32 | NVIDIA module failed to load |
| 11 | running kernel not supported by the bundle | 40 | nvidia-smi failed |
| 12 | bundle incomplete or corrupt (`SHA256SUMS`) | 41 | H200 not detected |
| 13 | conflicting NVIDIA driver (other version, `.run` install, Ubuntu prebuilt modules) | 42 | Fabric Manager not running (NVSwitch / HGX systems) |
| 20 | dependency / apt / dpkg failure | | |

## 3. What the builder does, step by step

1. **Verifies the build machine:** Ubuntu 26.04 (`/etc/os-release`), `x86_64`/dpkg `amd64`, the required tools, the Ubuntu archive keyring, free disk space, and Internet access. Internet access is proven by downloading the archive's `Release` file and checking that it reports `Version: 26.04`.
2. **Creates a clean working directory.** It refuses to delete any directory it did not create.
3. **Obtains `nvidia-driver-local-repo-ubuntu2604-615.71.09_1.0-1_amd64.deb`.**
   * It first uses a valid copy in `nvidia-downloads/`, checked against its `.sha256` file if present.
   * Otherwise it downloads the file over HTTPS from NVIDIA only. It tries `developer.download.nvidia.com/compute/nvidia-driver/615.71.09/local_installers/`, then `us.download.nvidia.com/tesla/615.71.09/`, then `international.download.nvidia.com/tesla/615.71.09/`, and saves the file in `nvidia-downloads/`.
   * If none of them serves the file, the build stops and prints the links and the exact place to put a manual download.

   It never falls back to another version or to the `.run` installer.
4. **Verifies the NVIDIA package:** it is a valid `.deb` with `Package: nvidia-driver-local-repo-ubuntu2604-615.71.09`, `Version: 1.0-1`, `Architecture: amd64`. Its SHA256 is recorded.
5. **Extracts it with `dpkg-deb -x`** into the working directory. It is never installed on the build machine. The APT source line and signing keyring shipped inside it are reused, and the NVIDIA repository signature is verified.
6. **Builds a private APT environment.** This is a separate `apt.conf`, sources, lists, cache and dpkg status inside the work directory. It contains:
   - the official Ubuntu archive `resolute`, `resolute-updates` and `resolute-security` (`main restricted universe multiverse`), signed by `ubuntu-archive-keyring.gpg`;
   - the extracted NVIDIA repository.

   Every NVIDIA repository package is **pinned (priority 1001) to its exact NVIDIA version**. Ubuntu 26.04 ships its own NVIDIA packages with overlapping names (branches 535–610), and the pin means those can never be selected instead. Architecture is forced to `amd64`, and the new `amd64v3` variants are disabled.
7. **Selects the NVIDIA package set.** The five requested packages are mapped to real package names found in the NVIDIA repository index:

   | Requested | Accepted real names (first one present wins) |
   |---|---|
   | `nvidia-dkms-open` | `nvidia-dkms-open`, `nvidia-dkms-615-open` |
   | `nvidia-kernel-source-open` | `nvidia-kernel-source-open`, `nvidia-kernel-source-615-open` |
   | `nvidia-kernel-common` | `nvidia-kernel-common`, `nvidia-kernel-common-615` |
   | `libnvidia-compute` | `libnvidia-compute`, `libnvidia-compute-615` |
   | `nvidia-open` | `nvidia-open`, `nvidia-open-615` |

   These are added when present:
   * `nvidia-utils[-615]` (nvidia-smi);
   * `nvidia-compute-utils[-615]`;
   * `nvidia-firmware[-615[-615.71.09]]`;
   * `nvidia-driver-pinning-615.71.09` or `nvidia-driver-pinning-615` (NVIDIA's version lock);
   * `nvidia-fabricmanager[-615]`.

   The version must be `615.71.09*`. If a required package is missing, the build stops and lists what is missing plus similar names that do exist. No name is invented. NVIDIA's 615 installation guide confirms that, from branch 590, the Ubuntu packages are unversioned (`nvidia-open`, `libnvidia-compute`, `nvidia-dkms-open`). Those are the names tried first.
8. **Finds the exact kernel**, never guessing. `7.0.0-generic` is a kernel *family*, not an installable package. The builder lists every `linux-headers-7.0.0-NN-generic` package in Ubuntu 26.04. With a family, it bundles all of them and reports them. With an exact ABI, that package must exist, otherwise the build stops and lists the available ABIs. If no `7.0.0-*-generic` headers exist at all, the build stops and lists the available flavours and kernel versions. On 2026-10-03 Ubuntu 26.04 provides `7.0.0-14, -15, -22, -27, -28, -29, -30, -31, -34, -38-generic`.
9. **Finds the matching "common" headers package** from the real `Depends:` of `linux-headers-<abi>`. On Ubuntu it is named `linux-headers-7.0.0-NN`; there is no `-common` suffix. It also **detects the compiler that built each kernel** from `CONFIG_GCC_VERSION` in the headers' `.config`: today `gcc 15.2`, so `gcc-15` is bundled.
10. **Resolves the full recursive dependency closure with APT** (see below), downloads every `.deb` with `apt-get download` (each file is hash-checked against the signed indexes), then re-checks each file's `Package`/`Version`/`Architecture`.
11. **Inspects the NVIDIA payload.** It looks inside the bundled packages for:
    * the DKMS source and `dkms.conf` (module name and version);
    * `/usr/bin/nvidia-smi`;
    * GSP firmware `/lib/firmware/nvidia/615.71.09/gsp*.bin` (mandatory for open modules on Hopper);
    * `libnvidia-ml.so.1` and `libcuda.so.1`.

    If something is missing, it searches every NVIDIA 615.71.09 package in the local repository for the file. It adds the package that ships it (marked "found by content" in `MANIFEST.txt`), resolves its dependencies, and checks again. This means an unexpected NVIDIA package name cannot silently produce a bundle without `nvidia-smi` or firmware. If a file cannot be found anywhere, the build stops.
12. **Writes** the local APT index, `bundle.conf`, `README.txt` and `MANIFEST.txt`.
13. **Validates the bundle** (section 5), writes and verifies `SHA256SUMS`, creates the ZIP, runs `unzip -t`, and checks that the installer, manifest, README, `SHA256SUMS` and every `.deb` are inside.

## 4. How dependency collection works

Installing only `dkms`, `build-essential` and `linux-headers-*` is **not** enough, and it is not
what this does. Everything is resolved by APT's own dependency solver, the same one the H200
will use, in up to three passes. The union of all passes is downloaded:

* **Pass 1 – full closure (always).** `apt-get -s install --no-install-recommends` of all explicit packages against an **empty dpkg database**. APT assumes nothing is installed and follows every `Depends`/`Pre-Depends` recursively. That covers gcc/g++/cpp, binutils, libc6-dev, make, patch, dpkg-dev, perl, kmod, openssl, libelf/libdw, the common headers, and so on. Virtual packages and `A | B` alternatives are resolved exactly as APT would resolve them. Explicit packages:
  * the NVIDIA packages above;
  * `dkms build-essential make kmod openssl gcc-<kernel compiler>`;
  * `linux-headers-<every selected ABI>`;
  * `mokutil`;
  * the Fabric Manager package.
* **Pass 2 – reference system.** The same resolution against the build machine's own dpkg database, which is a real Ubuntu 26.04 system. On a populated system APT sometimes has to upgrade "sibling" packages that are pinned to an exact version. This pass captures those (best effort).
* **Pass 3 – the H200 itself** (with `--target-state`). Resolution against the H200's captured `/var/lib/dpkg/status`. This is exactly what APT will do on the server.

`Recommends`/`Suggests` are excluded, so no CUDA Toolkit, Nsight, samples, documentation or
X/desktop packages are pulled unless they are a hard dependency. `nvidia-open` was explicitly
requested, and if NVIDIA's `nvidia-open` metapackage hard-depends on GL/X user-space
libraries, those come along as required dependencies. Every bundled package is listed with
its role (requested or dependency) and its source repository in `MANIFEST.txt`.

On the H200 the bundle is used as a **local APT repository**. The installer writes a private
APT configuration in `/tmp` whose only source is `file:<bundle>/packages`, and it does not
touch `/etc/apt`. APT then works out the dependency order and installs only what the server
is missing. Installation runs in two phases, so the kernel headers and compiler are
configured before the NVIDIA DKMS package builds the module:

* **Phase A:** toolchain + `linux-headers-$(uname -r)`.
* **Phase B:** NVIDIA packages.

## 5. Verification procedure: why `nvidia-smi` will work without Internet

1. **Builder validation (online, before the ZIP exists).** These are hard checks; the build fails if any of them fails:
   * A second private APT environment whose **only** source is the bundle's `packages/` directory simulates the complete installation for **each** kernel ABI on a bare system: toolchain + `gcc-NN` + `linux-headers-<abi>` + NVIDIA packages. Success proves every dependency is inside the bundle.
   * With `--target-state`, the same simulation runs against the H200's captured package database. It must succeed without removing any package other than NVIDIA driver packages, which include Ubuntu's prebuilt `linux-modules-nvidia-*`; those are replaced on the H200 with `--replace-existing-driver`.
   * One version per package (no duplicates); only `amd64`/`all` packages (no `amd64v3`, `arm64`, `i386`); no NVIDIA package of any other driver version; all requested NVIDIA packages present at `615.71.09`; headers, common headers, compiler and toolchain present.
   * NVIDIA payload present: `dkms.conf`, `nvidia-smi`, GSP firmware, NVML, `libcuda`.
   * `SHA256SUMS` written and re-verified; ZIP integrity tested; required files present in the ZIP.

   Two further checks are informational and only print a warning:
   * the simulation against the build machine's own package state (that machine is not the H200);
   * whether *all* bundled packages can be installed at the same time.
2. **On the H200, before changing anything:** `sudo bash ./install_h200_nvidia_offline.sh --dry-run`. It verifies:
   * the OS, architecture, and every SHA256;
   * that `uname -r` is one of the bundled ABIs;
   * the GPUs present on the PCI bus;
   * conflicting drivers;
   * the Secure Boot state.

   It then runs APT's simulation **against the server's real package database with the bundle as the only source**. A PASS here means the real installation cannot fail because of a missing package.
3. **Optional hard proof of "no network":** run the installer in an empty network namespace, `sudo unshare --net bash ./install_h200_nvidia_offline.sh`. The process then has no network interfaces at all.
4. **The installation verifies the result itself** and prints a PASS/FAIL report:
   * `dkms status` shows `nvidia/615.71.09, <kernel>: installed`;
   * `depmod` runs;
   * `modinfo` shows version `615.71.09` with license `Dual MIT/GPL` (the open module);
   * with Secure Boot, the module is signed and the MOK is enrolled;
   * `modprobe nvidia` and `modprobe nvidia_uvm` (needed by CUDA) both succeed. A failure exits 32, or 31 (Secure Boot key rejected), 41 (no usable GPU) or 3 (an old module still loaded, reboot needed);
   * `/proc/driver/nvidia/version` shows `Open Kernel Module ... 615.71.09`;
   * Fabric Manager is active if NVSwitches are present;
   * `nvidia-smi` succeeds, every GPU reports driver `615.71.09`, and at least one `NVIDIA H200` is listed.

   `nvidia-smi -q` and any DKMS `make.log` are saved to `install.log`.

### Problems the installer detects and explains

* wrong Ubuntu version or architecture;
* wrong kernel, with the list of supported ABIs;
* missing or corrupt files (`SHA256SUMS`, packages missing from the index);
* dependency failure (held packages, newer packages on the server), with a pointer to `--target-state`;
* missing headers;
* DKMS build failure (prints the end of `make.log`);
* Secure Boot: unsigned module, MOK not enrolled or enrollment pending, `Key was rejected by service`;
* nouveau in use (blacklists it and asks for a reboot);
* an older nvidia module still loaded;
* "No such device" / no H200 found;
* a `.run` installer driver, another NVIDIA driver version, or Ubuntu prebuilt `linux-modules-nvidia-*`;
* Fabric Manager not running on NVSwitch systems.

Nothing is removed or replaced without `--replace-existing-driver`.

## Validation status

The scripts were exercised in this repository's development environment as follows:

* **Builder.** Run inside a real Ubuntu 26.04 (`resolute`) userland, against the live official Ubuntu archive. Both root and a normal user were tested. Kernel ABI discovery, common-header discovery, the gcc-15 detection, the full dependency resolution, the downloads, the validation and the ZIP creation all ran for real. That covered a single ABI, all ten `7.0.0-NN-generic` ABIs, `--target-state` and `--with-kernel-image`. The refusal paths were tested too: a non-existent kernel family, a non-existent exact ABI, a wrong NVIDIA filename, and a missing NVIDIA package.
* **Installer.** Run on a fresh minimal Ubuntu 26.04 system **with networking removed**. It installed GCC 15, DKMS, and the real `linux-headers-7.0.0-38-generic` from the bundle only. DKMS then compiled a kernel module against those headers, and `depmod`/`modinfo` checks passed. Also tested: re-run idempotency, wrong-kernel detection, corrupt-package detection, non-root dry-run and `--install-kernel --dry-run`.
* **Automation tested.**
  * `prepare_h200_usb.sh` end to end, with a mounted drive. The SHA256 was re-verified with an uncached read. Paths on the system disk and on tmpfs were refused.
  * The `nvidia-downloads/` drop folder: reused without re-downloading, and a corrupt `.sha256` was rejected.
  * `download_nvidia_repo.sh --verify`: a wrong file name and an HTML error page saved as `.deb` were both rejected.
  * The no-network failure path, which prints the diagnosis, the links and the target path.
  * The content-based search: with `nvidia-smi` and the GSP firmware in unexpected packages, both were found and added.
* **Independent review.** A multi-agent review with five lenses checked the scripts:
  1. Bash correctness;
  2. the original specification;
  3. installer behaviour on real hardware;
  4. APT/bundle logic;
  5. documentation.

  Each finding was adversarially verified, and the confirmed issues were fixed and re-tested. Those tests covered:
  * an uncached USB read via `gnudd iflag=direct`, and refusal of tmpfs;
  * rejection of truncated NVIDIA downloads;
  * the wget-only diagnosis path;
  * guards against `/` or the output directory being used as the work directory;
  * `--replace-existing-driver` downgrading a newer installed driver (and exit 13 without the flag);
  * `nvidia-smi` parsing with stderr warnings, GH200-only GPUs (exit 41) and a wrong driver version (exit 40);
  * Secure Boot with shim validation disabled.

  A final full run of `prepare_h200_usb.sh` built the bundle and wrote it to the USB drive. On a fresh Ubuntu 26.04 target with no network, `sha256sum -c` passed, the dry-run passed, and the install passed every check up to loading the module.
* **Not possible there.** NVIDIA's servers (download, docs and developer sites) are blocked by that environment's network policy. A test-only stand-in for the NVIDIA local repository package was used instead: same layout, same signing scheme. Loading the module and running `nvidia-smi` need the H200 itself.

  Two cases make the builder stop and say exactly what is unavailable:
  * **The file isn't published at the URLs above.** Download it manually from NVIDIA's download page, put it into `nvidia-downloads/` (or pass `--nvidia-repo-deb`), and run again.
  * **The required packages have unexpected names.** The error lists the similar names that do exist in NVIDIA's repository. Add the real name to `role_candidates()` in the builder. Re-downloading the same file will not help. Missing `nvidia-smi`, firmware or library files are already found by content automatically.
