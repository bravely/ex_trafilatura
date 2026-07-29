defmodule ExTrafilatura.Panic do
  @moduledoc false
  # The Elixir half of the panic guard. The Rust half is a `catch_unwind` inside
  # the NIF body, which recovers the message Rustler discards and hands back
  # `{:error, {:panic, message}}`; this is what stops that term being silent.
  #
  # Demoting a panic to an `{:error, _}` drops a crate bug into the same `case`
  # clause as "no article on this page", where a `_ -> :skip` buries it forever.
  # The `Logger.error` is what answers that: #11 declined per-call log noise for
  # option typos, which are routine, but a panic is not routine, and here the
  # noise is the point (ADR-0006 §7).
  #
  # A module of its own rather than a clause inside `ExTrafilatura.extract/2`,
  # because reaching it through `extract/2` needs a panic the vendored crate is
  # patched to prevent. Untestable logging is logging that can be silently
  # broken; this way the fixture calls it directly.

  require Logger

  @tracker "https://github.com/bravely/ex_trafilatura/issues"

  @doc "Logs an extraction that panicked, and returns the result either way."
  @spec report(result) :: result when result: {:ok, term()} | {:error, term()}
  def report({:error, {:panic, message}} = result) do
    Logger.error("""
    ExTrafilatura: the vendored `trafilatura` crate panicked mid-extraction.

        #{message}

    Extraction returned `{:error, {:panic, message}}` rather than taking the \
    calling process down, so this is the only notice of it. It is a bug in the \
    crate, not in the document — please report it at #{@tracker}, with the \
    document that triggered it if you are able to share one.\
    """)

    result
  end

  def report(result), do: result
end
