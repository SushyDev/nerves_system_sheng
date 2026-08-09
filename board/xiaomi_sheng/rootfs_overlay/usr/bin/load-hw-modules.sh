#!/bin/sh
# POSIX sh, not bash: no BR2_PACKAGE_BASH here, only BusyBox ash.
#
# No udev/mdev hotplug auto-loading on Nerves, so load WiFi/audio modules
# explicitly. modprobe pulls in each dependency chain via modules.dep.
#
# WCN7850 (WiFi chip) power sequencing: the chip sits behind PCIe but starts
# fully powered off - wlan-enable-gpios has to be toggled by the
# pwrseq-qcom-wcn platform driver before anything shows up on the PCI bus at
# all (confirmed live: /sys/bus/pci/devices/ is empty without this, and
# `modprobe ath12k` alone silently does nothing since there's no PCI device
# yet for it to bind to). pci-pwrctrl-pwrseq is the consumer side that
# actually drives the sequence and lets PCI retry enumeration once power is
# up - loading pwrseq-qcom-wcn alone isn't enough, both are required.
modprobe pwrseq-qcom-wcn 2>/dev/null
modprobe pci-pwrctrl-pwrseq 2>/dev/null

# wcn7850 needs qrtr up first - ath12k's fw handshake runs over QRTR/QMI,
# no timeout if it's missing, just hangs at MHI "Wait for SBL/Mission mode"
modprobe qrtr 2>/dev/null
modprobe qrtr_mhi 2>/dev/null

# ath12k_wifi7 is the actual PCI-bus-matching driver; ath12k alone doesn't
# pull it in automatically (confirmed live - modprobe ath12k succeeds but
# nothing binds until ath12k_wifi7 is also loaded).
modprobe ath12k 2>/dev/null
modprobe ath12k_wifi7 2>/dev/null

modprobe snd-soc-qcom-sdw 2>/dev/null
