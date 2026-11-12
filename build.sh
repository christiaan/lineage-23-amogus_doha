#!/usr/bin/env bash
# Sync the pinned LineageOS 23.2 sources for amogus_doha (Moto G8 Plus),
# apply the fixes in patches/ and build the flashable zip.
#
# Usage: ./build.sh [SOURCE_DIR]      (default: ./lineage)
#
# Environment:
#   JOBS          parallel build jobs (default: nproc)
#   SYNC_JOBS     parallel repo sync jobs (default: 4)
#   MANIFEST_URL  manifest repo to init from (default: this checkout)
#   MANIFEST_BRANCH  manifest branch (default: this checkout's current
#                 branch, or main when MANIFEST_URL is set)
#   CCACHE_SIZE   ccache size limit (default: 50G)
#   SKIN_THROTTLE_C  skin temperature (°C) at which the thermal HAL reports
#                 throttling (default: 40)
#   ZIP_DIR       where finished builds are copied (default: zips/ next to
#                 SOURCE_DIR)
#   SKIP_SYNC=1   don't run repo init or repo sync
#   ADB_KEY       test builds only: an adb public key (adbkey.pub) to trust
#                 in recovery and Android, with USB adb on by default, so
#                 adb works after a wipe without tapping "Allow"
#                 (doha_android#64). The zip gets an -adbkey suffix. Never
#                 release such a build.
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SRC=$(mkdir -p "${1:-$PWD/lineage}" && cd "${1:-$PWD/lineage}" && pwd)
JOBS=${JOBS:-$(nproc)}
# Most projects come from android.googlesource.com, which answers too many
# parallel fetches with HTTP 429 / RESOURCE_EXHAUSTED. repo then retries each
# failed fetch as a full fetch of every branch, which makes it worse.
SYNC_JOBS=${SYNC_JOBS:-4}
MANIFEST_URL=${MANIFEST_URL:-$HERE}
DEVICE=amogus_doha
# Projects patched by the last run, as "<project> <patch blob> <tree>" lines.
STAMP=$SRC/.repo/doha-patches
SKIN_THROTTLE_C=${SKIN_THROTTLE_C:-40}
case $SKIN_THROTTLE_C in
  ''|*[!0-9]*) echo "SKIN_THROTTLE_C must be a whole number of °C" >&2; exit 1 ;;
esac

# repo needs a git identity, and git refuses to read a checkout owned by
# another user (common when this runs in a container). Pass both as
# command-line config so nothing is written to ~/.gitconfig.
name=$(git config user.name || echo builder)
email=$(git config user.email || echo builder@localhost)
export GIT_CONFIG_COUNT=3
export GIT_CONFIG_KEY_0=safe.directory GIT_CONFIG_VALUE_0='*'
export GIT_CONFIG_KEY_1=user.name GIT_CONFIG_VALUE_1="$name"
export GIT_CONFIG_KEY_2=user.email GIT_CONFIG_VALUE_2="$email"

cd "$SRC"

if [ "${SKIP_SYNC:-0}" != 1 ]; then
  # repo reads the manifest from a committed branch, while the patches come
  # from the working tree. Sync the branch that is checked out here, and refuse
  # to run with an uncommitted default.xml, so the two always match.
  if [ "$MANIFEST_URL" = "$HERE" ]; then
    if [ -z "${MANIFEST_BRANCH:-}" ]; then
      MANIFEST_BRANCH=$(git -C "$HERE" symbolic-ref -q --short HEAD) || {
        echo "$HERE has a detached HEAD; check out a branch or set MANIFEST_BRANCH" >&2
        exit 1
      }
    fi
    if ! git -C "$HERE" diff --quiet HEAD -- default.xml; then
      echo "default.xml has uncommitted changes; repo would not see them. Commit them first." >&2
      exit 1
    fi
  fi
  MANIFEST_BRANCH=${MANIFEST_BRANCH:-main}

  # Run init every time so a changed MANIFEST_URL or branch takes effect.
  repo init -u "$MANIFEST_URL" -b "$MANIFEST_BRANCH" -m default.xml --git-lfs -g default,-darwin
  # --force-checkout lets a pin bump replace a project that still carries
  # the previous run's patch. Projects already at their pin aren't touched.
  repo sync -c -j"$SYNC_JOBS" --retry-fetches=5 --force-sync --force-checkout \
    --no-tags --no-clone-bundle
fi

# The tree object of a project's working tree, including untracked files, so
# we can tell whether it is still exactly as the last run left it.
worktree_id() {
  local index
  index=$(mktemp)
  (cd "$1" && cp "$(git rev-parse --git-path index)" "$index")
  GIT_INDEX_FILE=$index git -C "$1" add -A
  GIT_INDEX_FILE=$index git -C "$1" write-tree
  rm -f "$index"
}

reset_project() {
  git -C "$1" reset -q --hard
  git -C "$1" clean -q -fd
}

declare -A old_patch old_tree
if [ -f "$STAMP" ]; then
  while read -r proj blob tree; do
    old_patch[$proj]=$blob
    old_tree[$proj]=$tree
  done < "$STAMP"
fi

# Each patches/<project path>.patch applies to that project.
mapfile -t projects < <(cd "$HERE/patches" && find . -name '*.patch' | sed 's|^\./||; s|\.patch$||' | sort)
declare -A patched
for proj in "${projects[@]}"; do
  patched[$proj]=1
done

# Undo patches that were removed or renamed since the last run.
for proj in "${!old_patch[@]}"; do
  if [ -z "${patched[$proj]:-}" ] && [ -d "$proj" ]; then
    reset_project "$proj"
    echo "reverted $proj (its patch is gone)"
  fi
done

# Leave a project alone when its patch hasn't changed and its tree is
# exactly as the last run left it: rewriting the files would change their
# mtimes and make the build redo work. Otherwise reset it and apply the
# patch again, so a patch is never applied twice.
# Patches can contain @NAME@ placeholders for build settings. The recorded
# blob is that of the filled-in patch, so changing a setting counts as a
# changed patch.
render_patch() {
  sed "s/@SKIN_THROTTLE_MC@/$((SKIN_THROTTLE_C * 1000))/g" "$HERE/patches/$1.patch"
}

for proj in "${projects[@]}"; do
  if [ "$(render_patch "$proj" | git hash-object --stdin)" = "${old_patch[$proj]:-}" ] &&
     [ "$(worktree_id "$proj")" = "${old_tree[$proj]:-}" ]; then
    echo "unchanged patches/$proj.patch"
    continue
  fi
  reset_project "$proj"
  render_patch "$proj" | git -C "$proj" apply --whitespace=nowarn
  echo "applied patches/$proj.patch"
done

# An empty *file* at this path stops AOSP from treating
# device/motorola/amogus_doha/kernel-headers as the device's kernel header
# directory (it is added to the include path whenever the path exists, and
# there's no opt-out). The real headers come from
# PRODUCT_VENDOR_KERNEL_HEADERS, set in patches/device/motorola/targets.patch.
[ -e device/motorola/amogus_doha/kernel-headers ] ||
  : > device/motorola/amogus_doha/kernel-headers

# Record the result only now, after kernel-headers exists, so the next run
# sees the same trees.
for proj in "${projects[@]}"; do
  echo "$proj $(render_patch "$proj" | git hash-object --stdin) $(worktree_id "$proj")"
done > "$STAMP.new"
mv "$STAMP.new" "$STAMP"

# Test builds can trust the build host's adb key (doha_android#64), through
# vendor/extra/product.mk, which vendor/lineage/config/common.mk inherits
# when it exists. It isn't in the manifest, so repo never touches it.
# PRODUCT_ADB_KEYS isn't used: Soong installs it only when ro.debuggable=1,
# and LineageOS userdebug builds set ro.debuggable=0.
product=$SRC/out/target/product/$DEVICE
key_files=("$product/recovery/root/system/product/etc/security/adb_keys" "$product/product/etc/security/adb_keys")
rm -rf vendor/extra
if [ -n "${ADB_KEY:-}" ]; then
  key=$(cat "$ADB_KEY")
  case $key in
    QAAAA*) ;;
    *) echo "ADB_KEY must be an adb public key (adbkey.pub): $ADB_KEY" >&2; exit 1 ;;
  esac
  mkdir -p vendor/extra
  printf '%s\n' "$key" > vendor/extra/adb_keys
  cat > vendor/extra/product.mk <<'MK'
# Written by doha-lineage build.sh because ADB_KEY was set (doha_android#64).
# Recovery's adbd and the system's adbd both trust /adb_keys, a symlink to
# /product/etc/security/adb_keys in both ramdisks. In recovery /product
# points to /system/product inside the ramdisk, so the key goes there; a
# file at recovery's /adb_keys is replaced by the symlink. ro.adb.secure
# stays 1.
PRODUCT_COPY_FILES += \
    vendor/extra/adb_keys:$(TARGET_COPY_OUT_RECOVERY)/root/system/product/etc/security/adb_keys \
    vendor/extra/adb_keys:$(TARGET_COPY_OUT_PRODUCT)/etc/security/adb_keys
PRODUCT_SYSTEM_DEFAULT_PROPERTIES += persist.sys.usb.config=adb
MK
else
  # Copied files stay in out/ after their rule is gone and would end up in
  # the images, so a normal build after a test build must delete them.
  rm -f "${key_files[@]}"
fi

export ALLOW_MISSING_DEPENDENCIES=true
if command -v ccache >/dev/null; then
  export USE_CCACHE=1 CCACHE_EXEC=$(command -v ccache)
  # ccache's own default is 5 GB, far too small for this build.
  ccache -M "${CCACHE_SIZE:-50G}" >/dev/null
fi

# envsetup.sh, breakfast and mka aren't errexit/nounset-clean, so check
# their results by hand.
set +eu
source build/envsetup.sh
breakfast "$DEVICE" userdebug || exit 1
mka -j"$JOBS" target-files-package bacon || exit 1
set -eu

if [ -z "${ADB_KEY:-}" ]; then
  for f in "${key_files[@]}"; do
    [ ! -e "$f" ] || { echo "$f exists in a build without ADB_KEY" >&2; exit 1; }
  done
fi

# bacon hard-links the dated zip to lineage_<device>-ota.zip, which the next
# build rewrites in place, so every earlier zip in out/ ends up holding the
# newest build. Keep a real copy of each build, with its images.
images=$product/obj/PACKAGING/target_files_intermediates/lineage_$DEVICE-target_files/IMAGES
dest=${ZIP_DIR:-$(dirname "$SRC")/zips}
# Take the name from the dated zip that bacon linked to the -ota.zip.
# Asking get_build_var for LINEAGE_VERSION here gives today's date, which
# is wrong when the build ran past midnight UTC (doha_android#55). /e/'s
# vendor/lineage names the zip e-<version>.zip instead of lineage-<version>.zip.
ota=$product/lineage_$DEVICE-ota.zip
zip=$(find "$product" -maxdepth 1 -name '*.zip' ! -name "${ota##*/}" -samefile "$ota" | head -1)
[ -n "$zip" ] || { echo "No dated zip hard-linked to $ota" >&2; exit 1; }
built=$(basename "$zip" .zip)
name=$built${ADB_KEY:+-adbkey}
mkdir -p "$dest"
cp "$product/$built.zip" "$dest/$name.zip"
for img in boot dtbo vbmeta; do
  cp "$images/$img.img" "$dest/$name-$img.img"
done
(cd "$dest" && sha256sum "$name.zip" "$name"-{boot,dtbo,vbmeta}.img > "$name.sha256sum")

echo
echo "Done. Build copied to $dest:"
ls -1 "$dest/$name"*
