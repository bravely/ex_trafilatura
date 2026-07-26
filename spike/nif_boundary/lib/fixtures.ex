defmodule Fixtures do
  @moduledoc """
  THROWAWAY SPIKE — see README.md.

  Synthetic pages. The 925-page ground-truth corpus belongs to go-trafilatura and
  is not in this repo, so these stand in. They are shaped like a real article page
  — meta tags, nav, sidebar, article body, comments, footer — because what we are
  measuring is the *ratio* of encode cost to extract cost, not absolute accuracy.
  """

  @lorem "The quick brown fox jumps over the lazy dog while the extraction " <>
           "algorithm decides whether this paragraph is main content or boilerplate. "

  @doc "A realistic article page. `paras` controls the body size."
  def article(paras \\ 40, opts \\ []) do
    date = Keyword.get(opts, :date, "2026-03-14")
    title = Keyword.get(opts, :title, "How Content Extraction Actually Works")

    body =
      for i <- 1..paras do
        "<p>Paragraph #{i}. #{String.duplicate(@lorem, 3)}</p>"
      end
      |> Enum.join("\n")

    """
    <!DOCTYPE html>
    <html lang="en">
    <head>
      <meta charset="utf-8">
      <title>#{title}</title>
      <meta property="og:title" content="#{title}">
      <meta name="author" content="Ada Lovelace">
      <meta property="article:published_time" content="#{date}">
      <meta name="description" content="A walkthrough of main content versus boilerplate.">
      <meta property="og:site_name" content="Extraction Weekly">
      <meta property="og:url" content="https://example.com/how-extraction-works">
      <meta property="og:image" content="https://example.com/hero.png">
      <meta property="og:type" content="article">
      <meta name="keywords" content="extraction, html, parsing">
    </head>
    <body>
      <nav><ul><li><a href="/">Home</a></li><li><a href="/about">About</a></li></ul></nav>
      <header><h1>#{title}</h1></header>
      <aside class="sidebar">
        <h3>Related posts</h3>
        <ul>#{String.duplicate("<li><a href=\"/x\">Another post you might like</a></li>", 12)}</ul>
      </aside>
      <article>
        #{body}
      </article>
      <section id="comments">
        <div class="comment"><p>Great write-up, this cleared up the precision/recall tradeoff for me.</p></div>
        <div class="comment"><p>Does this handle paywalled pages? Asking for a friend.</p></div>
      </section>
      <footer><p>&copy; 2026 Extraction Weekly. All rights reserved.</p></footer>
    </body>
    </html>
    """
  end

  @doc "Nothing worth extracting — expected to produce a typed error, not empty success."
  def empty, do: "<html><body></body></html>"

  @doc "Not HTML at all."
  def garbage, do: "this is not html, not even a little bit"

  @doc """
  Multi-byte content throughout: CJK, emoji (4-byte), combining marks, RTL.
  Checks that binaries survive the boundary as valid UTF-8.
  """
  def multibyte(paras \\ 40) do
    body =
      for i <- 1..paras do
        "<p>段落 #{i} — 内容抽出は難しい。🎉🇯🇵 café é مرحبا بالعالم. " <>
          String.duplicate("これは本文です。境界を越えても壊れないはず。", 8) <> "</p>"
      end
      |> Enum.join("\n")

    """
    <!DOCTYPE html>
    <html lang="ja">
    <head>
      <meta charset="utf-8">
      <title>内容抽出について 🎉</title>
      <meta name="author" content="山田 太郎">
      <meta property="og:site_name" content="抽出週刊">
    </head>
    <body>
      <nav><a href="/">ホーム</a></nav>
      <article>#{body}</article>
    </body>
    </html>
    """
  end

  @doc """
  Aimed squarely at `metadata/mod.rs:1237`:

      if s.len() >= 8 && s[..8].chars().all(|c| c.is_ascii_digit())

  `s.len()` is a BYTE length; `s[..8]` is a BYTE slice. "1234567é9" is 10 bytes,
  and `é` occupies bytes 7..9 — so `s[..8]` cuts a char in half and panics.
  This is the panic candidate CONTEXT.md flags.
  """
  def straddling_date do
    article(5, date: "1234567é9")
  end
end
