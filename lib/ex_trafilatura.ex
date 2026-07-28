defmodule ExTrafilatura do
  @moduledoc """
  Main content and metadata extraction for web pages, binding the Rust
  `trafilatura` crate over a NIF.
  """

  alias ExTrafilatura.Native
  alias ExTrafilatura.Result

  @doc """
  Extracts the main content and metadata of an HTML document.

  Uses the crate's default options. Note that these are the *crate's* defaults,
  not Python trafilatura's — the fallback pass is off, and comments are included.

      {:ok, result} = ExTrafilatura.extract(html)
      result.content_text
      result.metadata.title

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
  """
  @spec extract(binary()) :: {:ok, Result.t()} | {:error, {:unknown, String.t()}}
  def extract(html) when is_binary(html), do: Native.extract(html)

  @doc """
  The version of the vendored `trafilatura` crate this build extracts with.

  The `+extrafilatura.N` build-metadata marker distinguishes our patched copy
  from stock 0.3.0 on crates.io.
  """
  @spec crate_version() :: String.t()
  def crate_version, do: Native.crate_version()
end
