# GitHub Stack: Native fwup A/B on Qualcomm ABL

This repository uses `gh stack` to organize firmware-update improvements into reviewable, independently-shippable phases.

## Stack Structure

```
phase-3/hygiene-items (can merge independently)
  ↓
phase-2/ops-fw-integration (depends on phase-1)
  ↓
phase-1/fwup-atomicity (depends on phase-0)
  ↓
phase-0/gpt-retry-count (base, depends on main)
  ↓
main
```

---

## Phase 0: GPT Retry-Count / Success-Bit Gap

**Branch**: `phase-0/gpt-retry-count`

**Scope**: Fix the bootloader-level state-machine gap where ABL's GPT retry-count nibble is never replenished and the success-bit is never set, risking device strand-in-fastboot after N failed boots, even without any OTA update.

**Work items**:
1. Empirical test: reboot device ~10-15 times, monitor GPT attribute byte bit-3-5 (retry-count nibble, mask `0x38`) to determine if ABL decrements on every boot or only on retry-after-failure boots. Document findings.
2. Add `NervesSheng.ABUpdate.mark_boot_successful/0` function that raw-`pwrite`s the currently-active slot's GPT attribute byte, setting the SUCCESSFUL bit (`0x40`) and resetting retry-count to max (`0x38`).
3. Call `mark_boot_successful/0` from `Platform.boot!/0` at an appropriate trigger point (exact placement TBD based on empirical test results).
4. Unit-level verification: read-back the written attribute byte to confirm the changes stuck.

**Files to touch**:
- `nerves_sheng_platform/lib/nerves_sheng/platform.ex` — add call to `mark_boot_successful/0` in `boot!/0`
- `nerves_sheng_platform/lib/nerves_sheng/ab_update.ex` — add `mark_boot_successful/0` function and helper logic

**Risk**: Low. Direct `:file.pread`/`:file.pwrite` against live GPT at known offsets, same pattern already proven by `revert!/1`. Defensive-only fix (no OTA path involved).

---

## Phase 1: fwup Atomicity Fix

**Branch**: `phase-1/fwup-atomicity`

**Base**: `phase-0/gpt-retry-count`

**Scope**: Fold the UFS boot-LUN flip into the same fwup transaction as the GPT write, eliminating the process-level gap (two separate `System.cmd` calls) where power-loss or Elixir crash leaves the two writes disagreeing.

**Work items**:
1. `nerves_system_sheng/fwup.conf`: add `execute("ufs_boot_lun write a")` (or `b`) to `on-finish` of both `upgrade.a`/`upgrade.b` tasks, **after** the GPT `raw_write`.
2. `nerves_sheng_platform/lib/nerves_sheng/ab_update.ex`:
   - `run_fwup/3`: add `"--unsafe"` to `System.cmd` args (required for `execute()`)
   - `apply/1`: remove the separate `set_boot_lun` step (return arity changes)
   - `ssh_finish/1`: simplify to `mark_pending(target); Nerves.Runtime.reboot()` (LUN flip now happens inside fwup)
   - **Keep** `set_boot_lun/1` itself — still needed by `revert!/1`
3. `config/target.exs`: add `fwup_extra_options: ["--unsafe"]` to `config :ssh_subsystem_fwup` block (so `mix upload` passes `--unsafe` to fwup).

**Verification**:
- Manual `NervesSheng.ABUpdate.apply/1` against a spare/recoverable slot with fastboot cable in reach
- Confirm a deliberately-broken `execute()` command makes `fwup -a` exit non-zero
- Test auto-reboot path (`ssh_precheck`/`ssh_finish`) only after manual verification passes

**Risk**: Medium. `execute()`/`--unsafe` have never been exercised on this device's specific fwup build before. Kernel panic or watchdog timeout during manual test is recoverable via fastboot if needed.

---

## Phase 2: ops.fw / startup_guard_enabled

**Branch**: `phase-2/ops-fw-integration`

**Base**: `phase-1/fwup-atomicity`

**Scope**: Ship the idiomatic Nerves firmware-validation/revert mechanism (`ops.fw` + `Nerves.Runtime.FwupOps`) so `Nerves.Runtime.revert/1`, `validate_firmware/1`, `firmware_validation_status/0`, `firmware_slots/1` work natively, and enable `startup_guard_enabled: true` to activate the official "assisted firmware validation" safety net.

**Work items**:
1. New `nerves_system_sheng/fwup-ops.conf` with tasks: `status`, `revert`, `validate`, `prevent-revert`. Wire build step to create `/usr/share/fwup/ops.fw` inside the rootfs.
2. New minimal C helper `package/gpt_active_slot/src/gpt_active_slot.c` — reads GPT attribute byte (offsets 9910/13750, bit-2) and prints `a`/`b`, exit 1 on ambiguous state. Kept separate from `ufs_boot_lun.c` to preserve scoping.
3. `fwup-ops.conf`'s tasks use `execute("gpt_active_slot ...")` and `execute("ufs_boot_lun ...")` to read and manipulate state.
4. `config/target.exs`: `config :nerves_runtime, startup_guard_enabled: true` — activates the official "assisted firmware validation and automatic revert" behavior.
5. **Verify before wiring up**: exact fwup config function that emits `WN`-framed messages under `--framing` (for `FwupOps.status/0` to parse).

**Verification**:
- Test `Nerves.Runtime.FwupOps.status/0` parsing of `fwup-ops.conf`'s `status` task output
- Test `Nerves.Runtime.revert/1` end-to-end on a spare slot
- Confirm `startup_guard_enabled: true` doesn't break boot flow

**Risk**: Medium-High. `fwup-ops.conf` syntax is new to this project; `--framing` protocol details must be verified against fwup source before trusting.

---

## Phase 3: Hygiene Items

**Branch**: `phase-3/hygiene-items`

**Base**: `phase-2/ops-fw-integration` (or can be merged independently to main)

**Scope**: Low-risk, foundational fixes that unblock or improve robustness independent of the fwup/OTA mechanics.

**Work items**:

1. **Shoehorn**: Add `{:shoehorn, "~> 0.9"}` to `mix.exs` deps. Configure `init: [:nerves_runtime, :nerves_pack]` in `config/target.exs` so an unhandled crash in `nerves_sheng`'s supervision tree (e.g., `DataMount.mount/0`'s `tune2fs`/`e2fsck`/`resize2fs` shell-outs) doesn't take the whole VM down, keeping SSH/networking alive for remote recovery.

2. **Watchdog module**: Add `qcom_wdt` (or confirmed name from `modules.dep`) to `board/xiaomi_sheng/rootfs_overlay/usr/bin/load-hw-modules.sh` so `/dev/watchdog` exists on boot and `nerves_heart` can pet real hardware.

3. **boardid.config**: Either write `board/xiaomi_sheng/rootfs_overlay/etc/boardid.config` pointing at the actual serial source, or disable `BR2_PACKAGE_BOARDID` in `boards/xiaomi_sheng/nerves.defconfig` if it's dead weight. (Needs exact dmesg error from user first to confirm root cause.)

4. **fwup.conf metadata**: Add `meta-product`/`meta-version`/`meta-author`/etc. blocks and `NERVES_FW_APPLICATION_PART0_*` partition defines to `nerves_system_sheng/fwup.conf` so NervesMOTD stops showing "not available" for firmware metadata.

**Verification**:
- `/dev/watchdog` appears on target (`ls /dev/watchdog*`)
- Shoehorn survives app crash in IEx without dropping SSH
- MOTD shows firmware metadata instead of "not available"

**Risk**: Low. All items are additive or config-only, no behavioral changes to existing code paths.

---

## Workflow

1. **Check current stack**: `gh stack view`
2. **Move between branches**: `git checkout <branch-name>` (or use `gh stack switch <number>`)
3. **Make changes on current branch**: edit, commit normally with `git commit`
4. **Push and create PRs**: `gh stack submit` (when stack is ready for review/merge)
5. **Keep in sync with main**: `gh stack sync` (rebases stack if main has new commits)

---

## Reference

- Full implementation plan: `/Users/sushy/.claude/plans/please-investigate-fwup-and-resilient-popcorn.md`
- gh stack docs: `gh stack --help`
