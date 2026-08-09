#!/usr/bin/env bash

set -e

# Boot image params (base/kernel_offset/tags_offset/pagesize/cmdline/header_version)
# byte-verified against the working reference boot.img from
# alghiffaryfa19/Linux-xiaomi-sheng. Don't change without re-verifying on hardware.

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

if [ -f "$KERNEL_IMAGE" ]; then
    echo "Compressing kernel..."
    gzip -9 -c "$KERNEL_IMAGE" > "${KERNEL_IMAGE}.gz"
    KERNEL_TO_USE="${KERNEL_IMAGE}.gz"
else
    echo "Error: Kernel image not found at $KERNEL_IMAGE"
    exit 1
fi

echo "Combining kernel.gz and device tree..."
cat "$KERNEL_TO_USE" "$DEVICE_TREE" > "$ZIMAGE"

# DTB is concatenated into the kernel payload, not passed via --dtb (header v2+) -
# this bootloader expects a legacy v0 header with no separate DTB field.
#
# console=ttyGS0: serial console over USB gadget (no UART adapter needed) -
# see USB_SERIAL_DEBUGGING.md.
CMDLINE="root=PARTLABEL=userdata rootwait rw console=ttyGS0,115200 earlycon=qcom_geni,0xa9c000 loglevel=8"
BASE="0x00000000"
KERNEL_OFFSET="0x00008000"
TAGS_OFFSET="0x01e00000"
PAGESIZE="4096"
HEADER_VERSION="0"

# see mkbootimg.py header for why it's vendored instead of an external binary
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

echo "Creating rootfs.img from rootfs.ext2..."
cp "$ROOTFS_EXT2" "$ROOTFS_IMG"

rm -f "${KERNEL_IMAGE}.gz" "$ZIMAGE"

echo "✓ Fastboot images created successfully:"
ls -lh "$BOOT_IMG" "$ROOTFS_IMG"
echo ""
echo "To flash with fastboot (see FLASHING_GUIDE.md for the full procedure):"
echo "  fastboot erase dtbo_a && fastboot erase dtbo_b"
echo "  fastboot flash boot_ab $BOOT_IMG"
echo "  fastboot flash userdata $ROOTFS_IMG"
