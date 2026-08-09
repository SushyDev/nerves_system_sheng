#!/usr/bin/env bash

set -e

# Runs on $TARGET_DIR before Buildroot packs rootfs.ext2 - the right stage to
# add files a package already installed (post-build.sh only sees the packed image).

TARGET_DIR="$1"

# nerves.defconfig's linux-firmware selections are generic upstream only, so
# fetch the real Xiaomi-sheng firmware set (WiFi/audio/BT/sensors/etc) the
# same way the kernel source is fetched: git, at build time.
SHENG_FW_REPO="https://github.com/ianchb/sheng-firmware.git"
SHENG_FW_CLONE_DIR="$(mktemp -d)"

echo "Fetching device-specific firmware from $SHENG_FW_REPO..."
git clone --depth 1 "$SHENG_FW_REPO" "$SHENG_FW_CLONE_DIR"

mkdir -p "$TARGET_DIR/lib/firmware"
rm -rf "$SHENG_FW_CLONE_DIR/.git"
cp -a "$SHENG_FW_CLONE_DIR/." "$TARGET_DIR/lib/firmware/"
rm -rf "$SHENG_FW_CLONE_DIR"

echo "✓ Device-specific firmware installed to \$TARGET_DIR/lib/firmware"
