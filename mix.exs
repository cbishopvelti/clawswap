defmodule Clawswap.MixProject do
  use Mix.Project

  def project do
    [
      app: :clawswap,
      version: "0.2.0",
      # Hologram needs 1.19; the rest of clawswap is plain OTP.
      elixir: "~> 1.19",
      elixirc_paths: elixirc_paths(Mix.env()),
      compilers: Mix.compilers() ++ [:hologram],
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [mod: {Clawswap.Application, []}, extra_applications: [:logger, :inets, :ssl, :public_key]]
  end

  defp elixirc_paths(:test), do: ["app", "lib", "test/support"]
  defp elixirc_paths(_), do: ["app", "lib"]

  defp deps do
    [
      {:bandit, "~> 1.5"},
      {:hologram, "~> 0.12"},
      {:jason, "~> 1.4"},
      {:phoenix, "~> 1.7"},
      {:yaml_elixir, "~> 2.11"}
    ]
  end
end
