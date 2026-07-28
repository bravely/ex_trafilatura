defmodule ExTrafilatura.Native do
  @moduledoc false
  # The NIF boundary itself. Callers go through `ExTrafilatura`; nothing here is
  # public API.

  use Rustler, otp_app: :ex_trafilatura, crate: :ex_trafilatura

  def extract(_html), do: :erlang.nif_error(:nif_not_loaded)
  def crate_version, do: :erlang.nif_error(:nif_not_loaded)
end
