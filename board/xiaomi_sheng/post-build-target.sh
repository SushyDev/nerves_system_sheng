#!/usr/bin/env bash

set -e

# runs before rootfs.ext2 is packed - post-build.sh only sees the packed image

TARGET_DIR="$1"

# nerves.defconfig's linux-firmware is generic upstream only; fetch real
# sheng firmware (wifi/audio/bt/sensors) via git, same as the kernel source
SHENG_FW_REPO="https://github.com/ianchb/sheng-firmware.git"
SHENG_FW_CLONE_DIR="$(mktemp -d)"

echo "Fetching device-specific firmware from $SHENG_FW_REPO..."
git clone --depth 1 "$SHENG_FW_REPO" "$SHENG_FW_CLONE_DIR"

mkdir -p "$TARGET_DIR/lib/firmware"
rm -rf "$SHENG_FW_CLONE_DIR/.git"
cp -a "$SHENG_FW_CLONE_DIR/." "$TARGET_DIR/lib/firmware/"
rm -rf "$SHENG_FW_CLONE_DIR"

echo "✓ Device-specific firmware installed to \$TARGET_DIR/lib/firmware"
