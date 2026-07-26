# Context: ExTrafilatura

Elixir NIF bindings for `rs-trafilatura` — main content and metadata extraction for web pages, with no Python at deploy time.

> **Seed document.** The library is still scaffolding, so parts of this are stated purpose rather than settled design. Sharpen this with `/domain-modeling` as decisions land, and record the load-bearing ones as ADRs in `docs/adr/`.
>
> Facts about the Rust crate below are confirmed against **`rs-trafilatura` v0.2.2** source, read directly from the published `.crate` artifact. Full findings with file:line citations: [`docs/research/rs-trafilatura-api.md`](docs/research/rs-trafilatura-api.md).

## Why this exists

Python's `trafilatura` is the reference implementation for this kind of extraction, but depending on it from Elixir means shipping a Python runtime — a port, a pool, or a subprocess — into production. This library binds the Rust port instead, so extraction happens in-process over a NIF and deployment stays a single BEAM release.

**No Python at deploy time** is the project's defining constraint. A change that reintroduces a Python dependency in the runtime path defeats the purpose of the library.

## Glossary

- **Extraction** — the whole job: given an HTML document, return the parts a reader actually wants.
- **Main content** — the article body. The thing extraction is trying to keep.
- **Boilerplate** — navigation, sidebars, headers, footers, ads, share widgets, related-post blocks. The thing extraction is trying to drop. "Main content vs boilerplate" is the central distinction in this domain; prefer these two terms over vaguer ones like "the text" or "junk".
- **Metadata** — the descriptive fields about a document rather than its body: title, author, date, site name, description, categories, tags, license. Extracted from a mix of meta tags, JSON-LD, and heuristics over the markup.
- **Comments** — reader comments. A separate extractable stream from main content, not boilerplate. Confirmed present in the Rust port: dedicated `comments_text` / `comments_html` fields and a dedicated `src/extractor/comments.rs`, gated behind `include_comments` (default `false`). Two wrinkles worth knowing: a short comment section is silently reset to `None`, and on forum-type pages the crate overrides the caller's option and folds comments into main content.
- **Precision vs recall** — the core tuning axis. Favouring precision drops more borderline blocks (cleaner output, risks losing real content); favouring recall keeps more (fuller output, risks retaining boilerplate). Callers care about this tradeoff, so name it in these terms rather than as "strict"/"loose". In the crate these are `favor_precision` / `favor_recall` on the `Options` struct, both defaulting to `false`; they collapse to an effective `min_score` of 5000 / 1000 / 500, with precision winning if both are set.
- **Warnings** — a `Vec<String>` on every result. The crate's only diagnostic channel: it reports degraded extraction here rather than by failing. Unstructured `format!` strings — surface them to callers, but never pattern-match on their text.
- **NIF boundary** — the line between Elixir and the Rust crate. Anything crossing it is subject to BEAM scheduler rules: long work must not block a normal scheduler.
- **`rs-trafilatura`** — the upstream Rust crate being bound. Its behaviour is the source of truth for extraction semantics; this library's job is to expose it idiomatically, not to reimplement or second-guess it.

## What the crate forces

These were open questions. Research settled them — the crate's shape decides most of them for us.

- **Input type** — settled. The crate takes `&str` or `&[u8]` and **never fetches**, in any configuration. Even the optional `spider` feature only consumes an already-fetched page. So a URL-fetching layer is purely our choice to add or omit, not something inherited.
- **Metadata as a separate call** — settled, and not in our favour. One call returns content and metadata together; the crate's `metadata` module is `pub(crate)`, so a metadata-only entry point is **not implementable** without patching upstream. Callers pay for both regardless.
- **Output shape** — one result carries `content_text` (`String`) plus `content_html` and `content_markdown` (both `Option<String>`) simultaneously; format is not a mode. **No XML and no JSON** — a real capability gap against Python trafilatura, and worth stating in the README so nobody arrives expecting XML-TEI. Gotcha: Markdown is derived from `content_html`, so requesting Markdown still yields `None` on the paths that null out the HTML.
- **Scheduler strategy** — effectively decided by the numbers. The crate's own README reports ~71 files/s (≈14–22 ms/document) against a ~1 ms NIF budget: 10–20x over on the *common* case. That means a **dirty CPU scheduler**. A yielding NIF isn't implementable against this API anyway — extraction is one straight-line call with no re-entry points.

  Two caveats on the evidence. The 14–22 ms is the crate's self-reported figure, not measured on our hardware; the conclusion survives being wrong by a lot, but a benchmark over a real corpus is what would actually settle it. And the crate's stress test allowing 60 s for a 10 MB input is a **CI headroom allowance, not a measurement** — it says nothing about real cost and shouldn't be cited as if it did.

  What follows from the dirty scheduler is a constraint, not yet a design: extraction is **uninterruptible** and occupies one of a **bounded, VM-wide** pool of threads (default: core count). A caller who gives up waiting does not free the thread. Nothing can bound how *long* a call runs; only how *many* we hold concurrently is controllable, and only by us putting a limiter in front. Whether a library should impose one by default is open.
- **Error representation** — settled by evidence, and it's the surprising one. The public `extract*` functions return `Result`, but **never construct `Err` in 0.2.2**. A page with no detectable main content comes back `Ok` with `content_text: ""` and an explanatory entry in `warnings`. The `Error` enum has four variants (`ParseError`, `EncodingError`, `NoContent`, `ExtractionError`) and is effectively vestigial on this path.

  So "nothing extracted" is genuinely success-with-nothing, exactly as this document guessed — but it's success because the crate declines to fail, not because it distinguishes the cases. **This is a version-pinned observation, not a stable contract**: nothing in the crate's API or docs promises it, and a future release could start returning `Err` without it reading as a breaking change. The Elixir binding should handle `Err` properly even though it is currently unreachable.

## Open questions

Genuinely unresolved. Each is an ADR waiting to be written, not a gap to paper over:

- **Which crate to bind.** There are two independent Rust ports. `rs-trafilatura` (the one researched, 0.2.2) has ~3.4k downloads; an unrelated crate published as plain `trafilatura` (0.3.0, `nchapman/trafilatura-rs`) has ~48k — roughly 14x the adoption. The sibling has **not** been evaluated. This should be a deliberate choice, and it invalidates much of the section above if it goes the other way.
- **How `warnings` surfaces in Elixir.** The crate reports degraded extraction through warnings rather than errors, so discarding them hides real failure. Part of the result map, a separate return value, or a `Logger` call?
- **Whether to expose empty-extraction as an error.** The crate says `Ok("")`; the Elixir API need not agree. Returning `{:error, :no_content}` may serve callers better than an empty binary they have to test for — but it invents a distinction the crate isn't making.
- **Truncation.** `max_extracted_len` defaults to 1,000,000 and the crate truncates by byte index (see below). Doing truncation in Elixir on binaries instead sidesteps that entirely.

## Safety constraints on the NIF

Non-negotiable, and the reason the research mattered:

- **`catch_unwind` is mandatory.** A Rust panic across the NIF boundary takes down a BEAM scheduler. The crate is otherwise disciplined — `unsafe_code = "forbid"`, `unwrap_used`/`expect_used` both denied, zero `unwrap()` or `panic!` outside test modules — but two reachable panics slip past those lints because neither is an `unwrap`:
  - `src/extract.rs:1115` — `String::truncate(max_extracted_len)` on a **byte** index; panics when the cut lands mid-character.
  - `src/extract.rs:278` — `&desc_lower[..desc_lower.len().min(60)]`, also byte-indexed; panics when byte 60 splits a multi-byte character. The `.min(60)` guards the length but not the char boundary. Far easier to trigger than the first, and worth upstreaming a fix.
- **A panic also leaks state.** The crate keeps a `COMMENTS_ARE_CONTENT` thread-local; a panic can leave it stuck `true`, contaminating later extractions on that same scheduler thread. Catching the unwind is not sufficient on its own — the thread-local needs resetting too.

## Conventions

- The public module is `ExTrafilatura`. Bound Rust lives behind it; callers shouldn't need to know a NIF is involved to use the library.
- When naming things in issues, tests, or proposals, use the glossary's terms above. If the concept you need isn't here, that's a signal — either the language is being invented (reconsider) or there's a real gap (note it for `/domain-modeling`).
