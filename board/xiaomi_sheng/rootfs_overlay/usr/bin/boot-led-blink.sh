#!/bin/sh
# POSIX sh, not bash: this rootfs has no BR2_PACKAGE_BASH, only BusyBox's
# ash at /bin/sh - a #!/bin/bash shebang here fails at exec() with no
# interpreter found, silently (erlinit logs and moves on to the next -c
# command / the release, it doesn't abort), so this script was a no-op on
# real hardware despite looking correct in isolation.
# EARLIEST boot signal: blink LED immediately when erlinit starts
# If you see LED blinks, userspace + erlinit are alive
# This runs BEFORE anything else

LED_FILE=""

# Try multiple LED locations
for led_path in /sys/class/leds/*/brightness /sys/devices/platform/*/leds/*/brightness; do
  if [ -f "$led_path" ] 2>/dev/null; then
    LED_FILE="$led_path"
    break
  fi
done

# If no LED found, try writing to a generic path that might work
if [ -z "$LED_FILE" ]; then
  # Try to find ANY led device
  LED_FILE=$(find /sys/class/leds -name brightness 2>/dev/null | head -1)
fi

# Blink if we found an LED
if [ -f "$LED_FILE" ]; then
  # 10 rapid blinks = "I AM ALIVE"
  # {1..10} is bash brace expansion, not POSIX - ash doesn't expand it at
  # all (would literally iterate the single string "{1..10}" once).
  for i in 1 2 3 4 5 6 7 8 9 10; do
    echo 1 > "$LED_FILE" 2>/dev/null
    sleep 0.1
    echo 0 > "$LED_FILE" 2>/dev/null
    sleep 0.1
  done
  # Leave LED on for 1 second
  echo 1 > "$LED_FILE" 2>/dev/null
  sleep 1
  echo 0 > "$LED_FILE" 2>/dev/null
fi
