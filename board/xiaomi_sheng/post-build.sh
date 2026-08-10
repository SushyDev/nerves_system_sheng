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
BOOT_A_IMG="$IMAGES_DIR/boot_a.img"
BOOT_B_IMG="$IMAGES_DIR/boot_b.img"
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
#
# root=PARTLABEL differs per slot (real dual-rootfs A/B) - everything else
# is identical, so boot_a.img/boot_b.img only differ in this one field.
CMDLINE_COMMON="rootwait rw console=ttyGS0,115200 earlycon=qcom_geni,0xa9c000"
BASE="0x00000000"
KERNEL_OFFSET="0x00008000"
TAGS_OFFSET="0x01e00000"
PAGESIZE="4096"
HEADER_VERSION="0"

# vendored AOSP mkbootimg.py: buildroot host has no prebuilt mkbootimg binary
echo "Using vendored mkbootimg.py to create proper Android boot images..."
for slot in a b; do
  case "$slot" in
    a) OUT="$BOOT_A_IMG" ;;
    b) OUT="$BOOT_B_IMG" ;;
  esac
  python3 "$MKBOOTIMG" \
    --kernel "$ZIMAGE" \
    --cmdline "root=PARTLABEL=rootfs_$slot $CMDLINE_COMMON" \
    --base "$BASE" \
    --kernel_offset "$KERNEL_OFFSET" \
    --tags_offset "$TAGS_OFFSET" \
    --pagesize "$PAGESIZE" \
    --header_version "$HEADER_VERSION" \
    --id \
    --output "$OUT"
done

# Non-A/B single-partition boot.img (root=PARTLABEL=userdata), for the
# bootstrap flash - still needed alongside the A/B images above.
python3 "$MKBOOTIMG" \
  --kernel "$ZIMAGE" \
  --cmdline "root=PARTLABEL=userdata $CMDLINE_COMMON" \
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
ls -lh "$BOOT_IMG" "$BOOT_A_IMG" "$BOOT_B_IMG" "$ROOTFS_IMG"
echo ""
echo "See FLASHING_GUIDE.md for the full procedure"
echo "First bootstrapped flash requires flashing data.img"
echo "Bootstrapped A/B dual-partition:"
echo "  fastboot erase dtbo_a && fastboot erase dtbo_b"
echo "  fastboot flash boot_a $BOOT_A_IMG"
echo "  fastboot flash boot_b $BOOT_B_IMG"
echo "  fastboot flash rootfs_a $ROOTFS_IMG   # only on a fresh/unmigrated userdata GPT"
echo "  fastboot flash rootfs_b $ROOTFS_IMG   # one-time bootstrap so slot B is bootable too"
echo ""
echo "Non-A/B single-partition bootstrap:"
echo "  fastboot erase dtbo_a && fastboot erase dtbo_b"
echo "  fastboot flash boot_ab $BOOT_IMG"
echo "  fastboot flash userdata $ROOTFS_IMG"
