defmodule ExTrafilaturaTest do
  use ExUnit.Case, async: true

  doctest ExTrafilatura

  # Handwritten minimal HTML only — no real pages, no golden snapshots of
  # extraction output (ADR-0003 §3).
  @article """
  <!DOCTYPE html>
  <html lang="en">
    <head>
      <title>A minimal article</title>
    </head>
    <body>
      <nav><a href="/">Home</a> <a href="/about">About us</a></nav>
      <article>
        <p>The first paragraph of the article body, long enough that extraction
        keeps it as main content rather than discarding it as a stray fragment.</p>
        <p>A second paragraph, so the article carries enough substance for the
        extractor to settle on this subtree rather than on something else.</p>
      </article>
      <footer>Copyright 2026. All rights reserved.</footer>
    </body>
  </html>
  """

  @documented """
  <!DOCTYPE html>
  <html lang="en">
    <head>
      <title>How extraction picks a title</title>
      <meta name="author" content="Ada Lovelace">
      <meta name="description" content="A short summary of the article.">
      <meta name="keywords" content="extraction, boilerplate">
      <meta property="og:site_name" content="The Example Journal">
      <meta property="og:url" content="https://journal.example.com/picking-a-title">
      <meta property="og:image" content="https://journal.example.com/cover.png">
      <meta property="og:type" content="article">
      <meta property="article:published_time" content="2026-03-09">
    </head>
    <body>
      <article>
        <p>A document that carries its descriptive fields in meta tags, so that
        every one of them has a single unambiguous source in this fixture.</p>
        <p>A second paragraph, so the article carries enough substance for the
        extractor to settle on this subtree rather than on something else.</p>
      </article>
    </body>
  </html>
  """

  describe "extract/1" do
    test "carries the main content back across the NIF boundary, as text and as HTML" do
      # What this pins is ours: that both content streams cross intact and land
      # in the right field. *Which* blocks the crate judges to be main content
      # rather than boilerplate is upstream's contract, so there is no assertion
      # about the nav or the footer here — that is what the differential harness
      # covers, across 925 pages rather than one (ADR-0003 §3).
      assert {:ok, result} = ExTrafilatura.extract(@article)

      assert result.content_text =~ "The first paragraph"
      assert result.content_text =~ "A second paragraph"

      assert result.content_html =~ "The first paragraph"
      assert result.content_html =~ "<p>"
    end

    test "carries metadata nested under the result, each field in its own slot" do
      # The boundary this owns is the 13-field mapping: every descriptive field
      # the crate gathered arrives under the name the crate gives it, nested
      # rather than flattened, and `date` arrives as a `Date` rather than
      # something to parse. `@documented` gives each field a single unambiguous
      # source so a crossed pair of slots would show up as a wrong value rather
      # than a missing one.
      assert {:ok, result} = ExTrafilatura.extract(@documented)

      assert %ExTrafilatura.Result{metadata: %ExTrafilatura.Metadata{} = metadata} = result

      assert metadata.title == "How extraction picks a title"
      assert metadata.author == "Ada Lovelace"
      assert metadata.description == "A short summary of the article."
      assert metadata.sitename == "The Example Journal"
      assert metadata.url == "https://journal.example.com/picking-a-title"
      assert metadata.hostname == "journal.example.com"
      assert metadata.image == "https://journal.example.com/cover.png"
      assert metadata.page_type == "article"
      assert metadata.language == "en"
      assert metadata.date == ~D[2026-03-09]
      assert metadata.tags == ["extraction", "boilerplate"]
    end

    test "absence is nil on metadata and an empty binary on the streams" do
      # `@article` declares a title and nothing else, and has no comments — so
      # one document exercises both rules at once and pins them against each
      # other. The crate reports every one of these as `""`; which of them
      # reaches the caller as `nil` is our decision, not the crate's.
      assert {:ok, result} = ExTrafilatura.extract(@article)

      assert result.metadata.title == "A minimal article"

      assert result.metadata.author == nil
      assert result.metadata.description == nil
      assert result.metadata.sitename == nil
      assert result.metadata.url == nil
      assert result.metadata.hostname == nil
      assert result.metadata.image == nil
      assert result.metadata.license == nil
      assert result.metadata.page_type == nil
      assert result.metadata.date == nil

      assert result.comments_text == ""
      assert result.comments_html == ""

      assert result.metadata.categories == []
      assert result.metadata.tags == []
    end

    test "omits the two metadata fields the crate never assigns" do
      assert {:ok, result} = ExTrafilatura.extract(@documented)

      fields = result.metadata |> Map.from_struct() |> Map.keys()

      assert length(fields) == 13
      refute :id in fields
      refute :fingerprint in fields
    end
  end

  describe "crate_version/0" do
    test "reports the vendored crate's version marker" do
      assert ExTrafilatura.crate_version() == "0.3.0+extrafilatura.1"
    end
  end
end
