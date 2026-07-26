# THROWAWAY SPIKE — run by spike.exs in a child VM, because these calls may
# legitimately take the whole node down. That is the thing being measured.

straddle = Fixtures.straddling_date()

IO.puts("child VM: calling extract_unguarded/1 on the straddling-date doc")

result =
  try do
    {:returned, SpikeNif.extract_unguarded(straddle)}
  rescue
    e -> {:rescued, Exception.message(e) |> String.slice(0, 160)}
  catch
    kind, val -> {:caught, kind, inspect(val) |> String.slice(0, 160)}
  end

case result do
  {:returned, {:ok, _}} -> IO.puts("child VM: returned {:ok, _} — no panic on this input")
  {:returned, other} -> IO.puts("child VM: returned #{inspect(other, limit: 3, printable_limit: 60)}")
  {:rescued, msg} -> IO.puts("child VM: RESCUED an Elixir exception -> #{msg}")
  {:caught, kind, val} -> IO.puts("child VM: CAUGHT #{kind} -> #{val}")
end

IO.puts("child VM: calling panic_unguarded/0")

result2 =
  try do
    {:returned, SpikeNif.panic_unguarded()}
  rescue
    e -> {:rescued, Exception.message(e) |> String.slice(0, 160)}
  catch
    kind, val -> {:caught, kind, inspect(val) |> String.slice(0, 160)}
  end

case result2 do
  {:returned, r} -> IO.puts("child VM: returned #{inspect(r)}")
  {:rescued, msg} -> IO.puts("child VM: RESCUED an Elixir exception -> #{msg}")
  {:caught, kind, val} -> IO.puts("child VM: CAUGHT #{kind} -> #{val}")
end

IO.puts("child VM: still alive at the end")
