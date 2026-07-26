defmodule SpikeNif do
  @moduledoc "THROWAWAY SPIKE — see README.md."

  use Rustler, otp_app: :spike_nif, crate: "spike_nif"

  def noop(_html), do: :erlang.nif_error(:nif_not_loaded)
  def extract_discard(_html), do: :erlang.nif_error(:nif_not_loaded)
  def extract_full(_html), do: :erlang.nif_error(:nif_not_loaded)
  def extract_unguarded(_html), do: :erlang.nif_error(:nif_not_loaded)
  def panic_guarded, do: :erlang.nif_error(:nif_not_loaded)
  def panic_unguarded, do: :erlang.nif_error(:nif_not_loaded)
end
