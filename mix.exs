defmodule NervesSystemSheng.MixProject do
  use Mix.Project

  def project do
    [
      app: :nerves_system_sheng,
      version: "1.34.1",
      elixir: "~> 1.14",
      compilers: Mix.compilers() ++ [:nerves_package],
      nerves_package: nerves_package(),
      description: "Nerves System for Xiaomi Pad 6S Pro",
      deps: deps()
    ]
  end

  def application do
    []
  end

  defp nerves_package do
    [
      type: :system,
      build_runner_opts: build_runner_opts(),
      build_runner_config: build_runner_config(),
      platform: Nerves.System.BR,
      platform_config: [
        defconfig: "boards/xiaomi_sheng/nerves.defconfig"
      ],
      checksum: package_files()
    ]
  end

  defp package_files do
    [
      "board",
      "boards",
      "patches",
      "Config.in",
      "external.desc",
      "external.mk",
      "VERSION"
    ]
  end

  defp build_runner_opts do
    [make_args: ["source", "all"]]
  end

  defp build_runner_config do
    [docker: {"support/docker/nerves_system_br/Dockerfile", "nerves_system_sheng:local"}]
  end

  defp deps do
    [
      {:nerves, "~> 1.14.3", runtime: false},
      {:nerves_system_br, "~> 1.34.0", runtime: false},
      {:nerves_toolchain_aarch64_nerves_linux_gnu, "~> 15.3.0", runtime: false}
    ]
  end
end
