#!/usr/bin/env bash

set -e

#
# Xiaomi Pad 6S Pro (SM8550) post-build target-dir fixups
#
# Runs on $TARGET_DIR (a plain directory tree) before Buildroot packs it into
# rootfs.ext2 - this is the right stage to touch files that a package already
# installed, since post-build.sh (BR2_ROOTFS_POST_IMAGE_SCRIPT) only ever sees
# the already-packed image.
#

TARGET_DIR="$1"

# Device-specific firmware (ath12k WiFi calibration, audio/sensor DSP images,
# Bluetooth, keyboard-auth co-processor, fingerprint sensor, GPU zap/ALSA
# topology). Buildroot's BR2_PACKAGE_LINUX_FIRMWARE_* selections in
# nerves.defconfig only provide *generic* upstream firmware - none of it is
# specific to this exact board (sm8550-xiaomi-sheng.dtb). This repo is the
# device-specific counterpart, actively used and validated by
# references/debian-sheng's own CI (its compatibility table reports
# WiFi/Audio/Bluetooth/Sensors/Keyboard all "Works" using this firmware set
# as-is). Fetched via git at build time, same as this system's kernel source
# (BR2_LINUX_KERNEL_CUSTOM_GIT in nerves.defconfig) - network-at-build-time is
# an already-accepted pattern here, not something new introduced by this step.
SHENG_FW_REPO="https://github.com/ianchb/sheng-firmware.git"
SHENG_FW_CLONE_DIR="$(mktemp -d)"

echo "Fetching device-specific firmware from $SHENG_FW_REPO..."
git clone --depth 1 "$SHENG_FW_REPO" "$SHENG_FW_CLONE_DIR"

mkdir -p "$TARGET_DIR/lib/firmware"
# Copy everything except git bookkeeping - the repo root is firmware
# directories/files only (ath12k, cirrus, nanosic, novatek, qca, qcom,
# fpcsheng.elf), no README/LICENSE to exclude.
rm -rf "$SHENG_FW_CLONE_DIR/.git"
cp -a "$SHENG_FW_CLONE_DIR/." "$TARGET_DIR/lib/firmware/"
rm -rf "$SHENG_FW_CLONE_DIR"

echo "✓ Device-specific firmware installed to \$TARGET_DIR/lib/firmware"

# NOTE: this supersedes the previous "copy ath12k board-2.bin to board.bin"
# single-variant workaround that used to live here. That workaround copied
# Buildroot's *generic* upstream board-2.bin (not Xiaomi-sheng-specific) as a
# guess; the fetch above overwrites it with the real device-specific
# board-2.bin from sheng-firmware, which references/debian-sheng's CI uses
# as-is (no rename) with WiFi confirmed working - so the rename hack is no
# longer needed.
