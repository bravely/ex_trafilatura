defmodule SpikeNif.MixProject do
  use Mix.Project

  # THROWAWAY SPIKE — see README.md. Not part of the ExTrafilatura build.

  def project do
    [
      app: :spike_nif,
      version: "0.0.0",
      elixir: "~> 1.20",
      deps: deps()
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end

  defp deps do
    [{:rustler, "~> 0.38.0", runtime: false}]
  end
end
