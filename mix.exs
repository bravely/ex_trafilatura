defmodule ExTrafilatura.MixProject do
  use Mix.Project

  def project do
    [
      app: :ex_trafilatura,
      version: "0.1.0",
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      usage_rules: usage_rules()
    ]
  end

  # What `mix usage_rules.sync` writes into AGENTS.md. The config is the source
  # of truth: a package listed here is inlined on sync, and one removed from
  # here is deleted from the file on the next sync.
  #
  # Inlined rather than linked (`link: :markdown`) because links would point
  # into `deps/`, which is gitignored and — since usage_rules is `only: [:dev]`
  # — absent entirely on the 1.15 CI leg. The three rule sets total ~120 lines,
  # so inlining costs little and keeps AGENTS.md readable with no deps present.
  defp usage_rules do
    [
      file: "AGENTS.md",
      # One entry, three blocks. The `:elixir` and `:otp` built-ins are shipped
      # as sub-rules *of* the usage_rules package, so `:usage_rules` expands to
      # its main rules plus both — each exactly once, ~135 generated lines.
      #
      # Do not "improve" this to `[:elixir, :otp, :usage_rules]`. Every entry
      # naming a sub-rule also drags in that package's main rules, so listing
      # them separately emits the main block three times and elixir/otp twice.
      usage_rules: [:usage_rules]
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:rustler, "~> 0.38.0", runtime: false},

      # Validates `ExTrafilatura.extract/2`'s option keyword list against the
      # schema in `ExTrafilatura.Options`. A runtime dependency, and part of the
      # public contract: an unknown key or an invalid value reaches the caller
      # as a `NimbleOptions.ValidationError` (#11, reversed).
      {:nimble_options, "~> 1.0"},

      # Agent tooling: syncs dependency usage rules into AGENTS.md and provides
      # `mix usage_rules.docs` / `.search_docs`. See usage_rules/0 above.
      #
      # `only: [:dev]` is load-bearing, not tidiness. usage_rules declares
      # `elixir: "~> 1.18"` while this project's floor is 1.15 (ADR-0007 §9),
      # so it must never be compiled on the floor leg. It isn't: CI runs
      # deps.get, `format --check-formatted`, then `mix test`, and none of them
      # compile a dev-only dep under MIX_ENV=test. Verified by running that
      # sequence locally on Elixir 1.15.8 — all three pass. (On OTP 26 rather
      # than CI's OTP 24; the constraint under test is an Elixir-version check
      # in Mix, which OTP does not affect.) A bare `mix compile` in dev on 1.15
      # *would* pull this in; CI does not run one.
      #
      # No `runtime: false`: it would propagate to req/finch, which
      # `mix usage_rules.search_docs` needs started to make HTTP calls.
      {:usage_rules, "~> 1.2", only: [:dev]}
    ]
  end
end
