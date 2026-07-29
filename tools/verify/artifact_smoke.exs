defmodule ArtifactSmoke do
  @moduledoc false
  # ADR-0004 §10's addition to the release gate: before an artifact is attached
  # to a release, load *that artifact* and call `crate_version/0` on it.
  #
  # Everything else in the gate proves the source tree is correct and says
  # nothing about the eight binaries built from it. What this catches — bad
  # build config, a missing symbol, a `cdylib` that will not load, a name the
  # runtime will never ask for — is overwhelmingly target-independent, which is
  # why seven of eight is a good sample rather than a hole.
  #
  # It runs in two halves around a `mix compile`, because the artifact has to be
  # in place *before* the compile that consumes it:
  #
  #     export RUSTLER_PRECOMPILED_GLOBAL_CACHE_PATH=$PWD/_build/artifact-smoke
  #     elixir -r tools/verify/artifact_smoke.exs -e 'ArtifactSmoke.stage!("<artifact>")'
  #     mix deps.get && mix compile --force
  #     mix run -r tools/verify/artifact_smoke.exs -e 'ArtifactSmoke.verify!("<artifact>")'
  #
  # `stage!/1` puts the artifact where rustler_precompiled looks before it
  # reaches for the network, and writes a checksum file naming that artifact and
  # its bytes. Those two together are what make the middle step a real test: a
  # cache miss falls through to a download, and a download of anything else —
  # a differently named asset, an older upload under the same name — fails the
  # integrity check against the file we just wrote. The only way `mix compile`
  # succeeds is if this artifact carries exactly the name and exactly the bytes
  # the runtime will ask for at a user's compile time (ADR-0004 §6).

  # `build.rs` reads this same file into the NIF as `TRAFILATURA_VERSION`, so
  # comparing against it asks "did this artifact come out of the tree we are
  # releasing?" rather than "does it match a constant someone remembered to
  # bump" (ADR-0004 §1).
  @vendored_manifest "native/ex_trafilatura/vendor/trafilatura/Cargo.toml"

  @nif_module ExTrafilatura.Native

  # Where rustler_precompiled reads and writes it: the project root, named for
  # the NIF module. ADR-0004 §7's committed file has the same name, which is why
  # `stage!/1` says out loud that it has just overwritten it.
  @checksum_file "checksum-#{@nif_module}.exs"

  @cache_env "RUSTLER_PRECOMPILED_GLOBAL_CACHE_PATH"

  # `stage!/1` runs under plain `elixir`, before the compile and with no project
  # loaded, so none of these exist yet. Everything that reaches for them is
  # reached only from `verify!/1`, which runs under `mix run` afterwards.
  @compile {:no_warn_undefined,
            [ExTrafilatura.Native, ExTrafilatura.Native.Target, RustlerPrecompiled]}

  @doc """
  Put `artifact` where the compile that follows will find it, and pin its bytes.
  """
  def stage!(artifact) do
    artifact = Path.expand(artifact)

    unless File.regular?(artifact) do
      abort("no artifact at #{artifact}")
    end

    cache = cache_dir!()
    File.mkdir_p!(cache)
    File.cp!(artifact, Path.join(cache, Path.basename(artifact)))
    File.write!(@checksum_file, checksum_file_body(artifact))

    say("staged #{Path.basename(artifact)} in #{cache}")

    say("""
    wrote #{@checksum_file}, pinning that one artifact.

        This is a throwaway and is NOT ADR-0004 §7's committed checksum file,
        which is generated at release time by `mix rustler_precompiled.download`
        against the attached assets. Restore yours with:

            git checkout -- #{@checksum_file}
    """)
  end

  @doc """
  Assert that the compile that just ran loaded `artifact`, and that it answers.
  """
  def verify!(artifact) do
    artifact = Path.expand(artifact)
    name = Path.basename(artifact)

    refute_source_build!()
    assert_expected_name!(name)
    refute_unexpected_names!(artifact)
    assert_marker!()

    say("#{name} loads and answers — smoke test passed")
  end

  # A source build would pass every check below while proving nothing about the
  # artifact, so this is not a formality: `EX_TRAFILATURA_BUILD=1` left over in
  # a maintainer's shell is exactly how a smoke test goes green on a binary it
  # never touched.
  #
  # All four sources, because `ExTrafilatura.Native` passes all four: two of them
  # are `config :rustler_precompiled` keys rather than environment variables, and
  # a source build asked for that way is exactly as invisible here. Read at run
  # time rather than through `Application.compile_env/2` — same config, and this
  # file is loaded by `mix run` rather than compiled into the project.
  defp refute_source_build!() do
    alias ExTrafilatura.Native.Target

    sources = [
      ex_trafilatura_build: System.get_env(Target.build_env()),
      force_build_all_env: System.get_env("RUSTLER_PRECOMPILED_FORCE_BUILD_ALL"),
      force_build_all: Application.get_env(:rustler_precompiled, :force_build_all),
      force_build: Application.get_env(:rustler_precompiled, :force_build, [])[:ex_trafilatura]
    ]

    if Target.force_build?(version(), sources) do
      abort("""
      this build was a source build, so there is no artifact under test.

          One of these asked for it:

          - #{Target.build_env()}=#{inspect(sources[:ex_trafilatura_build])}
          - RUSTLER_PRECOMPILED_FORCE_BUILD_ALL=#{inspect(sources[:force_build_all_env])}
          - config :rustler_precompiled, force_build_all: #{inspect(sources[:force_build_all])}
          - config :rustler_precompiled, force_build: [ex_trafilatura: #{inspect(sources[:force_build])}]

          — or the version is a pre-release, #{version()}, which force-builds for
          everyone regardless (ADR-0004 §2) and so has no artifacts to smoke.
      """)
    end
  end

  defp assert_expected_name!(name) do
    expected = expected_artifact_names()

    unless name in expected do
      abort("""
      #{name} is not a name the runtime will ever ask for.

          rustler_precompiled resolves the download URL at the *user's* compile
          time (ADR-0004 §8), so a name only this workflow agrees with is an
          asset nobody can fetch. It expects one of:

          #{Enum.map_join(expected, "\n          ", &"- #{&1}")}
      """)
    end

    say("#{name} is a name the runtime asks for")
  end

  # Every other artifact sitting beside the one under test, which in the release
  # workflow is all eight. This is the only thing that looks at
  # `x86_64-pc-windows-gnu`'s name at all: it has no runner and so no smoke leg
  # of its own, and a misnamed asset there is permanent under ADR-0004 §8 —
  # nobody can fetch it and it cannot be re-uploaded. Run by hand against a
  # single downloaded artifact this is simply quiet.
  defp refute_unexpected_names!(artifact) do
    expected = expected_artifact_names()

    built =
      artifact
      |> Path.dirname()
      |> Path.join("*.tar.gz")
      |> Path.wildcard()
      |> Enum.map(&Path.basename/1)

    case unexpected_names(built, expected) do
      [] ->
        say("the #{length(built)} artifact(s) beside it are all names the runtime asks for")

      unexpected ->
        abort("""
        #{length(unexpected)} built artifact(s) carry a name the runtime will never ask for:

        #{Enum.map_join(unexpected, "\n", &"    - #{&1}")}
        """)
    end
  end

  @doc """
  Which of `built` are names the runtime will never ask for.

  One-directional on purpose: a name that was *not* built is not this function's
  question, because a maintainer running the smoke test by hand has one artifact
  in the directory rather than eight. The release workflow counts to eight
  separately, where all eight are in one place.
  """
  def unexpected_names(built, expected), do: built -- expected

  defp assert_marker!() do
    expected = expected_marker()
    reported = @nif_module.crate_version()

    unless reported == expected do
      abort("""
      crate_version/0 answered #{inspect(reported)}, not #{inspect(expected)}.

          The marker is compiled into the NIF from #{@vendored_manifest}, so an
          artifact that disagrees was not built from this tree.
      """)
    end

    say("crate_version/0 answered #{inspect(reported)}")
  end

  @doc """
  The checksum file rustler_precompiled will check `artifact` against.

  One entry, so the compile can only be satisfied by these exact bytes under
  this exact name.
  """
  def checksum_file_body(artifact) do
    digest =
      artifact
      |> File.read!()
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)

    ~s|%{\n  "#{Path.basename(artifact)}" => "sha256:#{digest}",\n}\n|
  end

  @doc """
  Every artifact name rustler_precompiled will look for, straight from itself.

  Asked rather than reconstructed, because the target-name-to-artifact-name
  mapping is the one thing ADR-0004 §6 says not to reimplement.
  """
  def expected_artifact_names do
    @nif_module
    |> RustlerPrecompiled.available_nifs()
    |> Enum.map(fn {tar_gz_name, {_url, _headers}} -> tar_gz_name end)
  end

  @doc """
  The vendored crate's version marker, read where `build.rs` reads it.
  """
  def expected_marker, do: @vendored_manifest |> File.read!() |> crate_marker()

  @doc """
  The `version` key of a Cargo manifest's `[package]` table.

  A line scan, mirroring `native/ex_trafilatura/build.rs` deliberately: the file
  it reads is byte-pinned by `vendor-integrity.sh`, so it cannot be reformatted
  underneath this without that check failing first. A layout this does not
  expect raises rather than returning a wrong version.
  """
  def crate_marker(manifest) do
    manifest
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    |> Enum.drop_while(&(&1 != "[package]"))
    |> Enum.drop(1)
    |> Enum.take_while(&(not String.starts_with?(&1, "[")))
    |> Enum.find_value(fn line ->
      case String.split(line, "version = ", parts: 2) do
        ["", value] -> String.trim(value, "\"")
        _ -> nil
      end
    end)
    |> case do
      nil -> raise "no [package] version in the manifest"
      marker -> marker
    end
  end

  defp cache_dir! do
    System.get_env(@cache_env) ||
      abort("""
      #{@cache_env} is not set.

          Set it to a directory this run owns. It is what puts the artifact in
          front of rustler_precompiled instead of the network.
      """)
  end

  defp version, do: Mix.Project.config()[:version]

  defp say(message), do: IO.puts(:stderr, "artifact-smoke: #{message}")

  defp abort(message) do
    say(message)
    System.halt(1)
  end
end
