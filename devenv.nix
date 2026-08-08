{ pkgs, lib, config, ... }:

{
  env.NERVES_SYSTEM = ./.;
  env.MIX_ENV = "prod";

  languages.erlang.enable = true;
  languages.elixir.enable = true;

  packages = [];

  tasks = {
    "firmware:build" = {
      description = "Build Nerves firmware for Xiaomi Pad 6S Pro";
      exec = ''
        mix local.hex --if-missing
        mix local.rebar --if-missing
        mix deps.get
        mix firmware
      '';
    };

    "firmware:burn" = {
      description = "Flash firmware to device";
      exec = "echo 'Flash with: fastboot flash boot_b _build/prod/generic_arm64/nerves_system_sheng_defconfig/boot.img'";
    };
  };
}
