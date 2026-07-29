# `tools/` never ships and is not on `elixirc_paths`, so the script is loaded by
# path. That is safe because the file defines a module and does nothing else —
# the workflow drives it with `elixir -r … -e …` rather than by running it.
Code.require_file("../../tools/verify/artifact_smoke.exs", __DIR__)

defmodule ArtifactSmokeTest do
  use ExUnit.Case, async: true

  @moduletag :tmp_dir

  describe "checksum_file_body/1" do
    # The format is rustler_precompiled's, not ours, so this asserts against
    # rustler_precompiled rather than against a string we wrote down. Getting it
    # wrong is the difference between a smoke test that proves the artifact's
    # bytes and one that quietly accepts whatever the cache happens to hold.
    test "is a checksum file rustler_precompiled accepts for the artifact we hashed", %{
      tmp_dir: dir
    } do
      artifact = artifact(dir, "the bytes we built")

      assert :ok =
               RustlerPrecompiled.check_integrity_from_map(
                 checksum_map(artifact),
                 artifact,
                 ExTrafilatura.Native
               )
    end

    test "and rejects the same name carrying different bytes", %{tmp_dir: dir} do
      artifact = artifact(dir, "the bytes we built")
      map = checksum_map(artifact)
      File.write!(artifact, "some other release's bytes, under the same name")

      assert {:error, message} =
               RustlerPrecompiled.check_integrity_from_map(map, artifact, ExTrafilatura.Native)

      assert message =~ "checksum"
    end
  end

  describe "crate_marker/1" do
    test "reads the [package] version, not a dependency's" do
      manifest = """
      [package]
      name = "trafilatura"
      version = "0.3.0+extrafilatura.1"

      [dependencies]
      chrono = { version = "0.4", default-features = false }
      version = "9.9.9"
      """

      assert ArtifactSmoke.crate_marker(manifest) == "0.3.0+extrafilatura.1"
    end

    test "raises rather than guessing when the [package] version is not where it was" do
      assert_raise RuntimeError, ~r/\[package\] version/, fn ->
        ArtifactSmoke.crate_marker("[dependencies]\nversion = \"9.9.9\"\n")
      end
    end
  end

  describe "expected_marker/0" do
    # The property the whole smoke test rests on. `build.rs` compiles this same
    # file's version into the NIF as `TRAFILATURA_VERSION`, so an artifact built
    # from this tree must answer with it — which is what makes a *mismatch*
    # evidence that the artifact came from somewhere else.
    test "is what the NIF built from this tree actually reports" do
      assert ArtifactSmoke.expected_marker() == ExTrafilatura.crate_version()
    end
  end

  describe "expected_artifact_names/0" do
    setup do
      %{names: ArtifactSmoke.expected_artifact_names(), version: version()}
    end

    test "is one name per supported target", %{names: names} do
      assert length(names) == length(ExTrafilatura.Native.Target.supported())
    end

    test "carries the version, NIF version and target the runtime will ask for", %{
      names: names,
      version: version
    } do
      assert "libex_trafilatura-v#{version}-nif-2.15-x86_64-unknown-linux-gnu.so.tar.gz" in names
    end

    test "keeps rustler_precompiled's platform spelling — no lib prefix, .dll on Windows", %{
      names: names,
      version: version
    } do
      assert "ex_trafilatura-v#{version}-nif-2.15-x86_64-pc-windows-msvc.dll.tar.gz" in names
    end

    test "spells Darwin artifacts .so, as erlang:load_nif/2 requires", %{
      names: names,
      version: version
    } do
      assert "libex_trafilatura-v#{version}-nif-2.15-aarch64-apple-darwin.so.tar.gz" in names
    end
  end

  describe "unexpected_names/2" do
    # This is the only thing that looks at `x86_64-pc-windows-gnu`'s name at all.
    # It has no runner and so no smoke leg of its own, but every other leg sees
    # all eight artifacts side by side, so a name the runtime will never ask for
    # is caught seven times over rather than never.
    test "names a built artifact the runtime will never ask for" do
      expected = ArtifactSmoke.expected_artifact_names()
      typo = "ex_trafilatura-v#{version()}-nif-2.15-x86_64-pc-windows-mingw.dll.tar.gz"

      assert ArtifactSmoke.unexpected_names([typo | expected], expected) == [typo]
    end

    # A maintainer running this by hand has one artifact in the directory, not
    # eight, so absence is not the question this asks. The release workflow
    # counts to eight separately, where all eight are in one place.
    test "is silent about names that were not built" do
      expected = ArtifactSmoke.expected_artifact_names()
      [one | _rest] = expected

      assert ArtifactSmoke.unexpected_names([one], expected) == []
    end
  end

  defp artifact(dir, contents) do
    path = Path.join(dir, "libex_trafilatura-v0.1.0-nif-2.15-x86_64-unknown-linux-gnu.so.tar.gz")
    File.write!(path, contents)
    path
  end

  defp checksum_map(artifact) do
    {map, _bindings} = Code.eval_string(ArtifactSmoke.checksum_file_body(artifact))
    map
  end

  defp version, do: Mix.Project.config()[:version]
end
