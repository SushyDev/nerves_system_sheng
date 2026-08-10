#!/bin/sh
# erlinit -c (pre-Erlang), deliberately separate from load-hw-modules.sh:
# nerves_heart opens /dev/watchdog0 during its own init, before any Elixir
# code runs, so qcom_wdt must be loaded before erlinit starts the release -
# confirmed on hardware (dmesg: "nerves_heart: can't open '/dev/watchdog0'"
# at 13s, well before HardwareModules.load!/0 ever got a chance to run its
# post-Erlang modprobe). Unlike ath12k, qcom_wdt has no known hang risk, so
# it's safe here even though the WiFi/audio modules deliberately aren't.
modprobe qcom_wdt 2>/dev/null
