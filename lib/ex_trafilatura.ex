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

  > #### The error term is provisional {: .warning}
  >
  > Every failure currently arrives as `{:error, {:unknown, message}}`, and the
  > message is **diagnostic, not contract — never match on it**. The decided set
  > of reasons is seven terms wide, and mapping the crate's errors onto it is
  > still to come. Match `{:error, _}` until then.

  ## Options

  A flat keyword list of twelve keys, each one an option of the Rust crate,
  under the crate's own name and at the crate's own default.

      {:ok, result} = ExTrafilatura.extract(html, focus: :favor_precision, include_links: true)

  | key | value | default |
  |---|---|---|
  | `focus` | `:balanced \\| :favor_precision \\| :favor_recall` | `:balanced` |
  | `exclude_comments` | boolean | `false` — comments **included** |
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

  `focus` is the precision-versus-recall axis, and it is one setting rather than
  two: favouring precision drops more borderline blocks, favouring recall keeps
  more. `enable_fallback` turns on a second extraction pass over documents the
  first pass does poorly on — the expensive option, and slowest on the documents
  that are already slowest.

  **The senses are mixed, and that is the crate's mixture, not an oversight**:
  `exclude_comments` and `exclude_tables` are negative, `include_links` and
  `include_images` positive. Matching the crate's names is what lets you read
  [the crate's own documentation](https://docs.rs/trafilatura) to learn what a
  knob does, which is why they are not translated.

  **Unknown keys are ignored**, so a superset from your own config is safe to
  pass — at the cost that a typo'd `exclude_comment:` is silent. An **invalid
  value raises `ArgumentError`**: exceptions here mean exactly one thing, that
  you called it wrong, and nothing arriving from the network can cause one.

  ### The options that are not here

  The crate has eighteen fields plus a nested config block of seven. The six
  omitted are omitted on *behaviour* — a knob that silently does nothing is
  worse than an absent one, because you cannot tell:

    * `config` — its seven fields are the fidelity baseline, not tuning.
    * `enable_log` — declared and settable, never read anywhere in the crate.
    * `html_date_mode` — only `Disabled` is ever branched on, and `Extensive` is
      unimplemented upstream.
    * `deduplicate` — documented as cross-document, but its cache is rebuilt per
      call, so it is intra-document only.
    * `max_tree_size` — fires *after* the work is done, so it is not the safety
      valve it looks like.
    * `fallback_candidates` — needs you to run your own readability pass first.

  Restoring any of them later is additive.
  """
  @spec extract(binary(), keyword()) :: {:ok, Result.t()} | {:error, {:unknown, String.t()}}
  def extract(html, opts \\ []) when is_binary(html) do
    Native.extract(html, Options.normalize(opts))
  end

  @doc """
  The version of the vendored `trafilatura` crate this build extracts with.

  The `+extrafilatura.N` build-metadata marker distinguishes our patched copy
  from stock 0.3.0 on crates.io.
  """
  @spec crate_version() :: String.t()
  def crate_version, do: Native.crate_version()
end
