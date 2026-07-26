# THROWAWAY SPIKE — follow-ups on things the main run surprised us with.
# Run with:  mix run oddities.exs

show = fn label, v -> IO.puts("  #{String.pad_trailing(label, 40)} #{inspect(v)}") end

IO.puts("\n-- Is `language` extracted, or defaulted to \"en\"? --")

for {label, doc} <- [
      {"no lang attribute at all", "<html><body><p>#{String.duplicate("word ", 300)}</p></body></html>"},
      {"lang=\"ja\", japanese body", Fixtures.multibyte(30)},
      {"lang=\"fr\" declared", "<html lang=\"fr\"><body><p>#{String.duplicate("mot ", 300)}</p></body></html>"},
      {"non-HTML garbage", Fixtures.garbage()}
    ] do
  case SpikeNif.extract_full(doc) do
    {:ok, r} -> show.(label, r.metadata.language)
    other -> show.(label, other)
  end
end

IO.puts("\n-- Is there any input that is 'not HTML' to the crate? --")

for {label, doc} <- [
      {"plain sentence", Fixtures.garbage()},
      {"JSON", ~s({"a": 1, "b": [2,3], "c": "#{String.duplicate("x", 400)}"})},
      {"raw binary-ish bytes", <<0, 1, 2, 3>> <> String.duplicate("zz", 400)},
      {"unclosed tags", "<div><p><span>#{String.duplicate("hello ", 200)}"},
      {"empty string", ""}
    ] do
  case SpikeNif.extract_full(doc) do
    {:ok, r} -> show.(label, {:ok, byte_size(r.content_text), String.slice(r.content_text, 0, 30)})
    {:error, e} -> show.(label, {:error, e})
  end
end

IO.puts("\n-- Does a non-UTF8 binary even reach the NIF? (html: &str) --")

bad = <<0xFF, 0xFE, 0xFD>> <> "<html><body><p>hello</p></body></html>"

try do
  show.("invalid UTF-8 binary", SpikeNif.extract_full(bad))
rescue
  e -> show.("invalid UTF-8 binary", {:rescued, Exception.message(e)})
catch
  k, v -> show.("invalid UTF-8 binary", {:caught, k, v})
end

IO.puts("\n-- Which metadata fields are \"\" vs nil on a rich page? --")

{:ok, r} = SpikeNif.extract_full(Fixtures.article(40))

{empty, present} = Enum.split_with(r.metadata, fn {_k, v} -> v == "" or v == nil or v == [] end)
show.("absent-ish", Enum.map(empty, fn {k, v} -> {k, v} end))
show.("populated", Enum.map(present, fn {k, _} -> k end))

IO.puts("")
