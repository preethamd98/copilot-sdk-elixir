defmodule CopilotSdk.MixProject do
  use Mix.Project

  def project do
    [
      app: :copilot_sdk,
      version: "0.1.0",
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps(),
      aliases: aliases(),
      dialyzer: [plt_file: {:no_warn, "priv/plts/project.plt"}]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  def application do
    [
      extra_applications: [:logger],
      mod: {CopilotSdk.Application, []}
    ]
  end

  defp deps do
    [
      {:jason, "~> 1.4", path: "/tmp/elixir_deps/jason-1.4.4", override: true},
      {:gen_stage, "~> 1.2", path: "/tmp/elixir_deps/gen_stage-1.3.2"}
    ]
  end

  defp aliases do
    [
      quality: ["compile --warnings-as-errors", "format --check-formatted", "credo --strict", "dialyzer"]
    ]
  end
end
