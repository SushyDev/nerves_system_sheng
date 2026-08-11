#!/usr/bin/env bash

set -e

# runs before rootfs.ext2 is packed - post-build.sh only sees the packed image

TARGET_DIR="$1"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# board/xiaomi_sheng/gpt/ is the single source of truth for GPT blobs - a
# stale duplicate under rootfs_overlay once caused a corrupted GPT write
# (see nerves_sheng_edl_brick_2026_08_11.md). Always copy fresh, no duplicates.
mkdir -p "$TARGET_DIR/usr/share/nerves_sheng/gpt"
cp "$SCRIPT_DIR/gpt/"*.bin "$TARGET_DIR/usr/share/nerves_sheng/gpt/"

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

# WCN7850 needs a flat board.bin, not board-2.bin multi-variant lookup -
# without it, wifi hangs forever at "Wait for device to enter SBL or
# Mission mode" (confirmed on hardware, reproduced twice).
ATH12K_FW_DIR="$TARGET_DIR/lib/firmware/ath12k/WCN7850/hw2.0"
if [ -f "$ATH12K_FW_DIR/board-2.bin" ]; then
    cp "$ATH12K_FW_DIR/board-2.bin" "$ATH12K_FW_DIR/board.bin"
fi

echo "✓ Device-specific firmware installed to \$TARGET_DIR/lib/firmware"
