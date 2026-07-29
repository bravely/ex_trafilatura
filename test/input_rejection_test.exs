defmodule ExTrafilatura.InputRejectionTest do
  use ExUnit.Case, async: true

  # The two gates that sit in front of the NIF, and the order they run in
  # (ADR-0001 §3, ADR-0005 §2). Both are Elixir-side, both refuse rather than
  # repair, and neither can mask the other's error.
  #
  # Handwritten minimal HTML only (ADR-0003 §3). Nothing here asserts what the
  # crate extracts — every fixture's point is whether the bytes reach it.

  @article """
  <!DOCTYPE html>
  <html lang="en">
    <head><title>A minimal article</title></head>
    <body>
      <article>
        <p>The first paragraph of the article body, long enough that extraction
        keeps it as main content rather than discarding it as a stray fragment of
        the page furniture that surrounds it.</p>
        <p>A second paragraph, so the article carries enough substance for the
        extractor to settle on this subtree rather than falling through to a
        rescue pass over the whole document.</p>
      </article>
    </body>
  </html>
  """

  # Comfortably past the 10 MB default, and built so that a truncating cap would
  # have plenty of well-formed document to hand back: the whole article sits in
  # front of the padding, so `{:ok, _}` from a truncation would look entirely
  # ordinary. The padding is one comment rather than a million elements because
  # the two tests that do let it reach the extractor pay for what they parse,
  # and neither is about the padding.
  @oversized @article <> "<!--" <> String.duplicate("Padding past the cap. ", 600_000) <> "-->"

  # `0x93` and `0x94` are windows-1252's curly double quotes, and the reason
  # this gate exists: they sit in `0x80`–`0x9F`, the range where windows-1252
  # differs from latin-1, and they are invalid as UTF-8 wherever they land.
  @before_the_bad_byte "<html><body><p>"
  @windows_1252 @before_the_bad_byte <>
                  <<0x93>> <> "Smart quotes" <> <<0x94>> <> "</p></body></html>"

  describe "the input-size cap" do
    test "refuses a document over the default 10 MB, rather than truncating it" do
      # The whole point of the refusal: an HTML document cut at an arbitrary byte
      # lands mid-tag, and the crate treats nothing as invalid HTML — it would
      # return `{:ok, _}` extracted from the wreckage of a document that never
      # existed (ADR-0001 §3). Anything but `{:error, :input_too_large}` here,
      # `{:ok, _}` most of all, is the bug.
      assert byte_size(@oversized) > 10 * 1024 * 1024

      assert ExTrafilatura.extract(@oversized) == {:error, :input_too_large}
    end

    test "accepts a document exactly at the cap and refuses one byte under it" do
      # The comparison itself, pinned at the only place it can be off by one.
      assert {:ok, _} = ExTrafilatura.extract(@article, max_input_bytes: byte_size(@article))

      assert ExTrafilatura.extract(@article, max_input_bytes: byte_size(@article) - 1) ==
               {:error, :input_too_large}
    end

    test ":infinity disables the cap" do
      # A wrong default has to be survivable in place, without waiting on a
      # release from us (ADR-0001 §2). So the escape hatch has to be a real one:
      # the document does not merely stop being refused, it extracts.
      assert {:ok, result} = ExTrafilatura.extract(@oversized, max_input_bytes: :infinity)

      assert result.content_text =~ "The first paragraph"
    end

    test "the size is the caller's own bytes, not a decoded length" do
      # A multi-byte document is capped on what it costs to hold, so the cap
      # counts bytes rather than characters. `byte_size/1` is also the whole
      # reason this gate goes first: no traversal, at any size.
      html = "<html><body><p>日本語</p></body></html>"

      assert byte_size(html) > String.length(html)

      assert ExTrafilatura.extract(html, max_input_bytes: String.length(html)) ==
               {:error, :input_too_large}
    end
  end

  describe "the encoding gate" do
    test "valid UTF-8 passes, non-ASCII and all" do
      html = """
      <!DOCTYPE html>
      <html lang="en">
        <head><title>A minimal article</title></head>
        <body>
          <article>
            <p>The first paragraph carries “curly quotes” and 日本語 through the
            gate and out the other side, long enough that extraction keeps it as
            main content rather than discarding it as a stray fragment.</p>
            <p>A second paragraph, so the article carries enough substance for the
            extractor to settle on this subtree rather than falling through to a
            rescue pass over the whole document.</p>
          </article>
        </body>
      </html>
      """

      assert {:ok, result} = ExTrafilatura.extract(html)
      assert result.content_text =~ "“curly quotes”"
      assert result.content_text =~ "日本語"
    end

    test "windows-1252 smart quotes refuse at the offset of the first invalid byte" do
      assert ExTrafilatura.extract(@windows_1252) ==
               {:error, {:invalid_utf8, byte_size(@before_the_bad_byte)}}
    end

    test "a sequence truncated at the end of the input refuses at where it starts" do
      # `characters_to_binary/3` reports this as `:incomplete` rather than
      # `:error`, and it is the likelier of the two in practice — a document cut
      # by something upstream of us mid-character. Same refusal, same offset.
      prefix = "<html><body><p>Cut off mid-character: "
      html = prefix <> binary_part("é", 0, 1)

      assert ExTrafilatura.extract(html) == {:error, {:invalid_utf8, byte_size(prefix)}}
    end

    test "BOM-marked UTF-16 refuses at offset 0, either endianness" do
      # Both marks lead with a byte that cannot open a UTF-8 sequence, so the
      # refusal is at the mark itself and the document behind it is never read.
      for {bom, endianness} <- [{<<0xFF, 0xFE>>, :little}, {<<0xFE, 0xFF>>, :big}] do
        html = bom <> :unicode.characters_to_binary(@article, :utf8, {:utf16, endianness})

        assert ExTrafilatura.extract(html) == {:error, {:invalid_utf8, 0}}
      end
    end

    test "BOM-less UTF-16 passes the gate — the known limitation, pinned" do
      # UTF-16 interleaves NUL bytes and U+0000 is valid UTF-8, so this document
      # is indistinguishable from valid input to the gate and reaches the crate
      # as NUL-riddled garbage. `{:ok, garbage}` is therefore reachable, and
      # v0.1.0 does not fix it (ADR-0005 §6) — the marked form is refused while
      # this, the form more likely to occur, is not. Asserted rather than
      # avoided, so that fixing it later is a visible change rather than a quiet
      # one.
      #
      # The garbage has a recognisable shape: the NULs stop html5ever seeing
      # tags at all, so the markup arrives as literal text. That is asserted
      # instead of the extracted string itself, which is upstream's to change
      # (ADR-0003 §3).
      html = :unicode.characters_to_binary(@article, :utf8, {:utf16, :little})

      assert {:ok, result} = ExTrafilatura.extract(html)
      assert result.content_text =~ "<!DOCTYPE html>"
    end

    test "a UTF-8 BOM passes, and the parser strips it" do
      # Nothing for us to do: html5ever's tokenizer defaults to `discard_bom`,
      # so a leading U+FEFF never reaches the extracted content (ADR-0005 §5).
      html = <<0xEF, 0xBB, 0xBF>> <> @article

      assert {:ok, result} = ExTrafilatura.extract(html)
      assert result.content_text =~ "The first paragraph"
      refute result.content_text =~ "﻿"
    end

    test "the error carries the byte offset only, never the offending bytes" do
      # `rest` from `characters_to_binary/3` is a sub-binary over the input, so
      # carrying the bytes would retain the whole document against GC — up to
      # 10 MB held alive by a three-byte diagnostic (ADR-0005 §3). An integer
      # retains nothing, which is the reason the payload is one.
      assert {:error, {:invalid_utf8, offset}} = ExTrafilatura.extract(@windows_1252)

      assert is_integer(offset)
    end

    test "there is no opt-out" do
      # Validity is a precondition, not a policy (ADR-0005 §4). Disabling the
      # check could not make invalid input work — it would only downgrade this
      # error to a bare `ArgumentError` out of Rustler. So there is no key for
      # it, and the one knob that does turn a gate off does not reach this one.
      assert_raise NimbleOptions.ValidationError, fn ->
        ExTrafilatura.extract(@windows_1252, validate_utf8: false)
      end

      assert {:error, {:invalid_utf8, _}} =
               ExTrafilatura.extract(@windows_1252, max_input_bytes: :infinity)
    end
  end

  describe "the order the gates run in" do
    test "the size cap runs first, so oversized input is refused on its size" do
      # Fixed and held in one function: size cap, then encoding gate, then the
      # NIF (ADR-0006 §4). The document below fails both tests, so the reason it
      # comes back with is the whole assertion — and raising the cap out of the
      # way leaves the second gate to catch it.
      both_wrong = <<0x93>> <> @oversized

      assert ExTrafilatura.extract(both_wrong) == {:error, :input_too_large}

      assert ExTrafilatura.extract(both_wrong, max_input_bytes: :infinity) ==
               {:error, {:invalid_utf8, 0}}
    end

    test "an invalid option is refused before either gate is reached" do
      # The schema runs first of all, and it raises rather than returning — the
      # invariant being that an exception means exactly one thing, that you
      # called it wrong. Oversized input is not that; it arrives from the
      # network.
      assert_raise NimbleOptions.ValidationError, fn ->
        ExTrafilatura.extract(@oversized, focus: :sideways)
      end
    end
  end
end
