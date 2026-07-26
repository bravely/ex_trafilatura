# THROWAWAY SPIKE — decisive check: does `metadata.language` read the document's
# declared `lang` attribute, or is it statistical detection?
# Run with:  mix run language.exs

english =
  "The parliamentary committee published its findings on Thursday afternoon. " <>
    "Members of the opposition argued that the report understated the costs involved, " <>
    "while the minister responsible insisted the figures had been independently audited. " <>
    "A second hearing is expected before the end of the month, according to a spokesperson."

doc = fn lang_attr ->
  attr = if lang_attr, do: ~s( lang="#{lang_attr}"), else: ""

  "<html#{attr}><head><meta charset=\"utf-8\"></head><body><article>" <>
    "<p>#{String.duplicate(english, 4)}</p></article></body></html>"
end

IO.puts("\nSame unambiguous ENGLISH body, varying only the declared lang attribute:\n")

for declared <- [nil, "en", "fr", "de", "ja", "zz"] do
  {:ok, r} = SpikeNif.extract_full(doc.(declared))

  IO.puts(
    "  declared lang=#{String.pad_trailing(inspect(declared), 8)}" <>
      " -> metadata.language = #{inspect(r.metadata.language)}"
  )
end

IO.puts("\nIf the column on the right does not track the column on the left,")
IO.puts("the declared attribute is being ignored and the value is detected.\n")

IO.puts("Consequence for the `target_language` option (which raises LanguageMismatch):\n")

# target_language is an Options field; the spike NIF hardcodes Options::default(),
# so we can only observe the detector's opinion, not the rejection. That is enough
# to show what the rejection would be built on.
short = "<html lang=\"en\"><body><article><p>#{String.duplicate("Hello there friend. ", 20)}</p></article></body></html>"
{:ok, r} = SpikeNif.extract_full(short)
IO.puts("  short, clearly-English, lang=\"en\"  -> #{inspect(r.metadata.language)}")
