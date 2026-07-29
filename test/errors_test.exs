defmodule ExTrafilatura.ErrorsTest.Document do
  @moduledoc false
  # Builds the fixtures below, so that each one shows only the part that decides
  # the error it is named for. A module rather than a private function because
  # the fixtures are module attributes, which are built before the test module
  # has any functions of its own.

  # Deliberately over ~250 characters, and unambiguously English: two of the
  # fixtures below turn on what the crate's language classifier makes of this
  # text, and a shorter or more ambiguous body would make that undetectable
  # rather than wrong.
  @body """
  <p>The first paragraph of the article body, long enough that extraction keeps
  it as main content rather than discarding it as a stray fragment of the page
  furniture that surrounds it.</p>
  <p>A second paragraph, so the article carries enough substance for the
  extractor to settle on this subtree rather than falling through to a rescue
  pass over the whole document.</p>
  """

  @doc "An article whose `<head>` carries what is given and nothing else."
  def article(head \\ "") do
    """
    <!DOCTYPE html>
    <html lang="en">
      <head>#{head}</head>
      <body><article>#{@body}</article></body>
    </html>
    """
  end
end

defmodule ExTrafilatura.ErrorsTest do
  use ExUnit.Case, async: true

  import ExTrafilatura.ErrorsTest.Document
  import ExUnit.CaptureLog

  # Handwritten minimal HTML only (ADR-0003 §3). Each fixture reaches exactly
  # one of the crate's error variants, and asserts on the whole term rather than
  # on its tag — the payload is the part the mapping can get wrong.
  #
  # Two of the seven reasons are unreachable from here. `{:unknown, _}` needs a
  # variant nothing constructs and `{:panic, _}` a panic the vendored crate is
  # patched to prevent, so both are exercised in `native/` instead (ADR-0006
  # "Consequences"). The Elixir half of the panic guard — the `Logger.error` —
  # is reachable, and is the last `describe` below.

  @title "<title>A minimal article</title>"
  @canonical ~s(<link rel="canonical" href="https://journal.example.com/an-article">)
  @published ~s(<meta property="article:published_time" content="2026-03-09">)

  describe ":insufficient_content" do
    test "an empty document is an error, not an empty result" do
      assert ExTrafilatura.extract("<html><body></body></html>") ==
               {:error, :insufficient_content}
    end

    test "a titled stub loses the title along with everything else" do
      # This pins ADR-0006 §5's *limitation*, not its fix. The crate returns
      # before it builds a result, dropping metadata it had already extracted —
      # so a document that genuinely carries a title, an author and an image
      # comes back carrying none of them. Normalising to
      # `{:ok, %Result{title: nil}}` would assert this document had no title,
      # which is false; the error asserts only that nothing came back, which is
      # true. If the vendored crate is ever patched to return a partial result,
      # this test is what notices.
      #
      # The title is an `og:title` rather than a `<title>`, which is load-bearing
      # and not a stylistic choice: the crate's last-resort baseline pass falls
      # back to the *whole document's* text, so a `<title>` element's text is
      # itself enough content to extract, and the document would come back
      # `{:ok, _}` with its own title for a body.
      stub = """
      <html>
        <head>
          <meta property="og:title" content="A stub with nothing under it">
          <meta property="og:image" content="https://journal.example.com/cover.png">
          <meta name="author" content="Ada Lovelace">
        </head>
        <body></body>
      </html>
      """

      assert ExTrafilatura.extract(stub) == {:error, :insufficient_content}
    end
  end

  describe "{:missing_metadata, field}" do
    test "title, then url, then date — the crate's own checking order" do
      # One document per step, each supplying what the step before demanded, so
      # the three assertions together pin the order rather than the set. The
      # payload is an atom, not the crate's `"title"`: the set is closed at
      # three by construction (ADR-0006 §4).
      assert ExTrafilatura.extract(article(), has_essential_metadata: true) ==
               {:error, {:missing_metadata, :title}}

      assert ExTrafilatura.extract(article(@title), has_essential_metadata: true) ==
               {:error, {:missing_metadata, :url}}

      assert ExTrafilatura.extract(article(@title <> @canonical), has_essential_metadata: true) ==
               {:error, {:missing_metadata, :date}}
    end

    test "a document carrying all three extracts, so the option is what refused the others" do
      html = article(@title <> @canonical <> @published)

      assert {:ok, _} = ExTrafilatura.extract(html, has_essential_metadata: true)
    end
  end

  describe "{:language_mismatch, language}" do
    test "nil when the document's own declaration decided it, before extraction ran" do
      # The early construction site: the crate checks the document's declared
      # language and returns without ever classifying any text, so there is no
      # detected language to carry. `nil` is "could not determine".
      html = article(~s(<meta http-equiv="content-language" content="de">))

      assert ExTrafilatura.extract(html, target_language: "en") ==
               {:error, {:language_mismatch, nil}}
    end

    test "the detected language when the extracted text decided it" do
      # The late construction site: the document declares nothing, extraction
      # runs, and the classifier's verdict on the extracted text is the payload.
      # A binary is "determined, and wrong" — the distinction the two sites
      # carry, and the reason this reason is not a bare atom.
      assert ExTrafilatura.extract(article(), target_language: "de") ==
               {:error, {:language_mismatch, "en"}}
    end

    test "the caller's own target language is not echoed back" do
      # Two different targets against the same document differ only in what the
      # caller already holds, so both terms are identical. Guards against the
      # crate's `expected` field creeping back into the payload.
      assert ExTrafilatura.extract(article(), target_language: "de") ==
               ExTrafilatura.extract(article(), target_language: "fr")
    end
  end

  describe "{:panic, message}" do
    # The half of the guard that lives in Elixir. Reaching it through
    # `extract/2` would take a panic the vendored crate is patched to prevent,
    # so it is called directly here — which is the whole reason it is a function
    # on a module of its own rather than a clause inside `extract/2`.

    test "a panic is logged, naming the crate and pointing at the tracker" do
      panicked = {:error, {:panic, "index out of bounds: the len is 8 but the index is 9"}}

      log = capture_log(fn -> assert ExTrafilatura.Panic.report(panicked) == panicked end)

      assert log =~ "[error]"
      assert log =~ "trafilatura"
      assert log =~ "index out of bounds"
      assert log =~ "github.com/bravely/ex_trafilatura/issues"
    end

    test "every other result passes through in silence" do
      # The noise is the point *for a panic*, and only for a panic — a page with
      # no article on it is routine and must not log (ADR-0006 §7).
      log =
        capture_log(fn ->
          assert ExTrafilatura.Panic.report({:error, :insufficient_content}) ==
                   {:error, :insufficient_content}
        end)

      refute log =~ "panicked"
    end
  end
end
