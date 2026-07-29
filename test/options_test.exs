defmodule ExTrafilatura.OptionsTest.Document do
  @moduledoc false
  # Builds the fixtures below, so that each one shows only the part that the
  # option under test moves. A module rather than a private function because
  # the fixtures are module attributes, which are built before the test module
  # has any functions of its own.

  # Deliberately over ~250 characters: below the crate's `min_extracted_size` a
  # second, baseline pass rescues the document and the option under test stops
  # being the only variable.
  @body """
  <p>The first paragraph of the article body, long enough that extraction keeps
  it as main content rather than discarding it as a stray fragment of the page
  furniture that surrounds it.</p>
  <p>A second paragraph, so the article carries enough substance for the
  extractor to settle on this subtree rather than falling through to a rescue
  pass over the whole document.</p>
  """

  def body, do: @body

  @doc "An article, with `body` for its content unless something else is given."
  def article(body \\ @body, head \\ ""), do: page("<article>#{body}</article>", head)

  @doc "A whole `<body>`, for the fixtures whose point is what sits outside the article."
  def page(body, head \\ "") do
    """
    <!DOCTYPE html>
    <html lang="en">
      <head><title>A minimal article</title>#{head}</head>
      <body>#{body}</body>
    </html>
    """
  end
end

defmodule ExTrafilatura.OptionsTest do
  use ExUnit.Case, async: true

  import ExTrafilatura.OptionsTest.Document

  # Handwritten minimal HTML only (ADR-0003 §3). Each fixture is built so that
  # exactly one option moves exactly one thing about the output — an option that
  # silently did nothing would show up here as two identical results.

  @article article()

  describe "extract/1 is the crate's default call" do
    test "the crate's own documented example extracts to what the crate documents" do
      # Borrowed verbatim from the crate's `extract` doc comment, which runs
      # `extract(html, &Options::default())`. It transfers only because
      # `extract/1` is *defined* to be that call — this test is what makes
      # borrowing expectations from upstream legitimate (ADR-0003 §1).
      html = "<html><body><article><p>Hello world</p></article></body></html>"

      assert {:ok, result} = ExTrafilatura.extract(html)
      assert result.content_text == "Hello world"
    end

    test "an empty option list is the same call as no option list" do
      assert ExTrafilatura.extract(@article) == ExTrafilatura.extract(@article, [])
    end

    test "spelling out every key at the crate's own default changes nothing" do
      # The defaults are not ours to choose: passing each one explicitly must be
      # indistinguishable from passing nothing. If we ever defaulted a knob on,
      # this is the test that fails.
      defaults = [
        focus: :balanced,
        exclude_comments: false,
        exclude_tables: false,
        include_links: false,
        include_images: false,
        enable_fallback: false,
        target_language: nil,
        has_essential_metadata: false,
        original_url: nil,
        prune_selector: nil,
        excluded_authors: [],
        html_date_override: nil
      ]

      assert ExTrafilatura.extract(@article, defaults) == ExTrafilatura.extract(@article)
    end
  end

  describe "focus" do
    # `focus` is one enum in the crate, not two booleans, and each of its three
    # values prunes a different amount: recall keeps teasers, precision drops
    # link-heavy trailing blocks that balanced keeps.
    @focus article("""
           <div class="teaser"><p>A teaser blurb that balanced and precision modes
           both discard as page furniture.</p></div>
           #{body()}
           <div class="bottom-links"><p>Trailing link bait that only precision mode
           discards.</p></div>
           """)

    test ":favor_recall keeps a teaser that :balanced discards" do
      assert {:ok, balanced} = ExTrafilatura.extract(@focus)
      assert {:ok, recall} = ExTrafilatura.extract(@focus, focus: :favor_recall)

      refute balanced.content_text =~ "A teaser blurb"
      assert recall.content_text =~ "A teaser blurb"
    end

    test ":favor_precision discards a trailing link block that :balanced keeps" do
      assert {:ok, balanced} = ExTrafilatura.extract(@focus)
      assert {:ok, precision} = ExTrafilatura.extract(@focus, focus: :favor_precision)

      assert balanced.content_text =~ "Trailing link bait"
      refute precision.content_text =~ "Trailing link bait"
    end
  end

  describe "exclude_comments" do
    @commented page("""
               <article>#{body()}</article>
               <div id="comments">
                 <div class="comment"><p>A reader comment long enough to survive the
                 extractor's minimum length checks on the comments stream.</p></div>
               </div>
               """)

    test "comments are included by default and excluded when asked" do
      # The sense is the crate's, and it is the inverted one: the default is
      # `false`, so comments arrive unless the caller says otherwise.
      assert {:ok, included} = ExTrafilatura.extract(@commented)
      assert {:ok, excluded} = ExTrafilatura.extract(@commented, exclude_comments: true)

      assert included.comments_text =~ "A reader comment"
      assert excluded.comments_text == ""
    end
  end

  describe "exclude_tables" do
    @tabled article("""
            #{body()}
            <table><tr><td>A cell of tabular content.</td></tr></table>
            """)

    test "tables are kept by default and dropped when asked" do
      assert {:ok, kept} = ExTrafilatura.extract(@tabled)
      assert {:ok, dropped} = ExTrafilatura.extract(@tabled, exclude_tables: true)

      assert kept.content_text =~ "A cell of tabular content"
      refute dropped.content_text =~ "A cell of tabular content"
    end
  end

  describe "include_links" do
    @linked article("""
            #{body()}
            <p>A paragraph carrying <a href="/elsewhere">a hyperlink</a> inside it.</p>
            """)

    test "anchors are stripped from the HTML stream by default and kept when asked" do
      assert {:ok, stripped} = ExTrafilatura.extract(@linked)
      assert {:ok, kept} = ExTrafilatura.extract(@linked, include_links: true)

      refute stripped.content_html =~ "<a"
      assert kept.content_html =~ "<a"
      assert kept.content_html =~ "/elsewhere"
    end
  end

  describe "include_images" do
    @imaged article("""
            #{body()}
            <p><img src="/diagram.png" alt="A diagram"></p>
            """)

    test "images are stripped from the HTML stream by default and kept when asked" do
      assert {:ok, stripped} = ExTrafilatura.extract(@imaged)
      assert {:ok, kept} = ExTrafilatura.extract(@imaged, include_images: true)

      refute stripped.content_html =~ "<img"
      assert kept.content_html =~ "/diagram.png"
    end
  end

  describe "enable_fallback" do
    # The crate's default is fallback *off*, unlike Python trafilatura's. The
    # second pass runs readability and justext over a copy of the document and
    # keeps whichever result it judges better, so it shows up on a document
    # whose main content the primary pass declines to find.
    @unstructured page("""
                  <div id="wrapper">
                    <div><span>Body text held in spans inside anonymous divs, which the
                    primary pass has no content selector for, but which a readability-style
                    scoring pass will happily recover as the main content of the page.</span></div>
                    <div><span>A second span-wrapped block, so there is enough text here for
                    the fallback pass to score this subtree above the rest of the page.</span></div>
                  </div>
                  """)

    test "the fallback pass changes what comes back" do
      assert {:ok, without} = ExTrafilatura.extract(@unstructured)
      assert {:ok, with_fallback} = ExTrafilatura.extract(@unstructured, enable_fallback: true)

      refute with_fallback.content_html == without.content_html
    end
  end

  describe "target_language" do
    test "a document that does not match the target is refused" do
      assert {:ok, _} = ExTrafilatura.extract(@article)
      assert {:error, _} = ExTrafilatura.extract(@article, target_language: "zh")
    end
  end

  describe "has_essential_metadata" do
    test "a document missing an essential field is refused" do
      # `@article` has a title but neither a URL nor a date.
      assert {:ok, _} = ExTrafilatura.extract(@article)
      assert {:error, _} = ExTrafilatura.extract(@article, has_essential_metadata: true)
    end
  end

  describe "original_url" do
    test "supplies the URL, and the hostname derived from it, that the document lacks" do
      assert {:ok, without} = ExTrafilatura.extract(@article)
      assert without.metadata.url == nil
      assert without.metadata.hostname == nil

      assert {:ok, with_url} =
               ExTrafilatura.extract(@article, original_url: "https://example.com/an-article")

      assert with_url.metadata.url == "https://example.com/an-article"
      assert with_url.metadata.hostname == "example.com"
    end
  end

  describe "prune_selector" do
    # The fixture is the crate's own `test_extract_prune_selector`, which is
    # borrowable for the same reason the doc example above is.
    @sidebarred page("""
                <article>#{body()}</article>
                <div class="sidebar"><p>Remove this sidebar text.</p></div>
                """)

    test "removes the matched elements before extraction runs" do
      assert {:ok, pruned} = ExTrafilatura.extract(@sidebarred, prune_selector: ".sidebar")

      refute pruned.content_text =~ "Remove this sidebar"
      assert pruned.content_text =~ "The first paragraph"
    end
  end

  describe "excluded_authors" do
    @authored article(body(), ~s(<meta name="author" content="Ada Lovelace">))

    test "drops a named author from the metadata" do
      assert {:ok, kept} = ExTrafilatura.extract(@authored)
      assert kept.metadata.author == "Ada Lovelace"

      assert {:ok, dropped} = ExTrafilatura.extract(@authored, excluded_authors: ["Ada Lovelace"])

      assert dropped.metadata.author == nil
    end
  end

  describe "html_date_override" do
    @dated article(body(), ~s(<meta property="article:published_time" content="2026-03-09">))

    test "replaces the date the document declares" do
      assert {:ok, extracted} = ExTrafilatura.extract(@dated)
      assert extracted.metadata.date == ~D[2026-03-09]

      assert {:ok, overridden} = ExTrafilatura.extract(@dated, html_date_override: ~D[1999-12-31])

      assert overridden.metadata.date == ~D[1999-12-31]
    end
  end

  describe "unknown keys" do
    test "are silently ignored" do
      # Tolerated so that passing a superset from a caller's own config never
      # crashes. The accepted cost is that `exclude_comment:` is undiscoverable
      # except by noticing the wrong output.
      assert ExTrafilatura.extract(@article, exclude_comment: true, nonsense: %{}) ==
               ExTrafilatura.extract(@article)
    end

    test "are ignored even when their value would be invalid for a key we know" do
      # The value of a key we do not have is never looked at, so it cannot be
      # wrong. `focus` next to it still is.
      assert ExTrafilatura.extract(@article, focu: :sideways) ==
               ExTrafilatura.extract(@article)
    end
  end

  describe "the struct that crosses the boundary" do
    test "carries all twelve fields whatever the caller named" do
      for opts <- [[], [focus: :favor_recall], [nonsense: 1], [:not_a_keyword_list]] do
        overrides = ExTrafilatura.Options.normalize(opts)

        assert %ExTrafilatura.Options{} = overrides
        assert overrides |> Map.from_struct() |> map_size() == 12
      end
    end

    test "is refused by the NIF if a field goes missing" do
      # Why the shape is a struct rather than a bare map. `Overrides` on the
      # Rust side reads every field, so a key that is merely *absent* is a
      # decode failure there rather than a `None`, and it comes back as a bare
      # `ArgumentError` naming nothing — none of the attribution the errors
      # above carry. A struct puts that out of reach: this test has to take a
      # field back off to reach it at all.
      overrides = ExTrafilatura.Options.normalize([])

      assert {:ok, _} = ExTrafilatura.Native.extract(@article, overrides)

      assert_raise ArgumentError, fn ->
        ExTrafilatura.Native.extract(@article, Map.delete(overrides, :prune_selector))
      end
    end
  end

  describe "repeated keys" do
    test "take the first, as Keyword.fetch/2 does" do
      assert ExTrafilatura.extract(@focus, focus: :favor_recall, focus: :balanced) ==
               ExTrafilatura.extract(@focus, focus: :favor_recall)
    end
  end

  describe "invalid values" do
    # Exceptions mean exactly one thing here: you called it wrong. Every one of
    # these is a caller mistake, and none of them can arrive from the network.

    test "a focus outside the enum raises" do
      assert_raise ArgumentError, fn -> ExTrafilatura.extract(@article, focus: :favour_recall) end
    end

    test "a non-boolean for a boolean key raises" do
      for key <- [
            :exclude_comments,
            :exclude_tables,
            :include_links,
            :include_images,
            :enable_fallback,
            :has_essential_metadata
          ] do
        assert_raise ArgumentError, fn -> ExTrafilatura.extract(@article, [{key, :yes}]) end
      end
    end

    test "a non-binary for a binary key raises" do
      for key <- [:target_language, :original_url, :prune_selector] do
        assert_raise ArgumentError, fn -> ExTrafilatura.extract(@article, [{key, :en}]) end
      end
    end

    test "an original_url with no scheme raises" do
      # A relative URL cannot be the base that the document's relative links
      # resolve against, and the crate refuses one too.
      for url <- ["/relative", "example.com/no-scheme", "not a url at all"] do
        assert_raise ArgumentError, fn -> ExTrafilatura.extract(@article, original_url: url) end
      end
    end

    test "an original_url the crate would accept is not narrowed further" do
      # `file:` and `mailto:` parse as `url::Url`, so they are not ours to
      # refuse — what the crate takes, we take.
      for url <- ["file:///tmp/an-article.html", "mailto:ada@example.com"] do
        assert {:ok, _} = ExTrafilatura.extract(@article, original_url: url)
      end
    end

    test "nil is a value only for the four keys whose default is nil" do
      for key <- [:target_language, :original_url, :prune_selector, :html_date_override] do
        assert ExTrafilatura.extract(@article, [{key, nil}]) == ExTrafilatura.extract(@article)
      end

      for key <- [
            :focus,
            :exclude_comments,
            :exclude_tables,
            :include_links,
            :include_images,
            :enable_fallback,
            :has_essential_metadata,
            :excluded_authors
          ] do
        assert_raise ArgumentError, fn -> ExTrafilatura.extract(@article, [{key, nil}]) end
      end
    end

    test "excluded_authors that is not a list of binaries raises" do
      assert_raise ArgumentError, fn ->
        ExTrafilatura.extract(@article, excluded_authors: "Ada Lovelace")
      end

      assert_raise ArgumentError, fn ->
        ExTrafilatura.extract(@article, excluded_authors: ["Ada Lovelace", :grace_hopper])
      end
    end

    test "an html_date_override that is not a Date raises" do
      assert_raise ArgumentError, fn ->
        ExTrafilatura.extract(@article, html_date_override: "1999-12-31")
      end
    end

    test "something that is not a list at all raises" do
      # A map is the likely mistake here, and the one worth a message.
      for opts <- [%{focus: :balanced}, "focus", :focus] do
        assert_raise ArgumentError, fn -> ExTrafilatura.extract(@article, opts) end
      end
    end

    test "a list that is not a keyword list names no options, as it does to Keyword.get/3" do
      # The consequence of building the map from the twelve known keys rather
      # than from what the caller passed: a list we can find no key in is the
      # same as an empty one. Pinned because it is a silent outcome, not
      # because it is a good one to rely on.
      assert ExTrafilatura.extract(@article, [:focus]) == ExTrafilatura.extract(@article)
    end

    test "the message names the key that was wrong" do
      assert_raise ArgumentError, ~r/:focus/, fn ->
        ExTrafilatura.extract(@article, focus: :sideways)
      end
    end
  end
end
