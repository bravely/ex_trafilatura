# THROWAWAY SPIKE — control experiment for the dirty-scheduler claim.
# Run with:  mix run scheduler.exs
#
# spike.exs measured a 28 ms worst-case Process.sleep(1) under 20-way load, but
# with no baseline that number means nothing. This measures the SAME probe with
# no load, then sweeps concurrency, so the shape is attributable.

doc = Fixtures.article(400)
dirty = :erlang.system_info(:dirty_cpu_schedulers_online)
normal = :erlang.system_info(:schedulers_online)

IO.puts("\nnormal schedulers: #{normal}   dirty cpu schedulers: #{dirty}\n")

# The probe: an ordinary BEAM process doing ordinary work. Records how late each
# 1 ms sleep actually came back.
probe = fn duration_ms ->
  deadline = System.monotonic_time(:millisecond) + duration_ms

  Stream.repeatedly(fn ->
    {us, _} = :timer.tc(fn -> Process.sleep(1) end)
    us
  end)
  |> Stream.take_while(fn _ -> System.monotonic_time(:millisecond) < deadline end)
  |> Enum.to_list()
end

report = fn label, samples ->
  s = Enum.sort(samples)
  n = length(s)
  p = fn q -> Enum.at(s, min(round(n * q), n - 1)) / 1000 end
  f = &:erlang.float_to_binary(&1, decimals: 2)

  IO.puts(
    "  #{String.pad_trailing(label, 24)} n=#{String.pad_trailing(to_string(n), 6)} " <>
      "p50 #{f.(p.(0.5))} ms   p99 #{f.(p.(0.99))} ms   max #{f.(p.(1.0))} ms"
  )
end

# --- control: no NIF load at all -------------------------------------------
report.("idle (control)", probe.(1500))

# --- sweep concurrency ------------------------------------------------------
for conc <- [1, 5, 10, 20, 40] do
  parent = self()
  pid = spawn(fn -> send(parent, {:probe, probe.(1500)}) end)

  load =
    Task.async(fn ->
      deadline = System.monotonic_time(:millisecond) + 1500

      Stream.repeatedly(fn -> :run end)
      |> Stream.take_while(fn _ -> System.monotonic_time(:millisecond) < deadline end)
      |> Task.async_stream(fn _ -> SpikeNif.extract_full(doc) end,
        max_concurrency: conc,
        timeout: 120_000
      )
      |> Enum.count()
    end)

  samples = receive do: ({:probe, s} -> s)
  done = Task.await(load, 120_000)
  Process.exit(pid, :kill)

  report.("#{conc}-way NIF load", samples)
  IO.puts("  #{String.duplicate(" ", 24)}(#{done} extractions completed)")
end

IO.puts("")
