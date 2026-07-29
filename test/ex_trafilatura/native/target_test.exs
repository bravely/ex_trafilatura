defmodule ExTrafilatura.Native.TargetTest do
  use ExUnit.Case, async: true

  alias ExTrafilatura.Native.Target

  describe "supported/0" do
    test "is ADR-0004 §3's eight: the precompiled default ten minus RISC-V and 32-bit ARM" do
      assert Enum.sort(Target.supported()) == [
               "aarch64-apple-darwin",
               "aarch64-unknown-linux-gnu",
               "aarch64-unknown-linux-musl",
               "x86_64-apple-darwin",
               "x86_64-pc-windows-gnu",
               "x86_64-pc-windows-msvc",
               "x86_64-unknown-linux-gnu",
               "x86_64-unknown-linux-musl"
             ]
    end

    test "is a subset of what rustler_precompiled would ship by default" do
      # The two we drop are dropped from *its* default list, not from some list
      # of our own — so if upstream's default moves, this fails rather than
      # silently shipping a set nobody chose.
      defaults = RustlerPrecompiled.Config.default_targets()

      assert Enum.sort(defaults -- Target.supported()) == [
               "arm-unknown-linux-gnueabihf",
               "riscv64gc-unknown-linux-gnu"
             ]
    end
  end

  describe "unsupported_message/1" do
    # ADR-0004 §11 states this at intent level: the failure a user hits on an
    # unlisted target must name the target, the eight supported targets, and the
    # environment variable. rustler_precompiled 0.9.0's own message names the
    # first two and no force-build mechanism at all, so this message is ours.
    setup do
      %{message: Target.unsupported_message("riscv64gc-unknown-linux-gnu")}
    end

    test "names the target the user is actually on", %{message: message} do
      assert message =~ "riscv64gc-unknown-linux-gnu"
    end

    test "names all eight supported targets", %{message: message} do
      for target <- Target.supported() do
        assert message =~ target
      end
    end

    test "names the environment variable that enables a source build", %{message: message} do
      assert message =~ "EX_TRAFILATURA_BUILD=1"
    end

    test "says a Rust toolchain is needed, since that is the other half of the recourse",
         %{message: message} do
      assert message =~ "Rust"
    end
  end

  describe "supported?/1" do
    test "accepts a listed target" do
      assert Target.supported?("x86_64-unknown-linux-gnu")
    end

    test "rejects the two dropped from the default set" do
      refute Target.supported?("riscv64gc-unknown-linux-gnu")
      refute Target.supported?("arm-unknown-linux-gnueabihf")
    end

    test "rejects a target rustler_precompiled never contemplated" do
      refute Target.supported?("powerpc64le-unknown-linux-gnu")
    end
  end

  describe "triple/2" do
    # Recovering the *normalized* triple matters: `:erlang.system_info/1` reports
    # things like `x86_64-pc-linux-gnu`, which would not match any row of the
    # table the same message prints.
    test "strips the nif-version prefix off a resolved target" do
      assert Target.triple({:ok, "nif-2.15-x86_64-unknown-linux-gnu"}, "fallback") ==
               "x86_64-unknown-linux-gnu"
    end

    test "recovers the triple rustler_precompiled quotes back in its own failure" do
      message =
        ~s(precompiled NIF is not available for this target: "powerpc64le-unknown-linux-gnu".\n) <>
          "The available targets are:\n - x86_64-unknown-linux-gnu"

      assert Target.triple({:error, message}, "fallback") == "powerpc64le-unknown-linux-gnu"
    end

    test "falls back rather than losing the target when the failure is shaped differently" do
      # The NIF-version arm of `RustlerPrecompiled.target/3` quotes a version
      # rather than a triple, and the wording is upstream's to change. An
      # un-normalized architecture is a worse answer than the triple; it is a
      # much better one than no target at all.
      assert Target.triple({:error, "precompiled NIF is not available for this NIF version"}, "x") ==
               "x"
    end
  end

  describe "force_build?/2" do
    test "is off by default: a source build is opt-in, never automatic (ADR-0004 §2)" do
      refute Target.force_build?("0.1.0", nil)
    end

    test "is on when the environment variable is set" do
      assert Target.force_build?("0.1.0", "1")
      assert Target.force_build?("0.1.0", "true")
    end

    test "ignores values that are not the documented ones" do
      refute Target.force_build?("0.1.0", "0")
      refute Target.force_build?("0.1.0", "")
      refute Target.force_build?("0.1.0", "yes")
    end

    test "is on for any pre-release, which is ours to enforce rather than inherited" do
      # ADR-0004 §2: "`force_build` flips to `true` automatically for pre-release
      # versions, so any `0.1.0-rc.N` is a source build for everyone." That is
      # not what rustler_precompiled 0.9.0 does — its `pre_release?/1` is
      # `"dev" in Version.parse!(version).pre`, so `-rc.1` would download.
      assert Target.force_build?("0.1.0-rc.1", nil)
      assert Target.force_build?("0.1.0-dev", nil)
      assert Target.force_build?("0.2.0-alpha.3", nil)
    end
  end

  describe "check!/1" do
    test "passes silently on a supported target" do
      assert Target.check!({:ok, "nif-2.15-aarch64-apple-darwin"}) == :ok
    end

    test "raises the message on an unlisted target" do
      assert_raise RuntimeError, ~r/riscv64gc-unknown-linux-gnu/, fn ->
        Target.check!({:ok, "nif-2.15-riscv64gc-unknown-linux-gnu"})
      end
    end

    test "raises on a target rustler_precompiled could not resolve at all" do
      message = ~s(precompiled NIF is not available for this target: "x86_64-unknown-haiku".)

      assert_raise RuntimeError, ~r/EX_TRAFILATURA_BUILD=1/, fn ->
        Target.check!({:error, message})
      end
    end
  end
end
