# `rs-trafilatura` — API research

**All findings apply to `rs-trafilatura` v0.2.2** (published 2026-04-03), unless stated otherwise.

**Method.** The `.crate` tarball for v0.2.2 was downloaded from `static.crates.io` and read directly. Every "Confirmed" claim below cites a file and line number **inside that tarball**, which is the exact published artifact Cargo would compile. Where a path like `src/extract.rs:161` appears, it is relative to the crate root. No Rust toolchain was available in this environment, so nothing was compiled or executed — all findings are from source reading plus the crate's own test assertions, not from running code. This is called out again where it matters.

---

## Summary

**The crate name is correct.** `rs-trafilatura` exists on crates.io, currently v0.2.2. No correction needed.

**However, there is a second, differently-named, more widely used Rust trafilatura port that this project may have intended.** See [Name check](#0-name-check-read-this-first) — this is worth a decision before writing any ADRs.

**Viability read: usable, but early and thinly staffed — and it has at least two reachable panic vectors that are disqualifying for a naive NIF until worked around.**

The good:

- The API is small, clean, synchronous, and exactly the shape a NIF wants: `&str` in, one owned plain-data struct out.
- It does no network I/O at all, in any feature configuration.
- `unsafe_code = "forbid"` is set crate-wide. There are **zero** `.unwrap()` and **zero** `panic!` calls in non-test code.
- Content, metadata, comments, and Markdown all come back from a **single call** — no separate metadata pass to design around.
- Dependency tree under default features is ~110 crates with no async runtime, no TLS, no HTTP.

The bad:

- **Two reachable `String` byte-index panics on the extraction path** (`src/extract.rs:1115` and `src/extract.rs:278`), both triggered by multi-byte UTF-8 at an unlucky byte offset. A panic across the NIF boundary takes down the BEAM scheduler. These are the single most important findings in this document. Details in [Q7](#q7--nif-relevant-properties).
- Single author, 44 GitHub stars, last commit 2026-04-03 — **roughly four months of no activity** as of 2026-07-26. Whole 0.1.0→0.2.2 lifetime was ten days of intense work followed by silence.
- `CHANGELOG.md` documents only 0.1.0 and was never updated for 0.2.x — so the changelog is not a reliable source.
- The public API surface is undocumented in places and the crate has no `docs.rs`-visible guarantees beyond rustdoc comments.
- Accuracy claims in the README (F1 0.966 / 0.859) are self-reported against the author's own benchmark corpus and were **not** independently verified here.

**Bottom line for this project:** the API shape is genuinely well-suited to a NIF binding and answers most of `CONTEXT.md`'s open questions cleanly. The panic vectors are real but narrow and can be defended against (see [What this means for the Elixir binding](#what-this-means-for-the-elixir-binding)). The maintenance risk is the thing to weigh deliberately — this is a one-person crate that went quiet.

---

## 0. Name check (read this first)

**Confirmed.** `rs-trafilatura` is a real, published crates.io package.

```
name        = rs-trafilatura
version     = 0.2.2  (latest)
description = "Rust port of trafilatura - web content extraction library"
repository  = https://github.com/Murrough-Foley/rs-trafilatura
homepage    = https://murroughfoley.com
docs        = https://docs.rs/rs-trafilatura
license     = MIT OR Apache-2.0
rust-version (MSRV) = 1.85
edition     = 2021
```

Source: `https://crates.io/api/v1/crates/rs-trafilatura`, and `Cargo.toml:12-41` in the v0.2.2 tarball.

Version history (all from the crates.io API):

| Version | Published | License | MSRV | Yanked |
|---|---|---|---|---|
| 0.2.2 | 2026-04-03 | MIT OR Apache-2.0 | 1.85 | no |
| 0.2.1 | 2026-04-02 | MIT OR Apache-2.0 | 1.85 | no |
| 0.2.0 | 2026-03-29 | MIT OR Apache-2.0 | 1.85 | no |
| 0.1.1 | 2026-03-24 | MIT OR Apache-2.0 | 1.85 | no |
| 0.1.0 | 2026-03-24 | MIT OR Apache-2.0 | 1.85 | no |

Note the crates.io metadata says `MIT OR Apache-2.0`, but the GitHub repo's detected license is `Apache-2.0` alone. Both `LICENSE-MIT` and `LICENSE-APACHE` files are present in the tarball, so the dual license in `Cargo.toml` is the authoritative one.

### The other crate — worth a deliberate decision

There is a **separate and unrelated** Rust port published as plain `trafilatura`:

| | `rs-trafilatura` | `trafilatura` |
|---|---|---|
| Latest | 0.2.2 (2026-04-03) | 0.3.0 (2026-03-08) |
| All-time downloads | 3,379 | 48,198 |
| Repo | `Murrough-Foley/rs-trafilatura` | `nchapman/trafilatura-rs` |
| License | MIT OR Apache-2.0 | Apache-2.0 |
| Description | "Rust port of trafilatura" | "Extract readable content, comments, and metadata from web pages" |

Source: `https://crates.io/api/v1/crates?q=trafilatura`.

`trafilatura` has ~14x the downloads. `CONTEXT.md` names `rs-trafilatura` specifically, so this research targets that crate as instructed — but the existence of a more-adopted sibling is a fact that belongs in the ADR discussion. **I did not research the `trafilatura` crate's API**; nothing in this document describes it.

Two further crates also showed up in the same search and are noted only so they aren't rediscovered later: `readex` (0.19.2) and `kawat` (0.1.5), both also claiming trafilatura-derived extraction. Not investigated.

### Maintenance status

**Confirmed.** From `https://api.github.com/repos/Murrough-Foley/rs-trafilatura`:

- Stars: 44 · Forks: 14 · Open issues: 8 · Watchers: 0
- Repo created: 2026-01-11
- **Last push: 2026-04-03** (~4 months before this research on 2026-07-26)
- Not archived
- Most recent commits: `Rename WCEB → WCXB in docs`, `v0.2.2: Fix spider integration issues from adversarial review`

Single author (`Murrough Foley`, per `Cargo.toml:17`). The entire published history spans ten days. Treat this as **early-stage and currently dormant, but not abandoned-by-declaration**.

`CHANGELOG.md` contains an entry for 0.1.0 only — no 0.2.x entries at all. It is stale and should not be relied on.

---

## Q1 — Output shape

**Confirmed.**

Format is **not** a separate set of functions and **not** an enum. There are four entry points that differ only in *input* type (`&str` vs `&[u8]`) and whether options are supplied. **All four return the same struct, which carries multiple representations simultaneously.**

Verbatim signatures from `src/lib.rs`:

```rust
// src/lib.rs:108
pub fn extract(html: &str) -> Result<ExtractResult>

// src/lib.rs:139
pub fn extract_with_options(html: &str, options: &Options) -> Result<ExtractResult>

// src/lib.rs:179
pub fn extract_bytes(html: &[u8]) -> Result<ExtractResult>

// src/lib.rs:215
pub fn extract_bytes_with_options(html: &[u8], options: &Options) -> Result<ExtractResult>
```

> Caveat on docs.rs: the rendered docs.rs page for 0.2.2 summarized these as taking `options: Options` **by value**. The published source takes `options: &Options` **by reference** (`src/lib.rs:139`, `src/lib.rs:215`). The source is authoritative; the by-value rendering appears to be a summarization artifact of how I fetched the page. The binding must pass a reference.

Formats available on the returned struct (`src/result.rs:36-84`):

| Format | Field | Type | Populated when |
|---|---|---|---|
| Plain text | `content_text` | `String` | Always (may be `""`) |
| HTML | `content_html` | `Option<String>` | When structure was preserved |
| Markdown (GFM) | `content_markdown` | `Option<String>` | Only when `options.output_markdown == true` **and** `content_html.is_some()` |

**There is no XML output and no JSON output.** Python trafilatura's XML/XML-TEI/JSON output modes have **no equivalent** in this crate — I checked the full public surface in `src/lib.rs:82-84` and the `ExtractResult` definition. Note that `ImageData` derives `Serialize`/`Deserialize` (`src/result.rs:13`), but `ExtractResult` and `Metadata` do **not** (`src/result.rs:35`, `src/result.rs:90` derive only `Debug, Clone, Default`), so there is no built-in whole-result JSON serialization.

**Gotcha worth designing around.** Markdown is generated by converting `content_html`, at `src/extract.rs:425-442`:

```rust
if options.output_markdown {
    if let Some(ref html) = result.content_html {
        // ... quick_html2md conversion ...
        result.content_markdown = Some(markdown);
    }
}
```

Several extraction paths deliberately set `content_html = None` — the multi-candidate merge (`src/extract.rs:243`), repeated-item collection (`src/extract.rs:262`), the collection-description path (`src/extract.rs:282`), and the JSON-LD product-description fallback (`src/extract.rs:316`). On any of those paths, **`output_markdown: true` still yields `content_markdown: None`.** A binding that promises "ask for Markdown, get Markdown" will be wrong some of the time.

---

## Q2 — Metadata

**Confirmed: one call returns both.** There is no separate public metadata function. The `metadata` module is private — `src/lib.rs:77` declares `pub(crate) mod metadata;`. Metadata is always computed, before content extraction and before DOM cleaning (`src/extract.rs:52`), and is returned as the `metadata` field of `ExtractResult`.

There is no way to extract metadata *without* also running content extraction. `Options` has an `only_with_metadata` flag (`src/options.rs:177`, default `false`) documented as "Only extract date, no content" — but that is a *hint about intent*, not a separate entry point.

The actual struct, verbatim from `src/result.rs:86-136`:

```rust
/// Metadata extracted from an HTML document.
///
/// All fields are optional as metadata may not be present in all documents.
/// Fields match go-trafilatura's Metadata struct for compatibility.
#[derive(Debug, Clone, Default)]
pub struct Metadata {
    /// Page title.
    pub title: Option<String>,

    /// Author name(s).
    pub author: Option<String>,

    /// Original URL of the document.
    pub url: Option<String>,

    /// Hostname extracted from URL.
    pub hostname: Option<String>,

    /// Page description (meta description).
    pub description: Option<String>,

    /// Site name (e.g., "New York Times").
    pub sitename: Option<String>,

    /// Publication or modification date.
    pub date: Option<DateTime<Utc>>,

    /// Content categories.
    pub categories: Vec<String>,

    /// Content tags.
    pub tags: Vec<String>,

    /// Document identifier.
    pub id: Option<String>,

    /// Content fingerprint/hash.
    pub fingerprint: Option<String>,

    /// License information.
    pub license: Option<String>,

    /// Detected content language (ISO 639-1 code).
    pub language: Option<String>,

    /// Main image URL.
    pub image: Option<String>,

    /// Page type classification (article, product, etc.).
    pub page_type: Option<String>,
}
```

Against the field list `CONTEXT.md` asks about: **title, author, date, sitename, description, categories, tags, license, url are all present.** Note the types:

- `date` is **`Option<DateTime<Utc>>`** — a real `chrono` timestamp, not a string. The binding must decide how to render this to Elixir (ISO 8601 string vs `DateTime` struct vs Unix seconds).
- `categories` and `tags` are **`Vec<String>`, not `Option<Vec<String>>`** — absence is the empty vector, so there is no `nil`/`[]` distinction to preserve.
- Everything else in that list is `Option<String>`.

Extras beyond what `CONTEXT.md` anticipated: `hostname`, `id`, `fingerprint`, `language`, `image`, `page_type`.

`page_type` is a `String` in metadata even though a typed `page_type::PageType` enum exists publicly — it is stringified at `src/extract.rs:95`.

The sibling `ImageData` struct, verbatim from `src/result.rs:13-29`:

```rust
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct ImageData {
    /// Full image URL (from `src` or `data-src` attribute).
    pub src: String,

    /// Filename extracted from URL (without query params/fragments).
    pub filename: String,

    /// Alt text from `<img alt="...">` attribute.
    pub alt: Option<String>,

    /// Caption text from associated `<figcaption>` element.
    pub caption: Option<String>,

    /// Whether this is the main/hero image for the page.
    pub is_hero: bool,
}
```

---

## Q3 — Comments

**Confirmed: YES — comments are exposed as a separate stream, and were NOT dropped in the port.**

This is a definitive yes. Three independent lines of evidence:

**1. The result struct has dedicated comment fields**, separate from `content_text`/`content_html` (`src/result.rs:49-53`):

```rust
    /// Comments section as plain text (if extraction enabled).
    pub comments_text: Option<String>,

    /// Comments section as HTML (if extraction enabled).
    pub comments_html: Option<String>,
```

**2. There is a dedicated extractor module** — `src/extractor/comments.rs`, whose header (lines 1-4) reads:

> "This module ports comment extraction from go-trafilatura's main-extractor.go. It extracts user comments from web pages when `include_comments` is enabled."

**3. It is gated and wired up.** At `src/extract.rs:379-383`:

```rust
    let (comments_text, comments_html) = if options.include_comments {
        extract_comments(&document, options)
    } else {
        (None, None)
    };
```

`Options.include_comments` defaults to **`false`** (`src/options.rs:32` and `src/options.rs:238`). So comments are opt-in; by default both fields are `None`.

Behavioural details that matter for the binding:

- Comments are **discarded post-hoc if too short.** `apply_final_validations` (`src/extract.rs:1122-1133`) sets both `comments_text` and `comments_html` back to `None` and pushes a warning if the comment word count is below `options.min_output_comm_size` (default `10`, `src/options.rs:135`). So `include_comments: true` does not guarantee non-`None`.
- **On forum-type pages, comments are reclassified as main content.** At `src/extract.rs:138-150`, if the detected page type's profile has `comments_are_content`, the crate force-enables `include_comments` and sets a thread-local flag so that `comment`-ish class names stop being treated as boilerplate. On a forum page, the comments end up in `content_text`, not `comments_text`. This is an implicit override of the caller's `Options` — worth surfacing rather than hiding.

The crate's own test suite exercises this thoroughly: `tests/comments_test.rs` asserts `comments_text.is_none()` under the default (lines 27-28) and `comments_text.is_some()` with `include_comments: true` across Disqus, Facebook-comments, `#respond`, and `comment-list` markup patterns (lines 84, 129, 155, 181).

---

## Q4 — Error representation

### The error type

**Confirmed.** Complete definition, verbatim from `src/error.rs:5-26`:

```rust
/// Error type for extraction operations.
#[derive(Debug, thiserror::Error)]
pub enum Error {
    /// HTML parsing failed.
    #[error("HTML parsing failed: {0}")]
    ParseError(String),

    /// Character encoding detection or conversion failed.
    #[error("Encoding detection failed: {0}")]
    EncodingError(String),

    /// No extractable content was found in the document.
    #[error("No extractable content found")]
    NoContent,

    /// General extraction failure.
    #[error("Extraction failed: {0}")]
    ExtractionError(String),
}

/// Result type alias for extraction operations.
pub type Result<T> = std::result::Result<T, Error>;
```

Yes, the public API returns `Result<ExtractResult>` — i.e. `std::result::Result<ExtractResult, Error>`.

### What happens when a page has NO detectable main content

**Confirmed — and this is the important one.**

**Answer: `Ok(ExtractResult)` with `content_text == ""` and an explanatory string pushed onto `warnings`. It does NOT return `Err`.**

Stronger than that: **in v0.2.2 the public `extract*` functions never return `Err` at all.** They are infallible in practice. The `Result` is vestigial.

Evidence, in order of strength:

**(a) The compiler-lint annotation.** `src/extract.rs:35-36`:

```rust
#[allow(clippy::unnecessary_wraps)]
pub(crate) fn extract_content(html: &str, options: &Options) -> Result<ExtractResult> {
```

`clippy::unnecessary_wraps` fires precisely when a function returns `Result` but never constructs an `Err`. The author hit that lint and suppressed it. That is the compiler telling us the function is infallible.

**(b) The `NoContent` error is caught and swallowed.** `src/extract.rs:159-169`:

```rust
    let (mut content_text, mut content_html) = match extract_main_content_with_profile(&document, options, page_title, profile.content_selectors) {
        Ok((text, html)) => (text, html),
        Err(Error::NoContent) => {
            warnings.push("Content extraction failed - no main content found".to_string());
            (String::new(), None)
        }
        Err(e) => {
            warnings.push(format!("Content extraction failed: {e}"));
            (String::new(), None)
        }
    };
```

The inner extractor *does* return `Err(Error::NoContent)` (from `src/extract.rs:1499`, `src/extract.rs:2289`, `src/extract.rs:2297`), but the top-level function converts every error into an empty string plus a warning.

**(c) No other error escape route exists.** I scanned the whole body of `extract_content` (lines 36–457): there are **no** `return Err(...)` statements, and **no** `?` propagation operators anywhere in the function. The only `Err(` tokens in that range are the two match arms quoted above.

**(d) The final step also only returns `Ok`.** `apply_final_validations` (`src/extract.rs:1081-1136`) is the last thing called before returning, and its sole exit is `Ok(result)` at `src/extract.rs:1135`.

**(e) The crate's own tests assert exactly this.** `tests/robustness_test.rs:52-77` — note the test *names*:

```rust
#[test]
fn extract_returns_partial_result_for_empty_string() {
    let result = extract("").expect("should return partial result with warnings");
    assert!(result.content_text.is_empty());
    assert!(!result.warnings.is_empty());
}
```

…and the same shape for whitespace-only input, `<html></html>`, and `<body></body>`. All four call `.expect(...)` on the `Result`, i.e. they assert it is `Ok`.

### The `warnings` channel

Because errors are downgraded to warnings, `ExtractResult.warnings: Vec<String>` is the real diagnostic channel. Documented at `src/result.rs:77-83` as covering "Content extraction failed (metadata-only result)", "Individual metadata fields failed to extract", and "Recoverable parsing errors". Observed warning producers include the no-content path (`src/extract.rs:162`), fallback-extraction notices (`src/extract.rs:220`), insufficient-content notices (`src/extract.rs:1104`), truncation (`src/extract.rs:1116`), and comment removal (`src/extract.rs:1128`).

These are **unstructured free-form strings**, several built with `format!` and embedded numbers. They are not machine-parseable and there is no stable warning code. Do not pattern-match on them.

### Caveat

`tests/robustness_test.rs` also contains assertions of the form `assert!(matches!(result, Ok(_) | Err(Error::NoContent)));` (lines 20, 38, 95, 120), which permit an `Err` return. Those tests are written defensively and accept either. Given (a)–(d), the `Err` arm is unreachable in 0.2.2 — but the author evidently intends to keep the option open. **The binding should not rely on infallibility as a permanent guarantee**; handle `Err` anyway.

---

## Q5 — Input type

**Confirmed: HTML strings and bytes only. The crate never performs network I/O.**

- `extract` / `extract_with_options` take `&str` (`src/lib.rs:108`, `src/lib.rs:139`).
- `extract_bytes` / `extract_bytes_with_options` take `&[u8]` and run charset detection first (`src/lib.rs:179`, `src/lib.rs:215`). Both call `encoding::transcode_to_utf8(html)` before extraction (`src/lib.rs:180`, `src/lib.rs:216`).

Encoding detection reads `<meta charset>` and `<meta http-equiv="Content-Type">`, defaults to UTF-8, and — per `src/lib.rs:164` — replaces invalid characters with U+FFFD "rather than causing errors."

`Options.url` (`src/options.rs:85`) is **not** a fetch instruction. It is metadata input: it supplies the source URL so `metadata.hostname` can be derived and so URL heuristics can inform page-type classification (`src/extract.rs:59`).

### Feature flags

**Confirmed.** From `Cargo.toml:43-45` — there are exactly two, and the default is empty:

```toml
[features]
default = []
spider = ["dep:spider"]
```

| Flag | Default | What it enables |
|---|---|---|
| *(default)* | — | Nothing. All core extraction is unconditional. |
| `spider` | off | Compiles `pub mod spider_integration` (`src/lib.rs:67-68`) and pulls in the `spider` crawler crate as a dependency. |

**Even the `spider` feature does not make this crate fetch anything.** It only adds adapters that accept a `Page` the *caller's* crawler already fetched. From `src/spider_integration.rs:36-50`:

```rust
pub fn extract_page(page: &Page) -> Result<ExtractResult> {
    extract_page_with_options(page, &Options::default())
}

pub fn extract_page_with_options(page: &Page, options: &Options) -> Result<ExtractResult> {
    let html = page.get_html_bytes_u8();
    let mut opts = options.clone();
    if opts.url.is_none() {
        opts.url = Some(page.get_url().to_string());
    }
    crate::extract_bytes_with_options(html, &opts)
}
```

I also grepped the whole of `src/` outside `spider_integration.rs` for `reqwest`, `TcpStream`, and fetch-like calls: the only hits are the word "Fetch" in three comments in `src/link_density.rs` describing fetching *links out of a DOM node*. **No network code.**

### Dependency tree

**Confirmed.** Direct dependencies under default features (`Cargo.toml:176-216`): `chrono`, `dom_query` 0.24, `encoding_rs`, `html-cleaning` 0.3, `quick_html2md` 0.2, `regex` 1.11, `serde` (derive), `serde_json`, `tendril`, `thiserror` 2.0, `url` 2.5, `web-page-classifier` 0.1. Optional: `spider` (`>=2.37, <3`). Dev-only: `criterion` 0.5.

I computed the transitive closure from the shipped `Cargo.lock`:

- **Default features: ~127 crates total, ~110 excluding Windows/wasm-only targets.**
- The full `Cargo.lock` lists 325 packages, but that number is misleading — it includes `criterion` (dev-only) and the entire optional `spider` stack (`tokio`, `reqwest`, `hyper`, `rustls`, `quinn`, `aws-lc-sys`, …). **None of that is compiled under default features.**

Notable: `web-page-classifier` has **zero dependencies** — the ML classifier is self-contained, so the "XGBoost/Random Forest" classifier does not drag in a numerics stack. Heaviest real cost is the `html5ever`/`markup5ever`/`selectors`/`string_cache` HTML-parsing group (via `dom_query`), plus `icu_*` normalization crates via `url`/`idna`.

For a NIF this is a moderate but very manageable tree: no async runtime, no TLS, no C toolchain requirements beyond what `cc`/`jobserver` normally handle. **Keep `spider` off** — enabling it would pull `tokio` + `reqwest` + `aws-lc-sys` (which needs CMake) into the NIF build for no benefit.

---

## Q6 — Precision/recall tuning

**Confirmed.** The config struct is **`Options`** (`src/options.rs:28`), re-exported at `src/lib.rs:83`. All fields are public; it derives `Debug, Clone` (`src/options.rs:26`) — note **no `Default` derive**, there is a hand-written `impl Default`.

The two headline knobs are `favor_precision` and `favor_recall`. Verbatim, `src/options.rs:49-71`:

```rust
    /// Tune extraction for higher precision (fewer false positives).
    ///
    /// When enabled, uses stricter content scoring thresholds (`min_score`: 5000)
    /// to exclude borderline content. This reduces false positives at the cost
    /// of potentially missing marginal content.
    ///
    /// If both `favor_precision` and `favor_recall` are true, precision takes
    /// precedence (the stricter threshold is used).
    ///
    /// Default: `false`
    pub favor_precision: bool,

    /// Tune extraction for higher recall (fewer missed content).
    ///
    /// When enabled, uses more lenient content scoring thresholds (`min_score`: 500)
    /// to include borderline content. This reduces false negatives at the cost
    /// of potentially including more noise.
    ///
    /// If both `favor_precision` and `favor_recall` are true, precision takes
    /// precedence (the stricter threshold is used).
    ///
    /// Default: `false`
    pub favor_recall: bool,
```

So the tradeoff collapses to an effective `min_score`: **5000 (precision) / 1000 (neither, the default) / 500 (recall)**, with precision winning if both are set. The crate's own tests state this resolution order explicitly (`src/options.rs:314-371`).

### Full field list and defaults

Read directly from the `impl Default` at `src/options.rs:235-270`. All 28 fields:

| Field | Type | Default |
|---|---|---|
| `include_comments` | `bool` | `false` |
| `include_tables` | `bool` | **`true`** |
| `include_images` | `bool` | `false` |
| `include_links` | `bool` | `false` |
| `favor_precision` | `bool` | `false` |
| `favor_recall` | `bool` | `false` |
| `target_language` | `Option<String>` | `None` |
| `url` | `Option<String>` | `None` |
| `author_blacklist` | `Option<Vec<String>>` | `None` |
| `deduplicate` | `bool` | `false` |
| `min_extracted_size` | `usize` | `200` |
| `min_extracted_len` | `usize` | `200` |
| `max_extracted_len` | `usize` | `1_000_000` |
| `min_output_size` | `usize` | `50` |
| `min_output_comm_size` | `usize` | `10` |
| `min_score` | `usize` | `1000` |
| `max_duplicate_ratio` | `f64` | `0.5` |
| `max_link_density` | `f64` | `0.8` |
| `min_paragraph_cluster` | `usize` | `3` |
| `include_formatting` | `bool` | `false` |
| `only_with_metadata` | `bool` | `false` |
| `max_tree_depth` | `usize` | `100` |
| `min_word_length` | `usize` | `2` |
| `use_fallback_extraction` | `bool` | **`true`** |
| `dedup_cache_size` | `usize` | `1000` |
| `include_title_in_content` | `bool` | `false` |
| `output_markdown` | `bool` | `false` |
| `page_type` | `Option<page_type::PageType>` | `None` |

The verbatim `Default` impl (`src/options.rs:235-270`):

```rust
impl Default for Options {
    fn default() -> Self {
        Self {
            include_comments: false,
            include_tables: true,
            include_images: false,
            include_links: false,
            favor_precision: false,
            favor_recall: false,
            target_language: None,
            url: None,
            author_blacklist: None,
            deduplicate: false,
            min_extracted_size: 200,
            // Story 6-1: Additional threshold defaults (from go-trafilatura settings.go)
            min_extracted_len: 200,
            max_extracted_len: 1_000_000,
            min_output_size: 50,
            min_output_comm_size: 10,
            min_score: 1000,
            max_duplicate_ratio: 0.5,
            max_link_density: 0.8,
            min_paragraph_cluster: 3,
            include_formatting: false,
            only_with_metadata: false,
            max_tree_depth: 100,
            min_word_length: 2,
            use_fallback_extraction: true,
            dedup_cache_size: 1000,
            include_title_in_content: false,
            // EPIC-02: Markdown output
            output_markdown: false,
            page_type: None,
        }
    }
}
```

`Options` is `#[non_exhaustive]`-free and all-public, so struct-update syntax (`..Options::default()`) is the intended construction idiom — and adding a field in a future version would be a breaking change for anyone constructing it exhaustively. The binding should always use `..Options::default()`.

`min_extracted_size` and `min_extracted_len` are both present, both default `200`, and appear redundant — `min_extracted_size` is documented as controlling fallback triggering while `min_extracted_len` is the one actually read at `src/extract.rs:176`. Minor wart; not load-bearing.

`page_type` deserves a mention: setting it (`src/options.rs:232`) skips the ML classifier entirely (`src/extract.rs:55-57`) and sets `classification_confidence` to `None`. That is both a performance lever and a determinism lever.

---

## Q7 — NIF-relevant properties

### Synchronous?

**Confirmed: fully synchronous.** No `async fn`, no futures, no runtime anywhere in the default build. All four entry points are plain blocking calls (`src/lib.rs:108/139/179/215`). The only async in the ecosystem is inside the optional `spider` crate, and even the `spider_integration` adapters themselves are plain `fn` (`src/spider_integration.rs:36`, `:43`).

### Global / lazy state

**Confirmed. Present, but benign.**

**Lazy statics:** the crate uses `std::sync::LazyLock` (not `lazy_static`, not `once_cell`) for compiled regexes:

- `src/patterns.rs:9` imports it; 16 `LazyLock<Regex>` statics at `src/patterns.rs:31,41,54,68,80,85,89,94,104,109,121,126,131,136` (+2 more).
- `src/encoding.rs:15,21` — two more.
- `src/page_type/ml.rs:13` — one more.
- `src/metadata/dom_extraction.rs:25,31,37,43,49,55` — six more.

`LazyLock` is `Sync` and thread-safe. Initialization happens on first access — **which, in a NIF, means inside the first extraction call on some scheduler thread.** Regex compilation of ~25 patterns is one-time and fast (single-digit milliseconds at most), but it is not free, and it is paid inside the first call. Consider a warm-up call at NIF load if first-call latency matters.

**Thread-locals:** exactly one, at `src/extract.rs:27-29`:

```rust
thread_local! {
    static COMMENTS_ARE_CONTENT: Cell<bool> = const { Cell::new(false) };
}
```

It is set at `src/extract.rs:149` for forum-profile pages and reset at `src/extract.rs:446` before returning.

**This is a real NIF hazard, though a small one.** The reset at line 446 is on the normal return path. Because the function has no `?` and no `return Err`, there is no early-return path that skips it — *except* on **panic**. If either panic vector below fires while the flag is set, the flag stays `true` on that scheduler thread, and **subsequent unrelated extractions on that same OS thread would silently treat comment markup as main content.** Cross-request state leakage. Another reason to make panics impossible rather than merely unlikely.

**No `static mut`, no `unsafe`.** `Cargo.toml:246` sets `unsafe_code = "forbid"` crate-wide — this is a hard compiler-enforced guarantee, not a lint.

### `Send` / `Sync`

**Confirmed by inspection of the type definitions** (not compiler-verified, since no toolchain was available).

All public types are composed exclusively of `Send + Sync` primitives, so they get both auto-traits:

- `ExtractResult` (`src/result.rs:36-84`): `String`, `Option<String>`, `Vec<ImageData>`, `Metadata`, `Option<f64>`, `f64`, `Vec<String>`.
- `Metadata` (`src/result.rs:91-136`): `Option<String>`, `Option<DateTime<Utc>>`, `Vec<String>`. `chrono::DateTime<Utc>` is `Send + Sync`.
- `ImageData` (`src/result.rs:14-29`): `String`, `Option<String>`, `bool`.
- `Options` (`src/options.rs:28-233`): `bool`, `usize`, `f64`, `Option<String>`, `Option<Vec<String>>`, `Option<PageType>` (a plain C-like enum, `src/page_type/mod.rs:28`).
- `Error` (`src/error.rs:7-23`): unit variant + `String` variants.

**No `Rc`, no `RefCell`, no raw pointers in any public type.** Importantly, the non-`Send` DOM types (`dom_query::Document`, `Selection`) are confined to `pub(crate)` modules (`src/lib.rs:71-79`) and **never escape into the public API** — the result is fully owned plain data. This is ideal for a NIF: nothing borrows, nothing needs a lifetime, and the result can be moved to any thread or turned into an Elixir term freely.

### Panics — the critical section

**`.unwrap()` / `panic!` audit: Confirmed CLEAN in production code, with two important exceptions that are NOT unwraps.**

`Cargo.toml:227` and `Cargo.toml:235` set `expect_used = "deny"` and `unwrap_used = "deny"`. I verified this holds in practice by classifying every occurrence against each file's `#[cfg(test)] mod tests` boundary:

- **37 `.unwrap()` calls — ALL 37 are inside `mod tests`.** Zero in production code.
- **17 `panic!` calls — 13 inside `mod tests` in `src/extract.rs` (lines 3793+), 4 inside `mod tests` in `src/url_utils.rs` (lines 320, 344, 358, 387; that file's `mod tests` starts at line 280).** Zero in production code.
- **0 `unreachable!`.**
- 27 `.expect()` calls survive in production, but **all of them are `Regex::new(...).expect(...)` inside `LazyLock` initializers** (`src/patterns.rs`, `src/encoding.rs:16,22`, `src/page_type/ml.rs:13`, `src/metadata/dom_extraction.rs:25-55`) plus three in the `batch_markdown` binary (not the library). These operate on **compile-time-constant regex literals** — they can only fail if the author shipped a malformed pattern, which every test run would catch. Effectively zero risk, and explicitly whitelisted via `#[allow(clippy::expect_used)]` at those sites.

**BUT — two reachable byte-index panics remain, and neither is an unwrap, so the lint config did not catch them.**

#### Panic vector 1 — `String::truncate` on a byte index (`src/extract.rs:1114-1120`)

```rust
    // Apply maximum length limit
    if result.content_text.len() > options.max_extracted_len {
        result.content_text.truncate(options.max_extracted_len);
        result.warnings.push(format!(
            "Content truncated to max length: {}",
            options.max_extracted_len
        ));
    }
```

`String::len()` returns **bytes**. `String::truncate(n)` **panics if `n` is not on a UTF-8 char boundary.** `max_extracted_len` defaults to `1_000_000`.

**Trigger:** any document whose extracted text exceeds 1,000,000 bytes *and* where byte 1,000,000 lands mid-multi-byte-character. For a large CJK, Cyrillic, Greek, or emoji-bearing page, the probability that a given byte offset is mid-character is substantial (for 3-byte CJK text, roughly 2 in 3).

This is in `apply_final_validations`, which runs on **every single extraction** (`src/extract.rs:448`).

Note the same function compares `result.content_text.len()` (bytes) against `options.min_extracted_len` at `src/extract.rs:1099`, while `src/extract.rs:175` and `:206` use `.chars().count()` for the same conceptual threshold — a bytes/chars inconsistency throughout. The docs describe these limits as "characters" (`src/options.rs:113,124`), so the byte-based comparison is also a correctness bug independent of the panic.

#### Panic vector 2 — byte-range slice at offset 60 (`src/extract.rs:273-286`)

```rust
    if detected_page_type == page_type::PageType::Category {
        if let Some(desc) = extract_collection_description(&doc_backup) {
            let desc_lower = desc.to_lowercase();
            let content_lower = content_text.to_lowercase();
            // Only add if the description isn't already in the extraction
            if !content_lower.contains(&desc_lower[..desc_lower.len().min(60)]) {
```

`&desc_lower[..60]` **panics if byte 60 is not a char boundary.**

**Trigger:** a page classified as `PageType::Category` that has a collection description longer than 60 bytes containing non-ASCII characters positioned such that byte 60 splits a character. This is *far more likely to fire in practice than vector 1* — it needs only a 60-byte description, not a megabyte one. Any non-English e-commerce category page is a candidate.

Note the author was clearly aware of this class of bug elsewhere — `src/extract.rs:198-199` contains the comment "Get first ~100 chars safely (on char boundary)" followed by a correct `.chars().take(100).collect()`. These two sites were simply missed.

#### Sites I checked and cleared

To be precise about what is *not* a risk:

- `src/encoding.rs:36` — `&html[..html.len().min(1024)]` where `html: &[u8]`. Byte slice, not `str`. **Safe.**
- `src/extract.rs:823` — `&content_lower[..content_lower.len().min(500)]`, same bug pattern, but it sits in `compute_extraction_quality_ml`, which **is never called** (`src/extract.rs:401` calls `compute_extraction_quality_heuristic` instead). Dead code. **Not reachable in 0.2.2** — but it would become live if the author wires the ML quality predictor up.
- `src/extract.rs:3735/3746/3753`, `src/metadata/mod.rs:121`, `src/page_type/mod.rs:1433`, `src/selector/content.rs:350,412` — all slice at offsets obtained from `str::find()`, which always returns char boundaries. **Safe.**
- `src/url_utils.rs:197` — `&path[..path.len() - 1]` guarded by an `ends_with('/')` check; `/` is one byte. **Safe.**
- `src/html_processing.rs:630` — `&trimmed[3..]` after an ASCII prefix check. **Safe.**

Arithmetic overflow is handled carefully (e.g. `saturating_add` at `src/extract.rs:2277`), so that is not an additional concern.

### Runtime cost

**Confirmed (self-reported) / partially Unknown.**

The crate ships `benches/benchmark.rs` (Criterion, `harness = false`, `Cargo.toml:171-174`) with a ~1KB synthetic microbenchmark plus a `real_world` group that reads HTML files from disk with `Throughput::Bytes`. **I could not run it** — no Rust toolchain in this environment. So all timing numbers below are the author's claims, not measurements I made.

From `README.md`:

> "**Fast**: 71 files/s for articles, 46 files/s overall on a 1,497-page benchmark"

That implies roughly **14 ms/document for articles and ~22 ms/document overall**, on unstated hardware.

**This is decisive for the scheduler question.** The BEAM's guidance is that a NIF should return within about **1 ms**. At 14–22 ms average, `rs-trafilatura` is **one to two orders of magnitude over budget on a typical document**, before considering tail cases.

For the tail: the crate's own stress test builds a **10 MB** HTML document and asserts only that extraction finishes within **60 seconds** (`tests/robustness_test.rs:80-96`):

```rust
    let target_size = 10 * 1024 * 1024 + 1;
    // ...
    assert!(matches!(result, Ok(_) | Err(Error::NoContent)));
    assert!(elapsed < Duration::from_secs(60), "large HTML parsing took {elapsed:?}");
```

A 60-second ceiling is a very loose bound and tells us the author had no tight latency expectation for large inputs. There is **no published per-size latency curve** and no documented complexity bound — that part is **Unknown**.

Also relevant to cost: `Options.max_tree_depth` (default `100`, `src/options.rs:184`) exists specifically to prevent "processing overly nested DOM structures", which is some protection against pathological inputs.

---

## What this means for the Elixir binding

Mapping the findings onto the five open questions in `CONTEXT.md`. These are inputs to ADRs, not decisions.

### 1. Error representation

The Rust side gives almost no error signal to model. In 0.2.2 the extraction call **cannot fail** ([Q4](#q4--error-representation)) — a page with no detectable main content returns `Ok` with `content_text: ""` plus a warning string. `CONTEXT.md` already leans this way ("A page with no detectable main content is a plausible success-with-nothing rather than a failure"), and **the crate agrees with that instinct**.

Consequences:

- `{:error, reason}` would have almost nothing to carry from the crate itself. The genuine error sources for `ExTrafilatura` are its own: invalid input type, a NIF-level failure, and — critically — **a caught Rust panic**.
- Empty extraction should be `{:ok, %Result{content: ""}}` or similar, not `{:error, :no_content}`. Deciding otherwise means the binding invents an error the crate deliberately declined to raise.
- **`warnings` needs a home in the Elixir result struct.** It is the only diagnostic channel. But it is unstructured `format!`-built strings with embedded numbers — expose it as an opaque `[String.t()]` for humans/logs, and resist the temptation to pattern-match or normalize it into atoms.
- Don't hard-code infallibility. `Error` has four variants and the crate's tests still accept `Err(Error::NoContent)`; handle `Err` even though it is currently unreachable.

### 2. Scheduler strategy

**This one is effectively decided by the evidence: a normal scheduler is not viable.**

At a self-reported ~14–22 ms/document average against a ~1 ms NIF budget ([Q7](#runtime-cost)), even the common case blows the budget by 10–20x, and the crate's own stress test tolerates up to 60 s on a 10 MB input.

- **Dirty CPU scheduler is the natural fit.** The work is pure CPU, fully synchronous, has no yield points, and cannot be incrementalized without forking the crate — `extract_content` is one long straight-line function with no re-entry mechanism. A yielding NIF is not realistically implementable against this API.
- A size threshold routing large documents differently is possible but probably unnecessary complexity: if 14 ms is already over budget, essentially *everything* belongs on a dirty scheduler.
- **Cap input size in Elixir before crossing the boundary.** Dirty schedulers are a finite pool; a 10 MB document occupying one for tens of seconds is a denial-of-service vector. Consider also lowering `max_tree_depth` from its default of 100.
- **First-call latency:** ~25 regexes compile lazily on first use inside the call ([Q7](#global--lazy-state)). Consider a warm-up extraction at NIF load.

### 3. Output shape

The crate makes this easier than `CONTEXT.md` assumed, with one wrinkle.

- **Format is not a separate function and not a mode** — one call returns text, HTML, and (optionally) Markdown together ([Q1](#q1--output-shape)). The natural Elixir mapping is a single result struct with `content_text`, `content_html`, `content_markdown` fields, rather than `extract_text/1` vs `extract_markdown/1`.
- **XML is off the table.** `CONTEXT.md` lists "structured XML" as something upstream can emit; the Rust port **has no XML output**. If XML matters, this crate cannot provide it. That is a genuine capability gap versus Python trafilatura and should be recorded as such.
- **Markdown is opt-in and not guaranteed.** It requires `output_markdown: true`, and even then returns `None` whenever `content_html` is `None` — which several extraction paths cause. Either document that `content_markdown` may be `nil` even when requested, or have the Elixir layer fall back to `content_text`.
- Extras worth surfacing: `extraction_quality: f64` and `classification_confidence: Option<f64>` are genuinely useful (the crate suggests <0.6 as an LLM-fallback trigger) and have no equivalent in the Python API.

### 4. Metadata as a separate call

**The crate forecloses this option.** There is no public metadata-only function — the `metadata` module is `pub(crate)` ([Q2](#q2--metadata)), and metadata is computed unconditionally at `src/extract.rs:52` before content extraction.

- "Independent functions so callers can pay only for what they need" **is not achievable** without forking the crate or upstreaming a new entry point. The metadata cost is already paid on every call.
- So: one function returning both. An `ExTrafilatura.extract_metadata/1` convenience wrapper could exist for ergonomics, but it must not be sold as cheaper — it would run the full pipeline and discard the content.
- Type-mapping decisions the metadata struct forces:
  - `date` is `Option<DateTime<Utc>>` — pick ISO 8601 string vs `DateTime` struct vs Unix seconds. A real decision, not a passthrough.
  - `categories`/`tags` are `Vec<String>`, so absent and empty are indistinguishable — Elixir gets `[]`, never `nil`.
  - Six fields exist beyond the glossary's list (`hostname`, `id`, `fingerprint`, `language`, `image`, `page_type`). The glossary in `CONTEXT.md` should probably grow to match, or the binding should consciously drop some.

### 5. Input type

**The "fetching pulls in an HTTP client" worry does not apply here** ([Q5](#q5--input-type)). The crate never fetches. Even the optional `spider` feature only consumes an already-fetched page.

- Binary-only input is not just the safe choice, it is the *only* choice the crate offers. There is nothing to opt out of.
- Both `&str` and `&[u8]` entry points exist. **Prefer `extract_bytes*`**: Elixir binaries are bytes, it avoids a UTF-8 validity precondition on input, it adds charset detection for non-UTF-8 pages, and it replaces invalid bytes with U+FFFD instead of erroring. Real-world HTML is often not valid UTF-8, so this matters.
- Pass `Options.url` when the caller knows it — it improves page-type classification and populates `metadata.hostname`. It does **not** cause a fetch.
- **Keep the `spider` feature off** in the NIF build. It would add `tokio` + `reqwest` + `rustls` + `aws-lc-sys` (which needs CMake) to a build that currently needs none of it.

### Cross-cutting: the panic problem

This does not map to one of the five questions but is the highest-priority engineering item.

**A Rust panic across a NIF boundary takes down the BEAM scheduler.** Two reachable panic vectors exist ([Q7](#panics--the-critical-section)):

1. `src/extract.rs:1115` — `String::truncate` at a byte offset, on documents >1 MB of extracted text with multi-byte characters.
2. `src/extract.rs:278` — `&desc_lower[..60]` on `PageType::Category` pages with non-ASCII descriptions. **This one is comparatively easy to hit.**

Mitigations, roughly in order of preference:

- **Wrap every call in `std::panic::catch_unwind`.** All public types are `Send`, owned, and free of interior mutability, so `catch_unwind` is straightforward here. Map a caught panic to `{:error, :extraction_panic}` or similar. This should be considered mandatory, not optional. Note this requires `panic = "unwind"` (the default — do not set `panic = "abort"` in the release profile).
- **Set `max_extracted_len` low enough to matter, and validate it lands on a char boundary** — or better, defuse vector 1 entirely by setting `max_extracted_len` to `usize::MAX` and doing any truncation in Elixir, where binaries are byte-safe.
- **Upstream both fixes.** Both are one-liners (`floor_char_boundary`, or `.chars().take(n)`). The repo is not archived and accepts PRs; this is the durable fix and also a way to test whether the maintainer is responsive — which is itself valuable information given the four-month silence.
- **Guard the thread-local.** A panic while `COMMENTS_ARE_CONTENT` is `true` leaves it set on that scheduler thread, leaking state into later unrelated extractions. `catch_unwind` alone does not reset it.

### Cross-cutting: dependency and maintenance risk

- ~110 crates compile into the NIF under default features ([Q5](#dependency-tree)) — moderate, no C toolchain surprises, no async runtime. Acceptable. Enabling `spider` would change that assessment sharply.
- MSRV 1.85, edition 2021 — recent, worth pinning in CI.
- Dual MIT/Apache-2.0 is permissive and compatible with essentially any Elixir library license.
- **Pin the exact version.** `0.2.2` with a lockfile. This is a 0.x crate from a single author where minor bumps can break the API, and `Options` is an all-public non-`exhaustive` struct — a new field is a breaking change for exhaustive construction.
- **The maintenance question deserves an explicit decision.** Four months quiet, one author, 44 stars, 8 open issues. That is not abandonment, but it is not a crate to build on without a stated fallback plan. Worth weighing against the more-adopted `trafilatura` crate ([Name check](#0-name-check-read-this-first)) before committing — a comparison this research did not perform.

---

## Sources

**Primary — source code read directly** (from the `rs-trafilatura-0.2.2.crate` tarball at `https://static.crates.io/crates/rs-trafilatura/rs-trafilatura-0.2.2.crate`; paths relative to crate root):

- `Cargo.toml` — package metadata, features, dependencies, lint config
- `src/lib.rs` — public API surface and all four entry-point signatures
- `src/error.rs` — `Error` enum, `Result` alias
- `src/result.rs` — `ExtractResult`, `Metadata`, `ImageData`
- `src/options.rs` — `Options` struct and `impl Default`
- `src/extract.rs` — extraction pipeline, no-content path, panic vectors, thread-local
- `src/extractor/comments.rs` — comment extraction
- `src/spider_integration.rs` — optional `spider` adapters
- `src/encoding.rs`, `src/patterns.rs`, `src/page_type/mod.rs`, `src/page_type/ml.rs`, `src/metadata/dom_extraction.rs`, `src/metadata/mod.rs`, `src/url_utils.rs`, `src/html_processing.rs`, `src/selector/content.rs`, `src/link_density.rs` — lazy statics, panic audit
- `Cargo.lock` — transitive dependency closure
- `README.md` — feature list, performance claims, usage examples
- `CHANGELOG.md` — 0.1.0 only; stale
- `tests/robustness_test.rs` — empty/no-content and large-input behaviour
- `tests/comments_test.rs` — comment extraction behaviour
- `benches/benchmark.rs` — benchmark shape

**Primary — registry and repository metadata:**

- `https://crates.io/api/v1/crates/rs-trafilatura` — versions, licenses, MSRV, publish dates
- `https://crates.io/api/v1/crates?q=trafilatura` — package name confirmation, sibling crates
- `https://crates.io/api/v1/crates/trafilatura` — alternative crate metadata
- `https://api.github.com/repos/Murrough-Foley/rs-trafilatura` — stars, issues, last push
- `https://api.github.com/repos/Murrough-Foley/rs-trafilatura/commits` — recent commit history
- `https://docs.rs/rs-trafilatura/0.2.2/rs_trafilatura/` — rendered API index (see the by-value/by-reference caveat in [Q1](#q1--output-shape))

**Not used as sources for API shape:** no blog posts, forum threads, or summary sites were consulted. Python `trafilatura`'s API was not used to infer anything about the Rust port; where the Rust port lacks a Python feature (XML output, standalone metadata extraction), that is stated as a verified absence in the Rust source, not an assumption.

**Not verified:** the crate was never compiled or executed — no Rust toolchain was available in this environment. Benchmark and F1 accuracy figures are the author's self-reported claims from `README.md`. `Send`/`Sync` were determined by inspecting type definitions rather than by compiler check. The `trafilatura` (non-`rs-`) crate's API was not researched.
