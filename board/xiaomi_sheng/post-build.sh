#!/usr/bin/env bash

set -e

#
# Xiaomi Pad 6S Pro (SM8550) post-build hook
# Creates fastboot-compatible boot.img and rootfs.img from kernel, DTB, and filesystem
#
# Boot image parameters (base, kernel_offset, tags_offset, pagesize, cmdline, header_version)
# have been byte-verified against the working reference boot.img from
# alghiffaryfa19/Linux-xiaomi-sheng project via Android AOSP bootimg header parsing
# (including IKCONFIG kernel config extraction). Do not change these values without
# re-verifying against known hardware — they are device-specific, not generic.
#

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MKBOOTIMG="$SCRIPT_DIR/mkbootimg.py"

IMAGES_DIR="${BINARIES_DIR:-.}"
KERNEL_IMAGE="$IMAGES_DIR/Image"
DEVICE_TREE="$IMAGES_DIR/sm8550-xiaomi-sheng.dtb"
ROOTFS_EXT2="$IMAGES_DIR/rootfs.ext2"

BOOT_IMG="$IMAGES_DIR/boot.img"
ROOTFS_IMG="$IMAGES_DIR/rootfs.img"
ZIMAGE="$IMAGES_DIR/zImage"

echo "Creating Android boot.img with kernel and device tree..."

# Compress kernel image if not already compressed
if [ -f "$KERNEL_IMAGE" ]; then
    echo "Compressing kernel..."
    gzip -9 -c "$KERNEL_IMAGE" > "${KERNEL_IMAGE}.gz"
    KERNEL_TO_USE="${KERNEL_IMAGE}.gz"
else
    echo "Error: Kernel image not found at $KERNEL_IMAGE"
    exit 1
fi

# Combine compressed kernel with DTB (Image.gz-dtb convention)
echo "Combining kernel.gz and device tree..."
cat "$KERNEL_TO_USE" "$DEVICE_TREE" > "$ZIMAGE"

# SM8550 boot image parameters (verified against known-good reference)
# Note: DTB is concatenated into kernel payload, not passed via --dtb (which is header v2+)
# This device's bootloader expects legacy v0 header with no separate DTB field
#
# === USB Serial Gadget Debugging ===
# The SM8550 can route its serial console over USB using the Linux USB Gadget framework.
# This allows real-time debugging without a UART adapter - just connect via USB to the host PC.
#
# Kernel config requirements:
#   CONFIG_USB_GADGET=y                    Enable USB gadget device mode (vs host mode)
#   CONFIG_USB_G_SERIAL=y                  USB serial gadget function (provides /dev/ttyGS0)
#   CONFIG_SERIAL_QCOM_GENI=y              Qualcomm GENI UART driver (SM8550 serial IP)
#   CONFIG_SERIAL_QCOM_GENI_CONSOLE=y      Route console to GENI UARTs
#
# Kernel cmdline parameters:
#   console=ttyGS0,115200                  Main kernel console → USB gadget serial at 115200 baud
#   earlycon=qcom_geni,0xa9c000            Early boot console (before drivers load) via GENI at addr 0xa9c000
#   loglevel=8                             Print all kernel messages (DEBUG level)
#
# On the host side:
#   The device appears as /dev/ttyUSB0 (or similar) when booting into Nerves.
#   Connect with: screen /dev/ttyUSB0 115200
#   You'll see kernel boot messages and Erlang VM output in real-time.
#
CMDLINE="root=PARTLABEL=userdata rootwait rw console=ttyGS0,115200 earlycon=qcom_geni,0xa9c000 loglevel=8"
BASE="0x00000000"
KERNEL_OFFSET="0x00008000"
TAGS_OFFSET="0x01e00000"
PAGESIZE="4096"
HEADER_VERSION="0"

# Use our vendored mkbootimg.py (see that file's header comment for why we
# don't rely on an external `mkbootimg` binary: it's not installed in the
# Docker build container this script actually runs in, and silently falling
# back to a headerless image here previously produced an unbootable image
# with zero warning). python3 is a hard Buildroot/Docker dependency, so if
# this fails, fail loudly rather than emitting a broken boot.img.
echo "Using vendored mkbootimg.py to create proper Android boot image..."
python3 "$MKBOOTIMG" \
  --kernel "$ZIMAGE" \
  --cmdline "$CMDLINE" \
  --base "$BASE" \
  --kernel_offset "$KERNEL_OFFSET" \
  --tags_offset "$TAGS_OFFSET" \
  --pagesize "$PAGESIZE" \
  --header_version "$HEADER_VERSION" \
  --id \
  --output "$BOOT_IMG"

# Create rootfs.img from ext2
echo "Creating rootfs.img from rootfs.ext2..."
cp "$ROOTFS_EXT2" "$ROOTFS_IMG"

# Cleanup temporary files
rm -f "${KERNEL_IMAGE}.gz" "$ZIMAGE"

echo "✓ Fastboot images created successfully:"
ls -lh "$BOOT_IMG" "$ROOTFS_IMG"
echo ""
echo "To flash with fastboot (see FLASHING_GUIDE.md for the full procedure):"
echo "  fastboot erase dtbo_a && fastboot erase dtbo_b"
echo "  fastboot flash boot_ab $BOOT_IMG"
echo "  fastboot flash userdata $ROOTFS_IMG"
