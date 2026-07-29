defmodule ExTrafilatura.Native do
  @moduledoc false
  # The NIF boundary itself. Callers go through `ExTrafilatura`; nothing here is
  # public API.

  alias ExTrafilatura.Native.Target

  # The artifact filenames rustler_precompiled builds carry the version, so this
  # and `base_url` must move together with the package's — hence reading it from
  # the project rather than restating it.
  @version Mix.Project.config()[:version]

  @force_build Target.force_build?(@version)

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
