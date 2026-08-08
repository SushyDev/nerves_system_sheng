#!/bin/sh
# POSIX sh, not bash - see boot-led-blink.sh's header comment for why.
#
# Nerves has no systemd-udevd/mdev hotplug auto-loading (confirmed:
# CONFIG_UEVENT_HELPER_PATH="" and no BR2_PACKAGE_MDEV), unlike the
# known-good references/debian-sheng reference this device's kernel config
# is otherwise matched against, which relies entirely on systemd for this.
# So the WiFi (ath12k) and audio (wcd938x/cs35l43 over SoundWire) drivers,
# built as modules to match that reference, need to be loaded explicitly.
# `modprobe <top-level module>` alone resolves and loads each dependency
# chain via modules.dep, generated at build time by depmod.

modprobe ath12k 2>/dev/null
modprobe snd-soc-qcom-sdw 2>/dev/null
