#!/bin/sh
# POSIX sh, not bash: no BR2_PACKAGE_BASH here, only BusyBox ash - #!/bin/bash
# fails exec() silently (erlinit just moves on), so this was a silent no-op.

LED_FILE=""

for led_path in /sys/class/leds/*/brightness /sys/devices/platform/*/leds/*/brightness; do
  if [ -f "$led_path" ] 2>/dev/null; then
    LED_FILE="$led_path"
    break
  fi
done

if [ -z "$LED_FILE" ]; then
  LED_FILE=$(find /sys/class/leds -name brightness 2>/dev/null | head -1)
fi

if [ -f "$LED_FILE" ]; then
  # {1..10} is bash brace expansion, not POSIX - ash would iterate it once
  # as a literal string instead of 10 times.
  for i in 1 2 3 4 5 6 7 8 9 10; do
    echo 1 > "$LED_FILE" 2>/dev/null
    sleep 0.1
    echo 0 > "$LED_FILE" 2>/dev/null
    sleep 0.1
  done
  echo 1 > "$LED_FILE" 2>/dev/null
  sleep 1
  echo 0 > "$LED_FILE" 2>/dev/null
fi
