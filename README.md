# LineageOS 24.0 for OnePlus 15R (macan) — OSS kernel

Local manifest to build **unofficial** LineageOS 24.0 (Android 17) for the
OnePlus 15R (`macan`, CPH2769) with the kernel built **from source**.

Maintainer: dlearin

## What this is

- Common tree, kernel, devicetrees, modules and `hardware/oplus` come
  straight from the [LineageOS](https://github.com/LineageOS) org.
- The `macan` device tree is a fork of
  [OnePlus-SM8850-Development](https://github.com/OnePlus-SM8850-Development)
  (by chandu078) with the changes below, until an official `macan` tree
  lands in LineageOS.
- The `macan` blobs are extracted from the stock OTA (see below). The
  common blobs come from [TheMuppets](https://github.com/TheMuppets).

### Changes on top of the upstream macan tree

Device tree ([`lineage-24.0-oss`](https://github.com/cfernande1408/android_device_oneplus_macan/tree/lineage-24.0-oss)), oldest first:

| Commit | Why |
|---|---|
| `macan: Build kernel from LineageOS sources` | Disable the prebuilt kernel and select `macan_dtbo_config` via `TARGET_KERNEL_BAZEL_FLAGS`, like fairlady/infiniti. |
| `macan: Ship face unlock algorithm library` | The common face HAL links against `libstfaceunlockocl_uff` (a dummy in common), same as infiniti. |
| `macan: Install ACDB where AGM expects it` | Audio calibration files in the paths AGM loads them from. |
| `macan: Enable burn-in protection` | OLED burn-in protection. |
| `macan: Drop prebuilt kernel option` | The kernel is always built from source. |
| `macan: Ship ACDB and face lib via vendor` | Declare them in `proprietary-files.txt`. |
| `macan: Raise SurfaceFlinger idle timer` | 80 → 500 ms. Fixes screen flicker while typing (60/120 Hz switching). |
| `macan: Reboot on kernel panic` | `qcom_dload_mode.download_mode=0`: reboot instead of hanging in crash dump mode. |
| `macan: Drop SenseTime lib from Live Photo blobs` | Match infiniti. |
| `macan: Don't auto-upgrade hotspot to bridged` | Match stock. Fixes intermittent hotspot drops. Also proposed for the common tree: [510001](https://review.lineageos.org/c/LineageOS/android_device_oneplus_sm8850-common/+/510001). |
| `macan: Ship face unlock TA firmware` | Without the `uff_face` trusted app the face HAL never starts. Match infiniti. |

Pending in Gerrit (factory Wi-Fi MAC):
[509163](https://review.lineageos.org/c/LineageOS/android_kernel_oneplus_sm8850-modules/+/509163),
[509164](https://review.lineageos.org/c/LineageOS/android_kernel_oneplus_sm8850-modules/+/509164).

## Build

### Sync

```bash
repo init -u https://github.com/LineageOS/android.git -b lineage-24.0 --git-lfs --no-clone-bundle
mkdir -p .repo/local_manifests
curl -L https://raw.githubusercontent.com/cfernande1408/local_manifests_macan/lineage-24.0/macan.xml \
  -o .repo/local_manifests/macan.xml
repo sync -c -j8 --force-sync --no-tags --no-clone-bundle
```

### Blobs

Get the full OxygenOS OTA zip for CPH2769, version 16.0.10.600 (EX01), and
extract only the `macan` blobs (the common ones come from TheMuppets):

```bash
sudo apt install erofs-utils
cd device/oneplus/macan
./extract-files.py /path/to/CPH2769_16.0.10.600_EX01.zip --only-target
cd -
```

### Pending changes

```bash
source build/envsetup.sh
repopick -t icnss2-dms-mac
```

### Compile

```bash
source build/envsetup.sh
source vendor/lineage/vars/aosp_target_release
lunch lineage_macan-${aosp_target_release}-userdebug
m bacon target-files-package otatools
```

The first `lunch` also syncs the kernel 6.12 build environment
(`kernel/platform/kernel-6.12`) through roomservice.

### Sign with your own keys (recommended)

```bash
curl -LO https://raw.githubusercontent.com/cfernande1408/local_manifests_macan/lineage-24.0/scripts/sign-macan.sh
bash sign-macan.sh
```

On the first run it creates the keys in `~/.android-certs`. Keep them
private and backed up: a build signed with other keys can't be installed
over yours without wiping data. Signing needs about 40 GB free
(`NEED_GB=36` lowers the check). The output goes to `release/`.

Tips:

- If `systemd-oomd` kills the build, stop it while building:
  `sudo systemctl mask --runtime systemd-oomd.service systemd-oomd.socket`
- With limited RAM use `m -j8` (or lower).
- To debug a bootloop, build with `export WITH_ADB_INSECURE=true` to get adb
  without authorization during boot. Never ship such a build.

## Install notes

- The zip flashes the EU firmware (16.0.10.600), so ROM and firmware always
  match. The Ace 6T is not supported.
- Updating between builds signed with the same keys needs no data wipe:
  sideload the ROM, reboot to recovery, sideload GApps again, reboot.

## Credits

- [chandu078](https://github.com/chandu078) and the OnePlus SM8850 maintainers
  for the device trees and the LineageOS kernel work
- [LineageOS](https://lineageos.org)
- [TheMuppets](https://github.com/TheMuppets) for the common vendor blobs
- OnePlus for the [kernel sources](https://github.com/OnePlusOSS)
