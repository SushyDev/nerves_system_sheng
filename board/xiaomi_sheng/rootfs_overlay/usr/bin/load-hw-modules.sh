#!/bin/sh
# POSIX sh, not bash - see boot-led-blink.sh header for why.
#
# No udev/mdev hotplug auto-loading on Nerves, so load WiFi/audio modules
# explicitly. modprobe pulls in each dependency chain via modules.dep.

modprobe ath12k 2>/dev/null
modprobe snd-soc-qcom-sdw 2>/dev/null
