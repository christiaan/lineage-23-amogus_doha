# LineageOS 23.2 for the Moto G8 Plus (amogus_doha)

This repo has everything needed to rebuild our unofficial **LineageOS 23.2
(Android 16)** ROM for the **Motorola Moto G8 Plus** (`doha`, XT2019-1/2,
Snapdragon 665). In the source tree the device is called **`amogus_doha`**.

The repo has three parts:

| Path | What it is |
| --- | --- |
| `default.xml` | A `repo` manifest that pins all 1184 projects to the exact commits the released build used |
| `patches/` | Our fixes. `patches/<project path>.patch` applies to that project |
| `build.sh` | Syncs the sources, applies the patches and builds the zip |

The device tree and vendor blobs come from the community doha port by
Aldair402 and moto-common. We didn't write those. Our work is the
patches that get that port building and booting on LineageOS 23.2.

The kernel is our fork of Aldair402's
([`christiaan/android_kernel_motorola_msm-4.14`](https://github.com/christiaan/android_kernel_motorola_msm-4.14),
branch `lts`). Aldair402's kernel is Motorola's 4.14.190. Ours merges the
4.14 LTS updates up to 4.14.357 (OpenELA) on top of it, so it carries
several years of upstream security and stability fixes. `uname -r` shows
`4.14.357-openela+`.

## Requirements

- **x86-64 Linux** with Docker. The build runs inside the
  [`lineageos4microg/docker-lineage-cicd`](https://github.com/lineageos4microg/docker-lineage-cicd)
  image, which has all the build tools and `repo` installed. To build
  without Docker, install the
  [LineageOS build dependencies](https://wiki.lineageos.org/emulator#install-the-build-packages)
  and `repo` first.
- **About 350 GB of free disk**: roughly 200 GB for the synced sources and
  120 GB for `out/`. ccache adds up to 50 GB more if you enable it.
  On btrfs (or XFS) you can save most of the source part by starting from
  another LineageOS 23.2 checkout: `cp -a --reflink=always <that tree>
  <source dir>` shares its files and git history instead of copying
  them. Move its `.repo/local_manifests/*.xml` out of the copy first;
  `build.sh` then syncs it to this manifest and only downloads what
  differs. The sync doesn't remove the other tree's own changes, though:
  run `repo status` and revert or remove everything except the projects
  `build.sh` patches, and move out folders that no project in
  `default.xml` covers (`repo list -p` lists the projects). Our first
  build from a copied tree picked up another device's LatinIME change
  this way.
- **32 GB RAM plus at least 32 GB swap.** Soong's analysis step peaks around
  20 GB. With 28 GB RAM and 8 GB swap it was OOM-killed.
- A fast internet connection. The first sync downloads about 100 GB of
  git history.
- Time. A clean build (empty ccache) took 2 h 51 min on 16 threads with
  30 GB RAM. With a warm ccache, a rebuild takes about 7 minutes.

## Building

```sh
git clone https://github.com/christiaan/lineage-23-amogus_doha.git doha-lineage
mkdir -p ~/doha/src ~/doha/ccache ~/doha/zips

docker run --rm -it \
  --user "$(id -u):$(id -g)" -e HOME=/tmp \
  -v "$PWD/doha-lineage:/manifest:ro" \
  -v ~/doha/src:/src \
  -v ~/doha/ccache:/ccache -e CCACHE_DIR=/ccache \
  -v ~/doha/zips:/zips -e ZIP_DIR=/zips \
  --entrypoint /manifest/build.sh \
  lineageos4microg/docker-lineage-cicd:latest /src
```

Without Docker, run `./build.sh ~/doha/src` from the clone.

`build.sh` does the following:

1. Runs `repo init` against `default.xml` on the branch checked out in this
   clone, and then `repo sync`. Every project is pinned to a commit, so the
   sources you get are the same whenever you sync. repo reads the committed
   manifest, so the script stops if `default.xml` has uncommitted changes.
2. Resets each patched project and applies its patch from `patches/`, so
   you can run the script again safely. A project whose patch and files are
   unchanged since the last run is left alone, so its files keep their
   timestamps and the build doesn't redo work. A project whose patch was
   deleted is reset to its pinned commit.
3. Creates the empty file `device/motorola/amogus_doha/kernel-headers`
   (see [the kernel headers fix](#kernel-headers)).
4. Runs `breakfast amogus_doha userdebug` and
   `mka target-files-package bacon`.
5. Copies the zip, `boot.img`, `dtbo.img` and `vbmeta.img` into
   `~/doha/zips`, with a `.sha256sum` file.

The output is
`~/doha/zips/lineage-23.2-<date>-UNOFFICIAL-amogus_doha.zip`, next to
`lineage-23.2-<date>-UNOFFICIAL-amogus_doha-{boot,dtbo,vbmeta}.img`. Use
these copies, not the zips in `out/target/product/amogus_doha/`: `bacon`
hard-links the dated zip there to `lineage_amogus_doha-ota.zip`, and the
next build rewrites that file in place, so every older zip in `out/` ends
up holding the newest build. A second build on the same day replaces that
day's files in `~/doha/zips`.

Options: `JOBS=<n>` sets the build job count (the default is `nproc`).
`SYNC_JOBS=<n>` sets the sync job count (the default is 4). Keep it low:
android.googlesource.com rate-limits parallel fetches with `HTTP 429` /
`RESOURCE_EXHAUSTED`. If a sync still fails that way, wait a few minutes and
run the script again; it picks up where it stopped. `SKIP_SYNC=1` skips
`repo init` and `repo sync` on later runs. `CCACHE_SIZE=<size>` sets the
ccache limit (the default is `50G`). `ZIP_DIR=<dir>` changes where builds
are copied (the default is `zips/` next to the source directory).
`MANIFEST_BRANCH=<branch>` syncs a different branch of the manifest.
`SKIN_THROTTLE_C=<°C>` sets the skin temperature at which the thermal HAL
reports throttling (the default is 40). With Docker, pass these as
`-e NAME=value`.

The build is `userdebug`, unsigned (it uses the AOSP test keys) and has no
GApps.

## Installing

You need an unlocked bootloader. The phone is A/B, and the recovery is
inside `boot`.

1. `fastboot flash boot <boot.img>`. This is only needed when you're
   coming from stock or a different ROM.
2. Boot into recovery. Do a factory reset when coming from another ROM.
   Then choose **Apply update → Apply from ADB** and run
   `adb sideload lineage-23.2-*.zip`.
3. When the install finishes, recovery asks whether you want to install an
   additional zip. Choose **No**, then **Reboot system now**.

To update a phone that already runs this ROM, without touching it: turn
on USB debugging, authorize the computer, and run

```sh
adb reboot sideload-auto-reboot
adb wait-for-sideload
adb sideload lineage-23.2-*.zip
```

With `sideload-auto-reboot`, recovery skips the additional-zip prompt
and reboots into the new build by itself when the install is done.

Things you should know:

- **Recovery installs to the inactive slot** and then switches to it. If
  one slot holds a known-good ROM you want to keep, make that slot the
  active one before you sideload (`fastboot --set-active=<slot>`).
- During the sideload, the transfer slows down a lot at around 47%.
  Tapping the phone's screen speeds it up again.
- `adb sideload` doesn't exit until you answer the additional-zip prompt
  from step 3 (not with `sideload-auto-reboot`, which has no prompt).
- When you flash `vbmeta`, the bootloader prints
  `WARNING: vbmeta_a anti rollback downgrade, 0 vs 15`. That's expected
  on an unlocked doha, and the flash still goes through.

## Status

Tested on real hardware, and working: boot, mobile calls and data (SIM),
Wi-Fi (including WPA3-SAE), Bluetooth (HID devices and A2DP audio to a
speaker), NFC tag reading, GPS, fingerprint (FPC), vibration, camera, audio,
charging, VoLTE calls (4G calling, tested with a simyo SIM on KPN), and
starting the Wi-Fi hotspot and USB tethering.

Touch is tested on a unit with the Himax panel. Since 1.0.1 the
FocalTech and Novatek touch drivers load at boot too, for units with
those panels; they haven't been tested on such a unit yet.

Not verified yet: Bluetooth headset call audio (HFP); traffic from a
tethered device through mobile data (hotspot and USB tethering were tested
with mobile data off); 464XLAT on IPv6-only mobile networks.

---

## The fixes, and why each one is needed

Most of these problems come from pairing an Android 16 base with a device
that launched on Android 10 with a 4.14 kernel. The shared Qualcomm trees
also assume newer chips. Each section names the patch it lives in.

### Needed to get the build working

**`device/motorola/amogus`: drop the `hardware/qcom/bootctrl` namespace
import** (`Android.bp`). That project has only makefiles, so it doesn't
declare a Soong namespace, and Soong refuses to import a namespace that
doesn't exist. Nothing in the build used the import.

<a id="kernel-headers"></a>
**Kernel headers** (`device/motorola/targets`, `device/motorola/amogus`,
plus the empty file that `build.sh` creates).
`PRODUCT_VENDOR_KERNEL_HEADERS` normally gets set only for prebuilt
kernels. doha builds its kernel from source, so the variable was empty.
The `KERNEL_OBJ/usr` rule in `amogus/Android.mk` then ran `cp -a /.` and
copied the whole build machine's root filesystem into `out/`. The fix:

- `targets/include/kernel/source.mk` points the variable at the
  sanitized header export in `device/motorola/amogus-kernel/kernel-headers`.
- `Android.mk` only runs the rule when the variable is set.
- An empty *file* is placed at `device/motorola/amogus_doha/kernel-headers`.
  AOSP adds `$(TARGET_DEVICE_DIR)/kernel-headers` to the include path
  whenever that path exists, and there's no way to turn this off. A stale
  raw-header directory at that path shadowed bionic's headers and broke
  the compile (`redefinition of 'sigaction'`). A plain file keeps a
  directory from being created there.

**`device/motorola/amogus`: don't enforce VINTF kernel requirements**
(`device.mk`,
`PRODUCT_OTA_ENFORCE_VINTF_KERNEL_REQUIREMENTS := false`). doha ships with
API level 29, which maps to FCM level 5. The compatibility matrices in
Android 16 no longer list a 4.14 kernel for that level, so `checkvintf`
always rejects this kernel.

**`libqsap_sdk` can't be built** (`device/motorola/common`,
`device/qcom/common`, `hardware/motorola`). `libqsap_sdk` is built from
`system/qcom/softap/sdk/Android.mk`, and that file is on Android 16's
`androidmk_denylist.go`. Both `PRODUCT_PACKAGES` entries for it are
removed, and `libqsap_shim` (its only user among source-built modules) is
stubbed out. See the GSM fix below for the prebuilt copy that is
installed instead.

**Sepolicy duplicates and missing types** (`device/qcom/common`,
`device/qcom/sepolicy_vndr/legacy-um`, `device/lineage/sepolicy`,
`device/motorola/amogus`). doha's sepolicy includes two trees:
`device/qcom/sepolicy_vndr/legacy-um`, the tree for this SoC family, and
`device/qcom/common/sepolicy/generic` + `qva`. The second tree was written
for newer chips. Together they cause two kinds of hard errors from
`checkpolicy` and the `*_contexts` tests:

- *Duplicates.* A type, label, property or genfs entry is declared by both
  trees, or by a shared tree and doha's own device tree. We delete one
  copy and keep the device tree's copy where the two disagree. Affected:
  `vendor_persist_wcnss_service_file`, the IMS, persist/wlan and "taro"
  labels, the extcon genfs nodes, `persist.vendor.rcs.singlereg.`,
  `persist.vendor.bt.a2dp_offload_cap`, `xtwifi-inet-agent`,
  `/dev/sec-nfc`, the trinket `bms` and `vibrator` genfs nodes, and
  `sched_energy_aware`.
- *Missing types.* Some rules and labels use types that only exist for
  sm8450 and newer: DMA-BUF heap devices (`hal_drm_widevine.te`,
  `mediacodec.te`), the LOWI/SLIM/XTRA/XTWiFi location daemons, QMS
  (`mutualex`), QCC-TRD/qccvndhal, `perf_qesdk`/`sensors-qesdk`,
  `vendor_ims_service_socket`, `vendor_proc_swappiness`,
  `vendor_modprobe_prop` and the poweropt hwservice/service types. We
  remove only those lines. When nothing in a file applies to this SoC,
  the file is left empty.

`sepolicy_test` also requires every type used under `/vendor` to carry
`vendor_file_type`, so that attribute is added to
`vendor_camera_data_file` (legacy-um) and `vendor_sensor_data_file`
(amogus).

**`device/motorola/common`: power HAL build dependency**
(`power-libperfmgr/Android.bp`). The power HAL includes the generated
aconfig header `powerhal_flags.h` but didn't link
`powerhal_flags-aconfig-cc`, so every object file failed to compile.

**`vendor/qcom/opensource/audio/sm8150`: C23 thread signatures**
(`spkr_protection.c`). In C23, `void *f()` means `void *f(void)`. That
signature doesn't match `pthread_create`, and clang treats the mismatch
as an error. The patch gives both thread functions a `void *` parameter.

**`vendor/qcom/common`: don't install the `wificfr`/`wifilearner`
services** (`wlan-legacy-vendor.mk`). Their init `.rc` files declare
HIDL interfaces that no `hidl_interface` in the tree defines, so
`host_init_verifier` fails. The libraries and command-line tools are
still installed.

### Needed to boot

**BPF kernel-version gates** (`packages/modules/Connectivity`). Android 16
requires kernel 4.19 or newer for BPF networking. doha has 4.14.

- `NetBpfLoad.cpp`: the 4.9/4.14/4.19/5.4 checks returned an error, and
  `reboot_on_failure` in `netbpfload.rc` turned that into a bootloop. Now
  they only log a warning, like the 5.10 check below them already does.
  LineageOS's abandoned Gerrit change 433516 made the same change.
- `BpfHandler.cpp`: the same 4.19 and 5.4 gates in netd made
  `libnetd_updatable_init` abort. netd is a critical service, so init kept
  restarting the whole `main` class and `system_server` never started. Now
  they only log a warning.
- `BpfNetMaps.java`: the `local_net_access` and `local_net_blocked_uid`
  maps can't be created on 4.14. `system_server` threw on this and
  crashed. Now it treats the maps as unsupported and skips them.

**Thermal HAL** (`device/motorola/amogus`, `vendor/qcom/opensource/thermal`).

- doha ships the HIDL `android.hardware.thermal@2.0-service.qti`.
  legacy-um only labels the AIDL binary name, so the HIDL service had the
  generic `vendor_file` label, init couldn't start it, and
  `ctl.interface_start` failed. The patch adds a `hal_thermal_default_exec`
  label to amogus's `file_contexts`.
- With the service unable to start, `HardwarePropertiesManagerService`'s
  blocking `IThermal@1.0::getService()` on `system_server`'s main thread
  never returned, and the watchdog killed `system_server` after 67
  seconds, in a loop. The label fix is enough: the service implements 2.0
  and registers as both `@1.0::IThermal/default` and
  `@2.0::IThermal/default`, so the 1.0 lookup succeeds and
  `frameworks/base` needs no change.
- The HAL's trinket (soc 394) config names two thermal zones that doha's
  kernel doesn't have: the skin sensor `xo-therm-adc`, which is called
  `xo_therm` here, and the battery percentage sensor `soc`. The HAL gives
  up on all sensors when one is missing, so it answered every request with
  "ThermalHAL not initialized properly" and `ThermalManagerService` got no
  temperatures. The patch uses `xo_therm` and drops `soc`. The skin
  sensor reports throttling from 40 °C, Qualcomm's trinket value;
  `SKIN_THROTTLE_C` changes it (see the build options).
- `vendor/qcom/opensource/thermal`: the service in the `.rc` is renamed
  to `vendor.thermal-hal-doha`. This was a debugging attempt that didn't
  fix the problem. It's harmless, and we kept it because the tested build
  included it.

### Workarounds for the 4.14 kernel

Android 16 assumes a 5.10 or newer kernel. These patches put back
fallbacks for kernel features doha's 4.14 kernel doesn't have. The BPF
kernel-version gates under "Needed to boot" are the same kind of fix.

**Hotspot and USB tethering** (`bionic`). netd uses `posix_spawn()` with
`POSIX_SPAWN_CLOEXEC_DEFAULT` to start dnsmasq. Since bionic commit
`bf8fc35b7`, that flag relies on the `close_range()` syscall. doha's 4.14
kernel doesn't have `close_range()`, so the child process exited with
code 127 before dnsmasq ran, and tethering stopped with
`Failed to send update command to dnsmasq (Broken pipe)`. The patch
reverts that commit, which brings back the `fcntl()` fallback. clatd
(464XLAT on IPv6-only mobile networks) is started the same way.

### Hardware fixes

**Mobile network / SIM** (`vendor/motorola/amogus`, `device/motorola/amogus`).
The prebuilt `libmdmcutback.so`, which `qcrild` loads, needs
`libqsap_sdk.so`. With the source module gone (see above), nothing
installed the prebuilt copy that is already in the blob tree. `qcrild`
then failed to link, and the phone had no RIL and no SIM. The patch adds
the 32-bit and 64-bit blobs to `amogus-vendor.mk` and
`proprietary-files.txt`.

**Wi-Fi WPA3-SAE** (`kernel/motorola/msm-4.14`). Upstream Linux commit
`cc3e14c21ae9` ("nl80211: add WPA3 definition for SAE authentication") is
cherry-picked here. The kernel had the nl80211 SAE password attribute
from a partial CAF backport, but not `NL80211_WPA_VERSION_3`.
wpa_supplicant sent VERSION_3 for SAE, the kernel rejected it, and WPA3
networks reported a wrong password.

**Vibration and other kernel modules** (`device/motorola/amogus_doha`,
`BOARD_VENDOR_KERNEL_MODULES_LOAD`). LineageOS always writes
`vendor/lib/modules/modules.load`, even when the list is empty. An empty
file makes `init.modprobe.sh` skip its "load everything" fallback, so no
vendor module loaded. That included the aw8695 haptics driver, so the
vibrator didn't work. The patch lists the modules explicitly: `aw8624`,
`aw8695`, `sx933x_sar` and `stmvl53l1`, plus the FocalTech and Novatek
touch drivers (`focaltech_0flash_mmi`, `focaltech_0flash_mmi_doha`,
`nova_0flash_mmi`). Some doha units have those panels instead of the
Himax one, whose driver is built into the kernel; without them their
touchscreen was dead. Each touch driver only binds when its panel is
present.

**Bluetooth** (`vendor/qcom/opensource/interfaces`). The prebuilt QTI
Bluetooth HAL and FM implementation link against
`vendor.qti.hardware.fm@1.0.so`. LineageOS's copy of this project doesn't
define that interface, so the library wasn't built and the Bluetooth HAL
couldn't start. The patch adds the `fm@1.0` HIDL definition from
moto-common's fork.

**Fingerprint** (`device/motorola/common`, `init.oem.fingerprint2.sh`).
The script picks the fingerprint HAL from `fps_id`. It reads that from a
utag or from persist, and doha has neither. The script then fell through
to its Egistec default, which never registers on doha's FPC sensor and
floods the log with about 785 `getService` retries per second. The patch
adds a fallback to the factory descriptor `/proc/hw/fps_id/ascii`
(`fpc`), which is used only when nothing else supplied an ID.

**NFC** (`hardware/nxp/nfc`). doha has a PN553 on `nq-nci`. After about
2 seconds idle, the chip goes into standby and NACKs the first I2C write.
The snxxx HAL retried 6 times with no delay, so every retry landed in the
wake-up window, and then it called `abort()`. The patch adds back the
10 ms `usleep` between retries. It was in the first snxxx release and the
pn8x HAL has it too, but NXP commit `594411b` removed it as an unrelated
side change.

**GPS: remove QCC** (`vendor/qcom/common` `gps-vendor.mk`,
`device/motorola/common` `vintf/manifest-qcom.xml`). The prebuilt
`qccsyshal@1.2` system HAL was built against protobuf ~3.21 and can't
link against LineageOS 23.2's protobuf 25.8. It crash-looped, and the QCC
app restarted every 15 seconds waiting for it. The patch stops installing
the HAL, its libraries and the app, and removes its VINTF entry. GPS and
XTRA downloads work without it.

### Inherited from docker-lineage-cicd

**`system/core`: `0001-Pass-SafetyNet.patch`.** This is not our patch. The
docker-lineage-cicd image applies it by default (`APPLY_PI_PATCH=true`)
from [lineageos4microg/patches](https://github.com/lineageos4microg/patches),
and our released build included it. It makes init report a locked,
verified boot state so that basic Play Integrity passes, and it makes
fastbootd read the real lock state from the kernel command line. If you
don't want it, delete `patches/system/core.patch`.
