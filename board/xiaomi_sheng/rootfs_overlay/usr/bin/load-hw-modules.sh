#!/bin/sh
# POSIX sh, not bash: no BR2_PACKAGE_BASH here, only BusyBox ash.
#
# No udev/mdev hotplug auto-loading on Nerves, so load WiFi/audio modules
# explicitly. modprobe pulls in each dependency chain via modules.dep.

# wcn7850 needs qrtr up first - ath12k's fw handshake runs over QRTR/QMI,
# no timeout if it's missing, just hangs at MHI "Wait for SBL/Mission mode"
modprobe qrtr 2>/dev/null
modprobe qrtr_mhi 2>/dev/null
modprobe pwrseq-qcom-wcn 2>/dev/null
modprobe pci-pwrctrl-pwrseq 2>/dev/null
modprobe ath12k 2>/dev/null
modprobe ath12k_wifi7 2>/dev/null
modprobe snd-soc-qcom-sdw 2>/dev/null
