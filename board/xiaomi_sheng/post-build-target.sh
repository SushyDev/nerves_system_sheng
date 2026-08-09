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

# ath12k_wifi7 on this exact device (confirmed by the community
# Xiaomi-pad-6s-pro-Linux port's fix_wifi_firmware helper) doesn't do the
# usual board-2.bin multi-variant lookup - it needs a flat board.bin. Without
# it, the WCN7850 hangs forever at "Wait for device to enter SBL or Mission
# mode" (confirmed on hardware - reproduced twice, 30+s with no timeout).
ATH12K_FW_DIR="$TARGET_DIR/lib/firmware/ath12k/WCN7850/hw2.0"
if [ -f "$ATH12K_FW_DIR/board-2.bin" ]; then
    cp "$ATH12K_FW_DIR/board-2.bin" "$ATH12K_FW_DIR/board.bin"
fi

echo "✓ Device-specific firmware installed to \$TARGET_DIR/lib/firmware"

# rootfs_overlay copy doesn't preserve the 600 this needs - erlang's :ssh
# host-key loading silently rejects group/world-readable private keys,
# which would fall back to the runtime-generation race this file exists
# to avoid (see config/target.exs).
chmod 600 "$TARGET_DIR/etc/nerves_ssh/ssh_host_ed25519_key"
