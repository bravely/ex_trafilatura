defmodule ExTrafilatura do
  @moduledoc """
  Main content and metadata extraction for web pages, binding the Rust
  `trafilatura` crate over a NIF.
  """

  alias ExTrafilatura.Native
  alias ExTrafilatura.Options
  alias ExTrafilatura.Result

  @doc """
  Extracts the main content and metadata of an HTML document.

      {:ok, result} = ExTrafilatura.extract(html)
      result.content_text
      result.metadata.title

  `ExTrafilatura.extract(html)` **is** the crate's own default call — no option
  is defaulted on here, and none is renamed. Note that these are the *crate's*
  defaults and not Python trafilatura's: the fallback pass is off, and comments
  are included.

  Returns `{:error, reason}` when the crate declines to extract. A page with no
  article body is one of those cases: "nothing extracted" is an error rather than
  a successful empty result, because the crate returns before it builds a result
  and the metadata it had already gathered goes with it — normalising would mean
  fabricating a result that asserts a titled stub page had no title.

  > #### Most of the error term is provisional {: .warning}
  >
  > The two rejections below are final, and can be matched on today. Everything
  > the *crate* declines still arrives as `{:error, {:unknown, message}}`, and
  > that message is **diagnostic, not contract — never match on it**. The
  > decided set of reasons is seven terms wide; mapping the crate's three
  > reachable errors onto their own terms is still to come.

  ## The input contract

  `html` must be a **UTF-8 binary of no more than 10 MB**. Both limits are
  checked in Elixir before the extractor is reached, in that order, and both
  refuse rather than repair.

    * Over the cap: `{:error, :input_too_large}`. Never a truncation — an HTML
      document cut at an arbitrary byte lands mid-tag, and nothing is invalid
      HTML to the extractor, so a truncating cap would return a plausible
      `{:ok, _}` derived from a document that never existed. Raise the cap with
      `max_input_bytes`, or remove it with `max_input_bytes: :infinity`.

    * Not UTF-8: `{:error, {:invalid_utf8, offset}}`, where `offset` is the byte
      position the first invalid sequence starts at. There is no option to
      disable this one and no encoding detection behind it.

  This library does no transcoding, and the reason is that **you are standing
  next to the answer and we are not**: an HTTP response carries
  `Content-Type: text/html; charset=windows-1252` — authoritative, needing no
  detection at all — and that signal is discarded before the bytes reach us. So
  take the charset from the response header, fall back to the `<meta charset>`
  in the first 1024 bytes when the header is silent, and transcode before
  calling. [`codepagex`](https://hex.pm/packages/codepagex) (pure Elixir) and
  [`iconv`](https://hex.pm/packages/iconv) (a NIF, faster) both do it; neither
  is tested or endorsed here.

  One case gets through and is worth knowing about: **BOM-less UTF-16 passes**.
  It interleaves NUL bytes, and U+0000 is valid UTF-8, so it is invisible to the
  check and extracts to garbage rather than being refused. The BOM-marked form
  is refused, at offset 0. A UTF-8 BOM is fine — the parser strips it.

  ## Options

      {:ok, result} = ExTrafilatura.extract(html, focus: :favor_precision, include_links: true)

  | key | value | default |
  |---|---|---|
  | `focus` | `:balanced \\| :favor_precision \\| :favor_recall` | `:balanced` |
  | `exclude_comments` | boolean | `false` |
  | `exclude_tables` | boolean | `false` |
  | `include_links` | boolean | `false` |
  | `include_images` | boolean | `false` |
  | `enable_fallback` | boolean | `false` |
  | `target_language` | binary (ISO 639-1) or `nil` | `nil` |
  | `has_essential_metadata` | boolean | `false` |
  | `original_url` | binary or `nil` | `nil` |
  | `prune_selector` | binary (CSS) or `nil` | `nil` |
  | `excluded_authors` | list of binaries | `[]` |
  | `html_date_override` | `t:Date.t/0` or `nil` | `nil` |
  | `max_input_bytes` | positive integer or `:infinity` | `10_485_760` |

    * `focus` — how much borderline content to keep. `:favor_precision` drops
      more blocks it is unsure about, giving cleaner output at the risk of
      losing real content; `:favor_recall` keeps more, giving fuller output at
      the risk of retaining boilerplate. One setting, not two.

    * `exclude_comments` — when `true`, reader comments are not extracted, and
      `comments_text` and `comments_html` come back empty. **Note the sense**:
      comments are extracted by default.

    * `exclude_tables` — when `true`, tables are dropped from the extracted
      content. They are kept by default.

    * `include_links` — when `true`, `<a>` tags are preserved in `content_html`.
      They are stripped by default, leaving the link text behind.

    * `include_images` — when `true`, `<img>` tags are preserved in
      `content_html`. They are stripped by default.

    * `enable_fallback` — when `true`, documents the main pass does poorly on
      get a second pass, using the readability and justext algorithms, and
      whichever result scores better is returned. This is the expensive option,
      and it is slowest on the documents that are already slowest.

    * `target_language` — an ISO 639-1 code, such as `"en"`. A document whose
      language does not match is **refused**, returning `{:error, reason}`
      rather than extracting. Off by default, so no document is refused.

    * `has_essential_metadata` — when `true`, a document without a title, a URL
      and a date is refused, returning `{:error, reason}`. The three are checked
      in that order.

    * `original_url` — the URL the document was fetched from. Relative links and
      images in the document resolve against it, and it fills in
      `metadata.url` and `metadata.hostname` when the document declares no URL
      of its own. Must have a scheme; nothing is fetched.

    * `prune_selector` — a CSS selector. Matching elements are removed from the
      document before extraction runs, so nothing inside one can reach any part
      of the result.

    * `excluded_authors` — names to drop from `metadata.author`, matched
      case-insensitively against each name the crate found. If every name is
      excluded, `metadata.author` is `nil`.

    * `html_date_override` — used as `metadata.date` directly, instead of
      extracting a date from the document.

    * `max_input_bytes` — the size cap described above, in bytes of the binary
      you pass. **The one option here that is not the crate's**; no such knob
      exists upstream, because a guard on the input physically cannot live
      downstream of the call it guards. It is per-call so that one known-huge
      document can be let through in place rather than by changing global
      policy. It bounds memory and catches the accident — a video file, a
      database dump, an unbounded concatenation. It does **not** bound time: a
      small, deeply nested document can occupy a scheduler thread for tens of
      seconds and still be far under the cap.

  **An unknown key raises**, and so does an invalid value, both as a
  `NimbleOptions.ValidationError` naming the key. Exceptions here mean exactly
  one thing — that you called it wrong — and nothing arriving from the network
  can cause one. If you keep extraction options alongside your own in one
  config, `Keyword.take/2` the ones meant for us.

  `nil` is a value only for the four keys whose default is `nil` — passing one
  of those at `nil` is the same call as leaving it out. On the other nine it is
  a wrong value and raises, so `focus: nil` is a mistake rather than a way of
  spelling `:balanced`, and `max_input_bytes: nil` is not how you remove the cap
  (`:infinity` is).

  Twelve of the thirteen are the crate's own options, under the crate's own
  names, so [its documentation](https://docs.rs/trafilatura) describes the same
  knobs. `max_input_bytes` is ours.
  """
  # Why this list and not another: the crate has eighteen option fields plus a
  # nested config block of seven, and six are omitted here. The cut is made on
  # *behaviour* rather than on the field list, because a knob that silently does
  # nothing is worse than an absent one — the caller cannot tell.
  #
  #   * `config` — its seven fields are go-trafilatura's defaults, so they *are*
  #     the fidelity baseline rather than tuning. Omitting it also keeps the
  #     surface one flat level.
  #   * `enable_log` — declared and settable, never read anywhere in the crate.
  #   * `html_date_mode` — only `Disabled` is ever branched on; `Default`,
  #     `Fast` and `Extensive` are identical, and upstream's own doc comment
  #     admits `Extensive` is unimplemented.
  #   * `deduplicate` — documented as cross-document, but its LRU cache is
  #     constructed per call, so it can only ever be intra-document.
  #   * `max_tree_size` — counts children of the *extracted* body and so fires
  #     after the work is done. Shipping it would invite use as the resource
  #     bound it is not (ADR-0001).
  #   * `fallback_candidates` — requires the caller to have run their own
  #     readability pass, and is the only struct-valued option.
  #
  # Omitting `deduplicate` and `max_tree_size` is what makes `DuplicateContent`
  # and `TreeTooLarge` unreachable by construction, which is why ADR-0006 §4 has
  # three crate-sourced error reasons rather than five. Restoring any of the six
  # is additive; removing one later would not be. Decided in #11.
  @spec extract(binary(), keyword()) ::
          {:ok, Result.t()}
          | {:error,
             :input_too_large | {:invalid_utf8, non_neg_integer()} | {:unknown, String.t()}}
  def extract(html, opts \\ []) when is_binary(html) and is_list(opts) do
    {max_input_bytes, overrides} = Options.normalize(opts)

    # Every input rejection, in one place and in a fixed order (ADR-0006 §4).
    # The size cap is the cheapest gate there is — `byte_size/1` reads a header
    # rather than traversing — so it goes first, and the encoding gate, which
    # walks the binary, sits behind it. Neither can mask the other's error.
    with :ok <- within_size_cap(html, max_input_bytes),
         :ok <- valid_utf8(html) do
      Native.extract(html, overrides)
    end
  end

  # `:infinity` is matched rather than compared. Term ordering would make the
  # comparison below come out right on its own — every integer sorts under
  # every atom — but that is a fact about Erlang, not about this cap, and a
  # reader should not have to know it to see that `:infinity` lets everything
  # through.
  defp within_size_cap(_html, :infinity), do: :ok
  defp within_size_cap(html, max_input_bytes) when byte_size(html) <= max_input_bytes, do: :ok
  defp within_size_cap(_html, _max_input_bytes), do: {:error, :input_too_large}

  # Never a repair, and never a transcode: we refuse the bytes and say where.
  # The gate is unconditional because validity is a precondition rather than a
  # policy — there is nothing here for a caller to turn off (ADR-0005 §4). What
  # it costs is one walk of the binary, chosen over `String.valid?/1` for being
  # 2–3x faster, content-independent, and the only candidate that reports where
  # it stopped.
  #
  # `rest` is deliberately dropped. It is a sub-binary over the input, so
  # carrying the offending bytes in the error term would retain the whole
  # document against garbage collection — up to `max_input_bytes` of it, held
  # alive by a diagnostic (ADR-0005 §3). The offset retains nothing.
  #
  # `:incomplete` is the same failure arriving from the other end: a multi-byte
  # sequence cut short by the end of the input rather than by a bad byte in the
  # middle. Same refusal, and `accepted` measures the same thing.
  defp valid_utf8(html) do
    case :unicode.characters_to_binary(html, :utf8, :utf8) do
      binary when is_binary(binary) -> :ok
      {:error, accepted, _rest} -> {:error, {:invalid_utf8, byte_size(accepted)}}
      {:incomplete, accepted, _rest} -> {:error, {:invalid_utf8, byte_size(accepted)}}
    end
  end

  @doc """
  The version of the vendored `trafilatura` crate this build extracts with.

  The `+extrafilatura.N` build-metadata marker distinguishes our patched copy
  from stock 0.3.0 on crates.io.
  """
  @spec crate_version() :: String.t()
  def crate_version, do: Native.crate_version()
end
