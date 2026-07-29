defmodule ExTrafilatura do
  @moduledoc """
  Main content and metadata extraction for web pages, binding the Rust
  `trafilatura` crate over a NIF.
  """

  alias ExTrafilatura.Native
  alias ExTrafilatura.Options
  alias ExTrafilatura.Panic
  alias ExTrafilatura.Result

  @typedoc """
  Why an extraction did not return a result.

  Every term carries exactly what you do not already have: a bare atom where the
  crate's own payload was constants or an echo of what you passed in, and a
  tagged tuple where it was information. No reason is a map, and every payload
  is a single value.

    * `:insufficient_content` — the document yielded no content at all. See
      `extract/2` on why this is an error rather than an empty result.

    * `{:missing_metadata, :title | :url | :date}` — you set
      `has_essential_metadata` and the document was without one of the three,
      checked in that order. The set is closed at three by construction.

    * `{:language_mismatch, String.t() | nil}` — `target_language` was set and
      the document did not match. The payload is the language that was
      *detected*, and `nil` means none could be — which happens both when the
      document's own declaration refused it before extraction ran, and when the
      classifier could not place the extracted text.

    * `{:panic, String.t()}` — the crate panicked, and the extraction was
      caught rather than taking your process with it. Also emits a
      `Logger.error`. This is a bug in the crate; please report it.

    * `{:unknown, String.t()}` — anything else the crate returned, in the
      crate's own words. **Diagnostic, not contract: never match on the
      string.** Its content will change without a major version, and a reason
      that reaches you here today may become a term of its own tomorrow.
  """
  @type reason ::
          :insufficient_content
          | {:missing_metadata, :title | :url | :date}
          | {:language_mismatch, String.t() | nil}
          | {:panic, String.t()}
          | {:unknown, String.t()}

  @doc """
  Extracts the main content and metadata of an HTML document.

      {:ok, result} = ExTrafilatura.extract(html)
      result.content_text
      result.metadata.title

  `ExTrafilatura.extract(html)` **is** the crate's own default call — no option
  is defaulted on here, and none is renamed. Note that these are the *crate's*
  defaults and not Python trafilatura's: the fallback pass is off, and comments
  are included.

  Returns `{:error, reason}` when the crate declines to extract, where `reason`
  is one of `t:reason/0`'s five terms. A page with no article body is one of
  those cases: "nothing extracted" is an error rather than a successful empty
  result, because the crate returns before it builds a result and the metadata
  it had already gathered goes with it — normalising would mean fabricating a
  result that asserts a titled stub page had no title.

      case ExTrafilatura.extract(html) do
        {:ok, result} -> result.content_text
        {:error, :insufficient_content} -> "no article on this page"
        {:error, reason} -> raise "extraction failed: \#{inspect(reason)}"
      end

  Two of the five are the crate saying something went wrong on its own side:
  `{:panic, message}` is a crate bug, and `{:unknown, message}` is a variant
  with no term of its own yet. Writing `_ -> :skip` in place of that last clause
  is the one shape worth avoiding, because it buries both — which is why a
  `{:panic, _}` also emits a `Logger.error`.

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

  **An unknown key raises**, and so does an invalid value, both as a
  `NimbleOptions.ValidationError` naming the key. Exceptions here mean exactly
  one thing — that you called it wrong — and nothing arriving from the network
  can cause one. If you keep extraction options alongside your own in one
  config, `Keyword.take/2` the ones meant for us.

  `nil` is a value only for the four keys whose default is `nil` — passing one
  of those at `nil` is the same call as leaving it out. On the other eight it is
  a wrong value and raises, so `focus: nil` is a mistake rather than a way of
  spelling `:balanced`.

  These are the crate's own options, under the crate's own names, so
  [its documentation](https://docs.rs/trafilatura) describes the same knobs.
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
  @spec extract(binary(), keyword()) :: {:ok, Result.t()} | {:error, reason()}
  def extract(html, opts \\ []) when is_binary(html) and is_list(opts) do
    html
    |> Native.extract(Options.normalize(opts))
    |> Panic.report()
  end

  @doc """
  The version of the vendored `trafilatura` crate this build extracts with.

  The `+extrafilatura.N` build-metadata marker distinguishes our patched copy
  from stock 0.3.0 on crates.io.
  """
  @spec crate_version() :: String.t()
  def crate_version, do: Native.crate_version()
end
