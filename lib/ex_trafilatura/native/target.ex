defmodule ExTrafilatura.Native.Target do
  @moduledoc false
  # Everything `ExTrafilatura.Native` needs to know at compile time about *which*
  # machine it is being compiled for: the eight targets we publish artifacts for,
  # whether this build is the opt-in source build, and — when neither applies —
  # the message the user gets instead.
  #
  # It exists as its own module rather than inline in `ExTrafilatura.Native`
  # because that module's body runs once, at compile time, inside a macro that
  # either downloads a binary or shells out to cargo. None of it is reachable
  # from a test. These functions are pure, and the message in particular is a
  # promise ADR-0004 §11 makes to a stranger on a platform we do not have.

  # ADR-0004 §3, in the ADR's own order: rustler_precompiled's default ten minus
  # `riscv64gc-unknown-linux-gnu` and `arm-unknown-linux-gnueabihf`, which are
  # the two most likely to break a cross-build and serve the two constituencies
  # a server-side HTML extraction library plausibly does not have.
  @targets [
    # the default server
    "x86_64-unknown-linux-gnu",
    # Graviton, Ampere, ARM cloud
    "aarch64-unknown-linux-gnu",
    # Alpine containers
    "x86_64-unknown-linux-musl",
    # Alpine on Apple Silicon Docker
    "aarch64-unknown-linux-musl",
    # dev machines, 2020 onward
    "aarch64-apple-darwin",
    # dev machines, pre-2020
    "x86_64-apple-darwin",
    # official OTP Windows builds
    "x86_64-pc-windows-msvc",
    # MSYS2 Erlang
    "x86_64-pc-windows-gnu"
  ]

  # One NIF version (ADR-0004 §4). NIF versions are backward compatible, so a
  # 2.15 artifact loads on any ERTS reporting 2.15 or higher, and the one ERTS
  # feature this binding depends on — dirty CPU schedulers — arrived in 2.7.
  @nif_versions ["2.15"]

  @build_env "EX_TRAFILATURA_BUILD"

  def supported, do: @targets

  def nif_versions, do: @nif_versions

  def build_env, do: @build_env

  def supported?(target), do: target in @targets

  # `false` unless asked, which is the whole of ADR-0004 §2. The argument is not
  # that source builds are slow — it is where the failure lands. A developer on
  # an unlisted target with Rust installed would get a silent source build here
  # and the same hard failure later, inside the toolchain-free deploy container.
  #
  # `sources` is every way a source build can be asked for, already read by the
  # caller so this stays pure. It is a list rather than one env var because
  # passing `force_build:` explicitly to `use RustlerPrecompiled` makes *us* the
  # authority on all of them: its own resolution of `force_build_all` and of
  # `config :rustler_precompiled, :force_build` sits behind a `Keyword.put_new/3`
  # that our value has already filled. Miss one here and it is simply dead, and
  # ADR-0004 §2 promises `RUSTLER_PRECOMPILED_FORCE_BUILD_ALL=1` "works globally".
  #
  # Pre-releases are the exception that needs no asking, and enforcing that is
  # ours rather than inherited: ADR-0004 §2 says any `0.1.0-rc.N` is a source
  # build for everyone, but `RustlerPrecompiled.Config` only treats
  # `"dev" in Version.parse!/1.pre` as a pre-release, so an `-rc.N` would go
  # looking for an artifact.
  def force_build?(version, sources \\ []) do
    pre_release?(version) or Enum.any?(sources, fn {_source, value} -> requested?(value) end)
  end

  defp requested?(true), do: true
  defp requested?(value), do: value in ["1", "true"]

  defp pre_release?(version), do: Version.parse!(version).pre != []

  # The pre-flight ADR-0004 §11 leaves open. Pinned against rustler_precompiled
  # 0.9.0's source: on an unlisted target `RustlerPrecompiled.target/3` returns
  # `{:error, "precompiled NIF is not available for this target: ..."}` listing
  # the available targets, and the `__using__` macro raises it verbatim. That
  # names two of the three things §11 requires and **no force-build mechanism at
  # all** — not `EX_TRAFILATURA_BUILD`, not rustler_precompiled's own config key.
  # So we get there first.
  def check!(resolved \\ RustlerPrecompiled.target()) do
    target = triple(resolved, system_architecture())

    if supported?(target) do
      :ok
    else
      raise unsupported_message(target)
    end
  end

  # The normalized triple, which is what the user needs to see: `:erlang`'s own
  # architecture string is `x86_64-pc-linux-gnu` where the table below says
  # `x86_64-unknown-linux-gnu`, and a message whose target matches no row it
  # prints is worse than useless. rustler_precompiled has already done that
  # normalization by the time we see either arm, so we take its answer.
  def triple({:ok, "nif-" <> nif_version_and_triple}, _fallback) do
    [_nif_version, triple] = String.split(nif_version_and_triple, "-", parts: 2)
    triple
  end

  def triple({:error, message}, fallback) do
    case Regex.run(~r/this target: "([^"]+)"/, message) do
      [_, triple] -> triple
      nil -> fallback
    end
  end

  defp system_architecture, do: List.to_string(:erlang.system_info(:system_architecture))

  def unsupported_message(target) do
    """
    ExTrafilatura publishes no precompiled NIF for this target:

        #{target}

    Precompiled artifacts exist for these #{length(@targets)} targets:

    #{Enum.map_join(@targets, "\n", &"    - #{&1}")}

    To build from source instead, add Rustler beside ExTrafilatura in your own
    mix.exs. Rustler is an optional dependency of this package, so a precompiled
    user never resolves it and it is not in your tree yet:

        {:rustler, ">= 0.0.0", optional: true}

    Then set #{@build_env}=1, which needs a Rust toolchain (https://rustup.rs):

        $ #{@build_env}=1 mix deps.get
        $ #{@build_env}=1 mix deps.compile ex_trafilatura

    The source build is opt-in rather than automatic on purpose. An automatic
    fallback would not remove this failure — it would defer it from your machine
    to a toolchain-free deploy container and strip this message off it
    (ADR-0004 §2).
    """
  end
end
