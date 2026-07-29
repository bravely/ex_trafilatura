defmodule ExTrafilatura.Native do
  @moduledoc false
  # The NIF boundary itself. Callers go through `ExTrafilatura`; nothing here is
  # public API.

  alias ExTrafilatura.Native.Target

  # The artifact filenames rustler_precompiled builds carry the version, so this
  # and `base_url` must move together with the package's — hence reading it from
  # the project rather than restating it.
  @version Mix.Project.config()[:version]

  # Every way a source build can be asked for, read here and decided in
  # `Target`. Passing `force_build:` explicitly below means rustler_precompiled's
  # own resolution of the last three never runs — its `Keyword.put_new/3` finds
  # our value already there — so anything missing from this list is simply dead,
  # including the key its own download failure tells users to reach for.
  @force_build Target.force_build?(@version,
                 ex_trafilatura_build: System.get_env(Target.build_env()),
                 force_build_all_env: System.get_env("RUSTLER_PRECOMPILED_FORCE_BUILD_ALL"),
                 force_build_all: Application.compile_env(:rustler_precompiled, :force_build_all),
                 force_build:
                   Application.compile_env(:rustler_precompiled, [:force_build, :ex_trafilatura])
               )

  # Before rustler_precompiled gets a chance to fail with a message that names
  # no way out (ADR-0004 §11). Skipped when we are building from source, since a
  # source build works on any target — which is the whole reason the message
  # points at it.
  if not @force_build, do: Target.check!()

  use RustlerPrecompiled,
    otp_app: :ex_trafilatura,
    crate: :ex_trafilatura,
    base_url: "https://github.com/bravely/ex_trafilatura/releases/download/v#{@version}",
    version: @version,
    targets: Target.supported(),
    nif_versions: Target.nif_versions(),
    force_build: @force_build

  def extract(_html, _overrides), do: :erlang.nif_error(:nif_not_loaded)
  def crate_version, do: :erlang.nif_error(:nif_not_loaded)
end
