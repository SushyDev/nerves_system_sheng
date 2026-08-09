defmodule Nerves.System.Sheng.Mixfile do
  use Mix.Project

  @version Path.join(__DIR__, "VERSION")
           |> File.read!()
           |> String.trim()

  def project do
    [
      app: :nerves_system_sheng,
      version: @version,
      elixir: "~> 1.14",
      compilers: Mix.compilers() ++ [:nerves_package],
      nerves_package: nerves_package(),
      description: description(),
      package: package(),
      deps: deps()
    ]
  end

  def application do
    []
  end

  defp description do
    """
    Nerves System Sheng - Buildroot based system for the Xiaomi Pad 6S Pro (sheng)
    """
  end

  defp package do
    [
      licenses: ["Apache-2.0", "GPL-2.0-or-later"],
      links: %{
        "GitHub" => "https://github.com/SushyDev/nerves_system_sheng",
        "REUSE Compliance" =>
          "https://api.reuse.software/info/github.com/SushyDev/nerves_system_sheng"
      }
    ]
  end

  defp nerves_package do
    [
      type: :system,
      build_runner_opts: build_runner_opts(),
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
      "package",
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

  defp deps do
    [
      {:nerves, "~> 1.14.3", runtime: false},
      {:nerves_system_br, "~> 1.34.0", runtime: false},
      {:nerves_toolchain_aarch64_nerves_linux_gnu, "~> 15.3.0", runtime: false}
    ]
  end
end
