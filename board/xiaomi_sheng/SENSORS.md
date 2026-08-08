# Sensor daemon stack — research notes (not yet implemented)

Kernel-side support is already correct and needs no changes:
- `CONFIG_QCOM_FASTRPC=m` — provides `/dev/fastrpc-adsp` (sm8550.config:2188)
- `CONFIG_KEYBOARD_GPIO=y` — the "hall effect" lid sensor is **not an IIO
  device**, it's a `gpio-keys` input device reporting `SW_LID` (confirmed via
  the reference NixOS module below, which greps for `dev.name == "gpio-keys"`
  and `SW_LID` in its capabilities). No new kernel driver is needed, assuming
  the in-tree DTS wires the GPIO correctly (not independently verified here).

What's missing is entirely userspace: the ADSP RPC daemon stack that talks to
the Sensor Subsystem (SSC) firmware over `/dev/fastrpc-adsp`. None of this
exists anywhere in `./references` as a prebuilt binary — but
`references/Xiaomi-pad-6s-pro-Linux/nixos/hardware/xiaomi-sheng/sensors/`
contains real Nix package derivations with exact upstream sources, extracted
here so a future session doesn't have to re-derive them:

| Component | Purpose | Upstream source | Buildroot deps already available |
|---|---|---|---|
| `fastrpc` (adsprpcd) | Root ADSP RPC daemon (`adsprpcd`, `cdsprpcd`, `sdsprpcd`, `gdsprpcd`) | `github.com/qualcomm/fastrpc` tag `v1.0.2` (official Qualcomm OSS repo) | `BR2_PACKAGE_LIBYAML` exists |
| `qrtr` | Qualcomm IPC router library, needed by pd-mapper | `github.com/linux-msm/qrtr` commit `ae881086dfd29f828dcadb56e4b32a09fdc5c202` (meson build) | meson/ninja already used elsewhere in Buildroot |
| `pd-mapper` | Serves firmware requests over QRTR to ADSP | `github.com/linux-msm/pd-mapper` commit `5ecd2fe926aca7abfe40724177f63b942cff3947` (plain Makefile, `prefix=`/`servicedir=`/`CC=` make vars) | depends on `qrtr` above |
| `libssc` | Client library + `ssccli` tool to query SSC-backed sensors (accel/gyro/light/proximity/compass) | **Vendored in full at `references/Xiaomi-pad-6s-pro-Linux/nixos/vendor/libssc`** (meson build, AGPL-3.0-or-later per file headers) | `BR2_PACKAGE_LIBQMI`, `BR2_PACKAGE_LIBMBIM`, `BR2_PACKAGE_PROTOBUF_C` all exist |
| `sheng-sensors-file` | Device-specific sensor registry JSON, installed to `/usr/share/qcom/sm8550/Xiaomi/sheng` | `github.com/alghiffaryfa19/sheng-sensors-file` (files only, no build) | n/a |
| `xiaomi_devauth` | Also gates sensor auth, not just the keyboard (`adsprpcd-sensorspd.service` depends on it in the reference) | Already vendored — see `rootfs_overlay/usr/bin/xiaomi_devauth` and `lib/nerves_sheng/application.ex` | n/a |

Two patch files are referenced by the Nix derivations but not present in
`./references` and were NOT fetched in this pass (would need network access
to the actual GitHub repos to diff against): `fastrpc-rflags.patch` (applied
to `qualcomm/fastrpc`) and `wait_for_qmi_service.patch` (applied to
`vendor/libssc`). Check what they do before packaging - they may encode
required behavior, not just NixOS-specific plumbing.

**Why this wasn't packaged in this pass**: writing 4 new Buildroot packages
(2 autotools/plain-Makefile, 2 meson) with a real dependency chain
(fastrpc -> libyaml, pd-mapper -> qrtr, libssc -> glib+protobuf-c+libqmi+libmbim)
is substantial, untested work, and the existing Nerves build pipeline hit an
unrelated pre-existing blocker in this session (`nerves_system_br`'s
`ERTS_DIR` bootstrap fails against the currently cached system artifact),
so none of it could be test-built anyway. Packaging blind, without being able
to verify a single build, risks leaving broken `.mk` files behind - the NixOS
service wiring above (`adsprpcd` -> `pd-mapper` -> `sheng-devauth` ->
`adsprpcd-sensorspd`, in that dependency order, with `ADSP_LIBRARY_PATH`
pointing at the sensors-file registry) is the ordering to replicate as OTP
supervision once the binaries exist, same pattern as `xiaomi_devauth` in
`lib/nerves_sheng/application.ex`.

**`iio-sensor-proxy`**: confirmed absent from Buildroot 2026.05.1 entirely
(no `BR2_PACKAGE_IIO_SENSOR_PROXY`). It's also a poor fit for Nerves anyway -
it's a desktop-oriented D-Bus daemon (`net.hadess.SensorProxy`) built for
GNOME/Settings orientation lock, not something a headless embedded target
needs. Once `libssc`'s `ssccli`/library exists, the idiomatic Nerves path is
reading sensor values directly from Elixir (e.g. via `Port`/NIF against
`libssc`, or shelling out to `ssccli`), not running a GNOME helper daemon.
