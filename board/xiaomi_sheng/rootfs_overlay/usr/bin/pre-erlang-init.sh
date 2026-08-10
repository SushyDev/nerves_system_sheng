#!/bin/sh
# erlinit -c: synchronous, blocks Erlang - keep fast, no hang risk here.

# nerves_heart needs /dev/watchdog0 before Elixir starts.
modprobe qcom_wdt 2>/dev/null

# ABL decrements GPT retry-count every boot regardless of Erlang - reset it
# here so a single Erlang hang can't burn a retry (see nerves_sheng_edl_brick_2026_08_11.md).
ab_ops validate 2>/dev/null
