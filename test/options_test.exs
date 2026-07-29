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
    test "raise, naming the key and what was valid" do
      # This reverses #11 §7, which had them silently ignored and accepted that
      # a typo'd key was undiscoverable except by noticing the wrong output.
      # The typo is the whole point: `exclude_comment:` is one character from a
      # real key and would otherwise change nothing and say nothing.
      error =
        assert_raise NimbleOptions.ValidationError, fn ->
          ExTrafilatura.extract(@article, exclude_comment: true)
        end

      assert Exception.message(error) =~ "unknown options [:exclude_comment]"
      assert Exception.message(error) =~ ":exclude_comments"
    end

    test "raise whatever their value would have been" do
      assert_raise NimbleOptions.ValidationError, fn ->
        ExTrafilatura.extract(@article, nonsense: %{})
      end
    end

    test "cost a caller who keeps our options alongside their own a Keyword.take/2" do
      # The accepted price of the reversal, pinned so it is a known shape of
      # caller code rather than a surprise.
      theirs = [focus: :favor_recall, retries: 3]

      assert_raise NimbleOptions.ValidationError, fn ->
        ExTrafilatura.extract(@article, theirs)
      end

      assert {:ok, _} = ExTrafilatura.extract(@article, Keyword.take(theirs, [:focus]))
    end
  end

  describe "max_input_bytes" do
    # The thirteenth key and the one non-crate key in the surface: ours, not
    # upstream's, and the only one carrying a default of our own (ADR-0001 §2).

    test "defaults to 10 MB" do
      # The figure ADR-0001 §1 chose, asserted at the seam rather than by
      # feeding 10 MB through the gate. Moving it is a decision rather than a
      # tweak, which is what this test is here to make someone notice.
      assert {max_input_bytes, %ExTrafilatura.Options{}} = ExTrafilatura.Options.normalize([])
      assert max_input_bytes == 10 * 1024 * 1024
    end

    test "the caller's value replaces it, :infinity included" do
      assert {512, _} = ExTrafilatura.Options.normalize(max_input_bytes: 512)
      assert {:infinity, _} = ExTrafilatura.Options.normalize(max_input_bytes: :infinity)
    end

    test "never reaches the NIF" do
      # It is consumed in Elixir, so it must not appear in the struct the Rust
      # side decodes — `Overrides` there names twelve fields and would refuse a
      # thirteenth. This is the seam: the schema validates all thirteen keys,
      # and exactly one of them is split back off before the boundary.
      {_max_input_bytes, overrides} = ExTrafilatura.Options.normalize(max_input_bytes: 512)

      refute Map.has_key?(overrides, :max_input_bytes)
      assert {:ok, _} = ExTrafilatura.Native.extract(@article, overrides)
    end

    test "a value that is neither a positive byte count nor :infinity raises" do
      for value <- [0, -1, "10", 1.5, nil, :unlimited] do
        assert_raise NimbleOptions.ValidationError, ~r/:max_input_bytes/, fn ->
          ExTrafilatura.extract(@article, max_input_bytes: value)
        end
      end
    end
  end

  describe "the struct that crosses the boundary" do
    test "carries all twelve fields whatever the caller named" do
      for opts <- [[], [focus: :favor_recall], [include_links: true, include_images: true]] do
        {_max_input_bytes, overrides} = ExTrafilatura.Options.normalize(opts)

        assert %ExTrafilatura.Options{} = overrides
        assert overrides |> Map.from_struct() |> map_size() == 12
      end
    end

    test "leaves every field nil when given nothing" do
      # The guard on the schema. Its entries must never carry `default:` — the
      # defaults belong to the crate, and a key the caller did not name has to
      # arrive as `nil` so that nothing is assigned over `Options::default()`.
      # A default declared here would be invisible whenever it happened to
      # match the crate's, so this asserts the absence rather than the values.
      # `max_input_bytes` is exempt and is not in the struct to be checked: its
      # default is ours to choose, because the crate has no such option.
      {_max_input_bytes, overrides} = ExTrafilatura.Options.normalize([])

      for {field, value} <- Map.from_struct(overrides) do
        assert value == nil, "#{inspect(field)} arrived as #{inspect(value)}, not nil"
      end
    end

    test "is refused by the NIF if a field goes missing" do
      # Why the shape is a struct rather than a bare map. `Overrides` on the
      # Rust side reads every field, so a key that is merely *absent* is a
      # decode failure there rather than a `None`, and it comes back as a bare
      # `ArgumentError` naming nothing — none of the attribution the errors
      # above carry. A struct puts that out of reach: this test has to take a
      # field back off to reach it at all.
      {_max_input_bytes, overrides} = ExTrafilatura.Options.normalize([])

      assert {:ok, _} = ExTrafilatura.Native.extract(@article, overrides)

      assert_raise ArgumentError, fn ->
        ExTrafilatura.Native.extract(@article, Map.delete(overrides, :prune_selector))
      end
    end
  end

  describe "repeated keys" do
    test "raise, rather than one of them silently winning" do
      # A consequence of refusing unknown keys, and a welcome one — naming an
      # option twice is a caller mistake, and neither first-wins nor last-wins
      # would have said so.
      #
      # The message is the wart: the schema takes the first occurrence and
      # reports the leftover as unknown, so the key is named as *both* unknown
      # and valid in one sentence. Pinned because a caller who hits it will be
      # baffled, and because it is the schema's wording rather than ours to fix.
      error =
        assert_raise NimbleOptions.ValidationError, fn ->
          ExTrafilatura.extract(@focus, focus: :favor_recall, focus: :balanced)
        end

      assert Exception.message(error) =~ "unknown options [:focus]"
    end
  end

  describe "invalid values" do
    # Exceptions mean exactly one thing here: you called it wrong. Every one of
    # these is a caller mistake, and none of them can arrive from the network.

    test "a focus outside the enum raises" do
      assert_raise NimbleOptions.ValidationError, fn ->
        ExTrafilatura.extract(@article, focus: :favour_recall)
      end
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
        assert_raise NimbleOptions.ValidationError, fn ->
          ExTrafilatura.extract(@article, [{key, :yes}])
        end
      end
    end

    test "a non-binary for a binary key raises" do
      for key <- [:target_language, :original_url, :prune_selector] do
        assert_raise NimbleOptions.ValidationError, fn ->
          ExTrafilatura.extract(@article, [{key, :en}])
        end
      end
    end

    test "an original_url with no scheme raises" do
      # A relative URL cannot be the base that the document's relative links
      # resolve against, and the crate refuses one too.
      for url <- ["/relative", "example.com/no-scheme", "not a url at all"] do
        assert_raise NimbleOptions.ValidationError, fn ->
          ExTrafilatura.extract(@article, original_url: url)
        end
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
            :excluded_authors,
            # Ours rather than the crate's, and the one where `nil` is the
            # plausible mistake: it is not how the cap is removed. `:infinity`
            # is.
            :max_input_bytes
          ] do
        assert_raise NimbleOptions.ValidationError, fn ->
          ExTrafilatura.extract(@article, [{key, nil}])
        end
      end
    end

    test "excluded_authors that is not a list of binaries raises" do
      assert_raise NimbleOptions.ValidationError, fn ->
        ExTrafilatura.extract(@article, excluded_authors: "Ada Lovelace")
      end

      assert_raise NimbleOptions.ValidationError, fn ->
        ExTrafilatura.extract(@article, excluded_authors: ["Ada Lovelace", :grace_hopper])
      end
    end

    test "an html_date_override that is not a Date raises" do
      assert_raise NimbleOptions.ValidationError, fn ->
        ExTrafilatura.extract(@article, html_date_override: "1999-12-31")
      end
    end

    test "something that is not a list at all does not match the function head" do
      # `extract/2` guards on `is_list/1`, so this never reaches the schema.
      # That is what keeps one kind of mistake to one kind of exception: a
      # wrong *type* for `opts` is a `FunctionClauseError`, exactly as it would
      # be for any other guarded argument, and a wrong *option* is always a
      # `NimbleOptions.ValidationError`.
      for opts <- [%{focus: :balanced}, "focus", :focus] do
        assert_raise FunctionClauseError, fn -> ExTrafilatura.extract(@article, opts) end
      end
    end

    test "a list that is not a keyword list raises" do
      assert_raise ArgumentError, ~r/expected a keyword list/, fn ->
        ExTrafilatura.extract(@article, [:focus])
      end
    end

    test "the message names the key that was wrong" do
      assert_raise NimbleOptions.ValidationError, ~r/:focus/, fn ->
        ExTrafilatura.extract(@article, focus: :sideways)
      end
    end
  end
end
