#!/bin/sh
# POSIX sh, not bash - see boot-led-blink.sh header for why.
#
# speaker-test, not aplay+python3: no python3 target package to generate PCM.

for i in 1 2 3; do
  if command -v speaker-test >/dev/null 2>&1; then
    speaker-test -t sine -f 1000 -l 1 -c 2 -d default >/dev/null 2>&1
  else
    exit 0
  fi
  sleep 0.2
done
