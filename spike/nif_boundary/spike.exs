# THROWAWAY SPIKE — see README.md.  Run with:  mix run spike.exs

defmodule Spike do
  def hr(title) do
    IO.puts("\n" <> IO.ANSI.bright() <> "══ " <> title <> IO.ANSI.reset())
  end

  def bullet(k, v), do: IO.puts("   #{String.pad_trailing(k, 34)} #{v}")

  def bench(fun, n) do
    # warm up
    for _ <- 1..max(div(n, 10), 3), do: fun.()

    times =
      for _ <- 1..n do
        {us, _} = :timer.tc(fun)
        us
      end
      |> Enum.sort()

    %{
      mean: Enum.sum(times) / length(times) / 1000,
      p50: Enum.at(times, div(length(times), 2)) / 1000,
      p99: Enum.at(times, min(round(length(times) * 0.99), length(times) - 1)) / 1000
    }
  end

  def ms(f), do: :erlang.float_to_binary(f, decimals: 3) <> " ms"
end

IO.puts(IO.ANSI.bright() <> "\nNIF boundary spike — trafilatura 0.3.0 / rustler 0.38.0" <> IO.ANSI.reset())

Spike.hr("0. Environment")
Spike.bullet("elixir", System.version())
Spike.bullet("otp", :erlang.system_info(:otp_release) |> to_string())
Spike.bullet("normal schedulers", :erlang.system_info(:schedulers_online))
Spike.bullet("dirty cpu schedulers", :erlang.system_info(:dirty_cpu_schedulers_online))

# ---------------------------------------------------------------------------
Spike.hr("1. Does the round trip work at all?")

html = Fixtures.article(40)
Spike.bullet("input size", "#{byte_size(html)} bytes")

case SpikeNif.extract_full(html) do
  {:ok, result} ->
    Spike.bullet("returned", "{:ok, map} with keys #{inspect(Map.keys(result))}")
    Spike.bullet("content_text", "#{byte_size(result.content_text)} bytes")
    Spike.bullet("content_html", "#{byte_size(result.content_html)} bytes")
    Spike.bullet("comments_text", "#{byte_size(result.comments_text)} bytes")
    Spike.bullet("comments_html", "#{byte_size(result.comments_html)} bytes")
    IO.puts("\n   metadata:")

    Enum.each(result.metadata, fn {k, v} ->
      shown =
        case v do
          "" -> IO.ANSI.yellow() <> ~s("")  <> "  <- empty string, not nil" <> IO.ANSI.reset()
          nil -> IO.ANSI.yellow() <> "nil" <> IO.ANSI.reset()
          other -> inspect(other)
        end

      Spike.bullet("  .#{k}", shown)
    end)

    IO.puts("\n   content_text opens: #{inspect(String.slice(result.content_text, 0, 90))}")
    IO.puts("   comments_text:      #{inspect(String.slice(result.comments_text, 0, 90))}")

  other ->
    IO.puts("   UNEXPECTED: #{inspect(other)}")
end

# ---------------------------------------------------------------------------
Spike.hr("2. What do errors look like coming back?")

for {name, doc} <- [{"empty document", Fixtures.empty()}, {"non-HTML garbage", Fixtures.garbage()}] do
  Spike.bullet(name, inspect(SpikeNif.extract_full(doc)))
end

# ---------------------------------------------------------------------------
Spike.hr("3. UTF-8 across the boundary")

mb = Fixtures.multibyte(40)

case SpikeNif.extract_full(mb) do
  {:ok, r} ->
    Spike.bullet("input", "#{byte_size(mb)} bytes / #{String.length(mb)} graphemes")
    Spike.bullet("content_text valid UTF-8?", String.valid?(r.content_text))
    Spike.bullet("content_html valid UTF-8?", String.valid?(r.content_html))
    Spike.bullet("title round-tripped", inspect(r.metadata.title))
    Spike.bullet("author round-tripped", inspect(r.metadata.author))
    Spike.bullet("emoji survived?", String.contains?(r.content_text, "🎉"))
    Spike.bullet("RTL survived?", String.contains?(r.content_text, "مرحبا"))
    Spike.bullet("sample", inspect(String.slice(r.content_text, 0, 60)))

  other ->
    Spike.bullet("UNEXPECTED", inspect(other))
end

# ---------------------------------------------------------------------------
Spike.hr("4. Panics — does catch_unwind hold?")

Spike.bullet("panic_guarded/0", inspect(SpikeNif.panic_guarded()))

straddle = Fixtures.straddling_date()
Spike.bullet("straddling-date doc", "#{byte_size(straddle)} bytes, date=\"1234567é9\"")
Spike.bullet("extract_full (guarded)", inspect(SpikeNif.extract_full(straddle), limit: 3, printable_limit: 60))

IO.puts("\n   (unguarded variants run in a separate VM below, so a crash cannot")
IO.puts("    take these results with it)")

# ---------------------------------------------------------------------------
Spike.hr("5. What does the boundary cost?")

IO.puts("""
   noop            = binary in, integer out (marshalling floor)
   extract_discard = extract, drop the result   (extraction only)
   extract_full    = extract + build result map (extraction + encoding)
""")

sizes = [{"small  (10 paras)", 10}, {"medium (40 paras)", 40}, {"large  (200 paras)", 200}, {"huge   (1000 paras)", 1000}]

for {label, paras} <- sizes do
  doc = Fixtures.article(paras)
  n = if paras > 200, do: 40, else: 200

  noop = Spike.bench(fn -> SpikeNif.noop(doc) end, n)
  disc = Spike.bench(fn -> SpikeNif.extract_discard(doc) end, n)
  full = Spike.bench(fn -> SpikeNif.extract_full(doc) end, n)

  {:ok, r} = SpikeNif.extract_full(doc)
  out = byte_size(r.content_text) + byte_size(r.content_html) + byte_size(r.comments_text) + byte_size(r.comments_html)

  encode = full.mean - disc.mean
  pct = if disc.mean > 0, do: Float.round(encode / disc.mean * 100, 1), else: 0.0

  IO.puts("\n   #{IO.ANSI.bright()}#{label}#{IO.ANSI.reset()} — #{byte_size(doc)} bytes in, #{out} bytes out")
  Spike.bullet("  noop", "#{Spike.ms(noop.mean)} mean")
  Spike.bullet("  extract_discard", "#{Spike.ms(disc.mean)} mean / #{Spike.ms(disc.p50)} p50 / #{Spike.ms(disc.p99)} p99")
  Spike.bullet("  extract_full", "#{Spike.ms(full.mean)} mean / #{Spike.ms(full.p50)} p50 / #{Spike.ms(full.p99)} p99")
  Spike.bullet("  => encoding cost", "#{Spike.ms(encode)}  (#{pct}% on top of extraction)")
end

# ---------------------------------------------------------------------------
Spike.hr("6. Dirty scheduler behaviour")

doc = Fixtures.article(400)
{serial_us, _} = :timer.tc(fn -> for _ <- 1..20, do: SpikeNif.extract_full(doc) end)

# Hammer the dirty pool while a plain process measures normal-scheduler latency.
parent = self()

probe =
  spawn(fn ->
    worst =
      Enum.reduce(1..2000, 0, fn _, acc ->
        {us, _} = :timer.tc(fn -> Process.sleep(1) end)
        max(acc, us)
      end)

    send(parent, {:probe, worst})
  end)

{par_us, _} =
  :timer.tc(fn ->
    1..20
    |> Task.async_stream(fn _ -> SpikeNif.extract_full(doc) end, max_concurrency: 20, timeout: 120_000)
    |> Enum.to_list()
  end)

worst =
  receive do
    {:probe, w} -> w
  after
    30_000 ->
      Process.exit(probe, :kill)
      :timeout
  end

Spike.bullet("20 extractions, serial", "#{Spike.ms(serial_us / 1000)}")
Spike.bullet("20 extractions, 20-way parallel", "#{Spike.ms(par_us / 1000)}")
Spike.bullet("speedup", Float.round(serial_us / par_us, 2))
Spike.bullet("dirty cpu schedulers", :erlang.system_info(:dirty_cpu_schedulers_online))

case worst do
  :timeout ->
    Spike.bullet("normal-scheduler latency", "probe timed out")

  w ->
    Spike.bullet("worst Process.sleep(1) under load", "#{Spike.ms(w / 1000)} (target: ~1-2 ms)")
end

# ---------------------------------------------------------------------------
Spike.hr("7. Unguarded panic — separate VM")

{out, status} =
  System.cmd("mix", ["run", "unguarded.exs"], stderr_to_stdout: true, env: [{"MIX_ENV", "dev"}])

IO.puts(out |> String.split("\n") |> Enum.map(&("   " <> &1)) |> Enum.join("\n"))
Spike.bullet("child VM exit status", status)

IO.puts("\n" <> IO.ANSI.bright() <> "Done." <> IO.ANSI.reset() <> " Findings go in the ticket, not here.\n")
