#!/bin/bash
set -e
echo "Building Nerves system for Xiaomi Pad 6S Pro..."
make clean
make BR2_DEFCONFIG=boards/xiaomi_sheng/nerves.defconfig -j$(nproc)
echo "✓ Build complete!"
ls -lh output/images/
