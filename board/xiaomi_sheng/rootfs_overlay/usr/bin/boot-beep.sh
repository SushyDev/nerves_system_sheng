#!/bin/sh
# POSIX sh, not bash: this rootfs has no BR2_PACKAGE_BASH, only BusyBox's
# ash at /bin/sh - a #!/bin/bash shebang here fails at exec() with no
# interpreter found, silently (erlinit logs and moves on to the next -c
# command / the release, it doesn't abort), so this script was a no-op on
# real hardware despite looking correct in isolation.
#
# Earliest boot confirmation: triple beep via ALSA speaker-test
# Runs before Erlang VM starts (from erlinit.config), so if you hear it,
# the device kernel+erlinit are alive even if everything else fails.
#
# speaker-test used directly, not aplay+python3: python3 is only a
# build-host tool (see support/docker/nerves_system_br/Dockerfile), it was
# never added as a target package (no BR2_PACKAGE_PYTHON3 in
# nerves.defconfig) - piping python3-generated PCM into aplay always failed
# at the missing python3 binary. speaker-test is a self-contained tone
# generator that needs no external PCM source and is already enabled via
# BR2_PACKAGE_ALSA_UTILS_SPEAKER_TEST specifically for this script.

for i in 1 2 3; do
  if command -v speaker-test >/dev/null 2>&1; then
    speaker-test -t sine -f 1000 -l 1 -c 2 -d default >/dev/null 2>&1
  else
    # No audio tools, exit silently (still proves kernel is alive)
    exit 0
  fi
  sleep 0.2
done
