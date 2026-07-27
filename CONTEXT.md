# Context: ExTrafilatura

Elixir NIF bindings for the Rust `trafilatura` crate — main content and metadata
extraction for web pages, with no Python at deploy time.

> **Seed document.** The library is still scaffolding, so parts of this are stated
> purpose rather than settled design. Sharpen this with `/domain-modeling` as
> decisions land, and record the load-bearing ones as ADRs in `docs/adr/`.
>
> Facts about the Rust crate below are confirmed against **`trafilatura` v0.3.0**
> (`nchapman/trafilatura-rs`), read and executed directly. The crate choice and the
> measurements behind it are in
> [`docs/research/crate-comparison.md`](docs/research/crate-comparison.md).

## Why this exists

Python's `trafilatura` is the reference implementation for this kind of extraction,
but depending on it from Elixir means shipping a Python runtime — a port, a pool, or
a subprocess — into production. This library binds a Rust port instead, so extraction
happens in-process over a NIF and deployment stays a single BEAM release.

**No Python at deploy time** is the project's defining constraint. A change that
reintroduces a Python dependency in the runtime path defeats the purpose of the
library.

## Which crate, and why it matters

There were two independent Rust ports. We bind **`trafilatura` 0.3.0**
(`nchapman/trafilatura-rs`), a port of `go-trafilatura` which is itself a port of
Python trafilatura.

The sibling crate `rs-trafilatura` was evaluated and rejected. The disqualifying
finding: it recurses over the DOM without any depth bound and **stack-overflows at
~3000 nesting depth on a BEAM dirty-scheduler-sized stack** (~18 KB of HTML). A stack
overflow is not a catchable panic — it aborts the OS process, so the entire node
dies. It was also measurably slower (13.0 ms vs 4.8 ms mean per document) and less
accurate (F-score 0.881 vs 0.913 on 925 real pages). Full evidence in the research
doc.

`trafilatura`'s behaviour is the source of truth for extraction semantics; this
library's job is to expose it idiomatically, not to reimplement or second-guess it.

## Glossary

- **Extraction** — the whole job: given an HTML document, return the parts a reader
  actually wants.
- **Main content** — the article body. The thing extraction is trying to keep.
- **Boilerplate** — navigation, sidebars, headers, footers, ads, share widgets,
  related-post blocks. The thing extraction is trying to drop. "Main content vs
  boilerplate" is the central distinction in this domain; prefer these two terms over
  vaguer ones like "the text" or "junk".
- **Metadata** — the descriptive fields about a document rather than its body: title,
  author, date, site name, description, categories, tags, license. Extracted from a
  mix of meta tags, JSON-LD, OpenGraph, and heuristics over the markup.
- **Comments** — reader comments. A separate extractable stream from main content,
  not boilerplate. Surfaced as `comments_text` / `comments_html`, and **included by
  default**: the crate's option is `exclude_comments` (default `false`), the inverse
  sense of what you might expect. On 925 real pages, 168 produced comments and the
  two streams were disjoint on 166 of them — so a caller joining content and comments
  will usually not duplicate, but occasionally (~1%) will.
- **Precision vs recall** — the core tuning axis. Favouring precision drops more
  borderline blocks (cleaner output, risks losing real content); favouring recall
  keeps more (fuller output, risks retaining boilerplate). Callers care about this
  tradeoff, so name it in these terms rather than as "strict"/"loose". In the crate
  it is a single `ExtractionFocus` enum — `Balanced` (default), `FavorPrecision`,
  `FavorRecall` — not two independent booleans. It measurably works: `FavorPrecision`
  moves precision 0.908 → 0.920.
- **Fallback** — a second-chance extraction pass using the `libreadability` and
  `justext` algorithms when the primary pass does poorly. Controlled by
  `enable_fallback`. Python trafilatura does the same thing; this is fidelity, not
  an invention.
- **NIF boundary** — the line between Elixir and the Rust crate. Anything crossing it
  is subject to BEAM scheduler rules: long work must not block a normal scheduler.
- **`trafilatura`** — the upstream Rust crate being bound. Not to be confused with
  Python `trafilatura` (the reference implementation) or `rs-trafilatura` (the
  rejected sibling). When ambiguity is possible, say "the Rust crate" or "Python
  trafilatura".

## What the crate forces

These were open questions. Research settled them — the crate's shape decides most of
them for us.

- **Input type** — settled. `extract(html: &str, opts: &Options)` takes a `&str` and
  **never fetches**. Network code (`reqwest`) exists only behind the `cli` feature,
  which we will not enable. A URL-fetching layer is purely our choice to add or omit.
- **Metadata as a separate call** — settled, and not in our favour. One call returns
  content and metadata together. Callers pay for both regardless.
- **Output shape** — one `ExtractResult` carries `content_text`, `comments_text`,
  `content_html`, `comments_html`, all `String`, all populated simultaneously. Format
  is not a mode. **Empty string means absent**, not `Option` — mapping that onto
  Elixir `nil` is our job. Same for most of `Metadata`, where only `date` is an
  `Option`. **No XML and no JSON output** — a real capability gap against Python
  trafilatura, worth stating in the README so nobody arrives expecting XML-TEI.
- **Markdown is a method behind a feature flag.** `content_markdown()` /
  `comments_markdown()`, gated on the `markdown` feature, derived from the
  corresponding `*_html` field. Since those fields are plain `String` and always
  populated, there is no "requested Markdown, got nothing" trap.
- **No truncation.** The crate has no `max_extracted_len` and never truncates output.
  If we want a size cap it is entirely ours to impose — and doing it in Elixir on
  binaries is both easy and safer than a byte-indexed cut in Rust.
- **The options surface is 18 fields plus a nested `Config` of 7** — far wider than
  the handful usually cited, and **three of its knobs do not do what they say**.
  Confirmed by reading 0.3.0's source:

  - `enable_log` is declared and settable but **never read anywhere in `src`**. It is
    a pure no-op.
  - `html_date_mode` has four variants, but only `Disabled` is ever branched on
    (`metadata/mod.rs:358`). `Default`, `Fast`, and `Extensive` are behaviourally
    identical, and the crate's own doc comment admits `Extensive` is "not yet
    implemented".
  - `deduplicate` is documented as "cross-document duplicate detection via LRU
    cache", but the cache is constructed **per call** (`lib.rs:147`), so it cannot
    span documents. It does intra-document paragraph dedup only.

  **Defaults are all-off.** `Options` derives `Default`, so `enable_fallback`,
  `include_links`, `include_images`, `exclude_comments`, `exclude_tables`,
  `deduplicate`, and `has_essential_metadata` are every one of them `false`, and
  `max_tree_size` is `None`. Note this deviates from Python trafilatura, which
  defaults fallback **on**. The v0.1.0 binding matches the crate's defaults, not
  Python's — see [#11](https://github.com/bravely/ex_trafilatura/issues/11).

- **Everything public is `#[non_exhaustive]`** — `ExtractResult`, `Metadata`,
  `TrafilaturaError`. We cannot exhaustively match on them, and upstream can add
  fields or variants in a minor release. The Elixir binding must tolerate that:
  build result maps field-by-field, and make the error mapping total with a
  catch-all.
- **Scheduler strategy** — decided, and now on measured rather than vendor data.
  Mean 4.84 ms/document (p50 3.93, p99 19.5) against a ~1 ms NIF budget; **915 of 925
  real documents exceed it**. That means a **dirty CPU scheduler**. A yielding NIF
  isn't implementable against this API anyway — extraction is one straight-line call
  with no re-entry points.

  The constraint this creates: extraction is **uninterruptible** and occupies one of
  a **bounded, VM-wide** pool of threads (default: core count). A caller who gives up
  waiting does not free the thread. Nothing bounds how *long* a call runs; only how
  *many* we hold concurrently is controllable, and only by us putting a limiter in
  front. The posture v0.1.0 takes toward that is settled — see
  [ADR-0001](docs/adr/0001-resource-safety-posture.md).

- **Error representation** — settled, and unlike the rejected crate this is a real
  contract. `extract` returns `Result<ExtractResult, TrafilaturaError>` and genuinely
  constructs errors. Five of seven variants are reachable in the current code:

  | Variant | Reachable | Meaning |
  |---|---|---|
  | `InsufficientContent { text_len, comment_len, min_output_size, min_output_comment_size }` | yes | nothing worth returning was found |
  | `MissingMetadata(String)` | yes | `has_essential_metadata` was set and a field was absent |
  | `LanguageMismatch { expected, got }` | yes | `target_language` was set and did not match |
  | `DuplicateContent` | opt-in | body seen before, per the dedup cache |
  | `TreeTooLarge(usize)` | opt-in | output exceeded `max_tree_size` |
  | `ParseError(String)` | no | vestigial in 0.3.0 |
  | `Io(std::io::Error)` | no | vestigial on this path |

  Note `InsufficientContent` fires on an empty document — "nothing extracted" is a
  typed error here, not success-with-nothing. That answers a question this document
  previously had open.

  **Two of the five are gated behind an option that is off by default.**
  `TreeTooLarge` is constructed only at `lib.rs:237`, inside
  `if let Some(max_tree) = opts.max_tree_size`; `DuplicateContent` only at
  `lib.rs:259`, inside `if opts.deduplicate`. Neither option ships in v0.1.0, so both
  variants are **unreachable by construction** and the binding's error union is three
  variants, not five — see [#10](https://github.com/bravely/ex_trafilatura/issues/10).

## Open questions

Genuinely unresolved. Each is an ADR waiting to be written, not a gap to paper over:

- **How errors map to Elixir.** The crate gives five distinct reachable variants with
  structured payloads. Flatten to `{:error, :insufficient_content}`, or preserve the
  fields as `{:error, {:insufficient_content, %{text_len: 0, ...}}}`? The former is
  idiomatic; the latter keeps information the crate went to the trouble of typing.
  Whatever we pick must stay total — `TrafilaturaError` is `#[non_exhaustive]`.
- **Empty string vs `nil`.** Most result and metadata fields use `""` for absent.
  Translating those to `nil` at the boundary is more idiomatic Elixir but invents a
  distinction the crate isn't making, and `""` is a legitimate extracted value in
  principle. Decide once and apply uniformly.
- **Images.** The crate can preserve `<img>` inside `content_html` rather than
  returning a structured list — but **only when `include_images` is set, and it
  defaults to `false`**, so the stock call strips them. (The 400/925 measurement of
  pages carrying at least one image in extracted content was taken with the option
  on.) If callers want structured image data, we either parse `content_html` in
  Elixir (Floki) or do not offer it.
- **Whether to pursue time-of-day upstream, or vendor it.** `Metadata.date` is a
  `NaiveDate`, but the crate parses a full offset-aware timestamp and then discards
  the time (`dt.date_naive()` in `src/metadata/mod.rs`). The case for contributing is
  strong: go-trafilatura's `Metadata.Date` is a full `time.Time`, so narrowing to a
  date is a **deviation from the reference the crate exists to port** — and unlike
  the crate's two other date deviations, `DEVIATIONS.md` does not record it. Nobody
  has ever raised it upstream (zero issues or PRs mention it).

  The obstacle is upstream responsiveness, not technical difficulty — see below.

## Upstream health

Checked 2026-07-26. This bears on any plan that routes through upstream.

- **The repository is effectively dormant.** Last commit to `main` is 2026-03-09;
  crates.io is still at 0.3.0. Tags `v0.3.1`–`v0.3.7` exist but all carry
  `version = "0.3.0"` — they release the language-binding artifacts, not the crate.
- **Two PRs sit unmerged**, both from outside contributors:
  - [#2](https://github.com/nchapman/trafilatura-rs/pull/2), open since 2026-03-18 —
    a pure dependency bump (`ego-tree` 0.10→0.11, `html5ever` 0.36→0.39, `scraper`
    0.25→0.26, `tendril` 0.4→0.5) that fixes a **reported panic**, see below.
  - [#3](https://github.com/nchapman/trafilatura-rs/pull/3), open since 2026-06-03 —
    a Windows path-handling fix in image detection.
- **The one open issue is a reachable panic in the version we depend on.**
  [#1](https://github.com/nchapman/trafilatura-rs/issues/1) reports
  `ego-tree` 0.10.0 `unwrap()` on `None`, reached via
  `extract` → `extract_document` → `doc_cleaning` → `strip_elements` →
  `dom::tree::remove`. The reporter noted the repo "doesn't seem to have permission
  set up for external contributors."
- **A second panic exists that upstream does not know about.** The `s[..8]`
  char-boundary slice in `src/metadata/mod.rs:1237` (see the safety constraints below)
  is attacker-reachable and, as of 2026-07-27, has no upstream issue or PR. We report
  it, without waiting on it.

**What this means for us.** Assume upstream will not merge our changes on any useful
timescale. Carry patches ourselves rather than blocking on a PR. Verified locally:
PR #2's bump applies cleanly to 0.3.0 with **no source changes** and the crate builds
and tests green against it, so mitigating the panic is cheap and we do it from the
start.

**How v0.1.0 carries them** ([ADR-0002](docs/adr/0002-vendor-the-patched-rust-crate.md)):
a patched copy of the crate is **vendored in-tree** at
`native/ex_trafilatura/vendor/trafilatura/` (`Cargo.toml` + `src/` + `LICENSE`, ~455 KB)
and referenced through `[patch.crates-io]`, carrying both fixes — PR #2's bumps and
our own one-line char-boundary fix. Both need modified crate source, since the bumps
are semver-incompatible and no lockfile can produce them. Provenance is pinned by a
`0.3.0+extrafilatura.1` version marker, a `VENDOR.md` recording the upstream tarball's
sha256, and the patches kept as files. Bug fixes land freely; **anything changing
extraction or metadata semantics needs its own ADR first.**

The time-of-day widening is a larger patch (a type change through ~8 signatures plus
`result.rs`, `options.rs`, and the UniFFI mapping) and is worth opening upstream on
principle — but design for it landing in our own tree. That tree now exists: it would
go in the vendor directory as a further patch. Because it changes metadata semantics
rather than fixing a bug, ADR-0002 requires it to carry its own ADR first — and it is
out of scope for v0.1.0.

## Safety constraints on the NIF

Non-negotiable, and the reason the research mattered:

- **`catch_unwind` buys failure *shape*, not survival.** This document previously said
  it was mandatory because a panic across the boundary takes down a BEAM scheduler.
  The boundary spike disproved that: **Rustler 0.38 already wraps every NIF body in
  `catch_unwind`** (`rustler-0.38.0/src/codegen_runtime.rs`), so a panic surfaces as
  `** (ErlangError) Erlang error: :nif_panicked` and the VM carries on. Rustler
  **discards the panic payload**, though — `Err(_) => nif_panicked` — so Elixir gets a
  bare atom with no message, no Rust file:line, and no way to tell which panic fired;
  the message goes to OS stderr via Rust's default hook, which is not `Logger`. A
  guard of our own is therefore an API choice, not a safety one, and the error term it
  should produce belongs to the error-representation decision.

  `trafilatura` is disciplined — no `unsafe`, no thread-locals, no statics with
  interior mutability, zero compiler warnings, CI runs `clippy -D warnings` — and it
  bounds every DOM recursion at `MAX_TREE_DEPTH = 500`. But it is not panic-*proven*:
  `src/metadata/mod.rs:1237` slices `s[..8]` before its own ASCII-digit check. That was
  listed here as a hypothesis; the spike confirmed it is **real and attacker-reachable**
  from a meta tag value. We patch it — see
  [ADR-0002](docs/adr/0002-vendor-the-patched-rust-crate.md).
- **`catch_unwind` is not sufficient on its own, and cannot be.** It does not catch
  stack overflow or abort. That is exactly why the depth bound matters and why we
  rejected the alternative crate: no amount of Rust-side care in *our* wrapper can
  save a NIF from a dependency that recurses without a limit.
- **Cost is unbounded per call, and we cannot cap it in Rust.** `Options.max_tree_size`
  looks like a safety valve but is not one for this purpose — it counts children of
  the *extracted* body and fires *after* the work is done. Any real bound on time or
  memory has to come from us: limit input size before the call, and/or limit
  concurrency in front of it.

  **What v0.1.0 does about it** ([ADR-0001](docs/adr/0001-resource-safety-posture.md)):
  bounds memory and accidents, not time. A 10 MB input-size cap is checked in Elixir
  before the call, overridable per call via `max_input_bytes` (`:infinity` disables) —
  the one non-crate key in the API — and exceeding it is an error, never a truncation.
  **No concurrency limiter ships**, not even opt-in, and there is no structural or
  depth pre-flight check. Bytes are a weak proxy for time — ~600 KB of nesting
  measured 20.7 s on one thread — so the tarpit is documented rather than mitigated,
  and the README says so in full.
- **Verify determinism assumptions hold as we go.** Serial vs. 8-thread extraction
  over 300 real documents produced byte-identical output, so there is no known
  cross-call state to contaminate. That is a property of 0.3.0, not a promise.

## How correctness is verified

Settled in [ADR-0003](docs/adr/0003-verification-posture.md). "Correct" is narrow here:
the crate's behaviour is the source of truth, so verification proves the *binding*
faithfully exposes it and that the crate has not silently regressed underneath us — not
that extraction is good.

Three tiers, separated by what each can fail on and how often it runs:

- **Every push** — a CI job doing `mix format --check-formatted`, `mix test`,
  `cargo clippy -D warnings` scoped to our NIF crate only, and a **vendor-integrity
  check** (pristine tarball + `vendor/patches/*.patch` must reproduce
  `vendor/trafilatura/` exactly). One Ubuntu job, no matrix, no Dialyzer, no Credo.
  Fixtures are **handwritten minimal HTML only** — no real pages, no golden snapshots of
  extraction output, since a snapshot asserts on upstream's contract rather than ours
  and redistributing scraped articles in a Hex package is a licence problem we don't
  need. Because `extract/1` is defined to equal `Options::default()`, expectations can
  be borrowed from upstream's **inline-HTML** unit tests (`metadata_unit_test.rs`,
  `elements_test.rs`, `html_processing_test.rs`) — a source for fixtures, not a porting
  project, and distinct from its real-page suites.
- **Pre-release and at each re-vendor** — two harnesses in `tools/verify/`. A
  **differential run** compiles one harness twice, against stock 0.3.0 and against the
  patched vendor, and diffs the full `ExtractResult` and `Metadata` byte for byte over
  the 925-page corpus, which is **cloned on demand and never vendored**. And the
  **adversarial nesting benchmark**, which regenerates the figures ADR-0001 §6 publishes.
- **Escalation only** — if the differential diff is non-empty, upstream's own
  `tests/comparison_test.rs` is run against a clone with our patches applied. **F-score
  below 0.903** (0.01 under the measured 0.913) reopens ADR-0002 §1 rather than being
  settled on release day.

Deliberately **not** done for v0.1.0: no fuzz pass. A fuzzer over a parser this size
finds panics with no natural stopping point, and `catch_unwind` plus the error term from
the error-representation work already bound a panic to one failed call. It reopens if
panics prove frequent rather than theoretical.

## Conventions

- The public module is `ExTrafilatura`. Bound Rust lives behind it; callers shouldn't
  need to know a NIF is involved to use the library.
- When naming things in issues, tests, or proposals, use the glossary's terms above.
  If the concept you need isn't here, that's a signal — either the language is being
  invented (reconsider) or there's a real gap (note it for `/domain-modeling`).
- **This project is Apache-2.0**, matching the crate and the whole upstream lineage
  (Rust `trafilatura` → `go-trafilatura` → Python trafilatura are all Apache-2.0).
  It was briefly dual MIT/Apache-2.0, inherited from the rejected sibling crate;
  that was dropped because a NIF statically links its dependencies, so binary
  distributions must satisfy Apache-2.0 regardless — a source-level MIT option would
  have been one binary users could not exercise. Bundled-dependency terms, including
  four MPL-2.0 crates, are in `THIRD-PARTY-NOTICES.md`.
