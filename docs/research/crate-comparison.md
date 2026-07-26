# Which Rust crate to bind: `rs-trafilatura` vs `trafilatura`

Resolves the first open question in [`CONTEXT.md`](../../CONTEXT.md) ("Which crate to bind").

**Recommendation: bind `trafilatura` (nchapman/trafilatura-rs) 0.3.0.**

It is safer behind a NIF, measurably more accurate, and 2.7x faster. `rs-trafilatura`
has a defect that kills the BEAM VM outright on a small, ordinary-looking input.

Candidates:

| | `rs-trafilatura` 0.2.2 | `trafilatura` 0.3.0 |
|---|---|---|
| Repo | `Murrough-Foley/rs-trafilatura` | `nchapman/trafilatura-rs` |
| Lineage | direct from-scratch port of Python trafilatura | port of `go-trafilatura`, itself a port of Python trafilatura |
| License | MIT OR Apache-2.0 | Apache-2.0 |
| DOM stack | `dom_query` | `scraper` + `html5ever` + `ego-tree` |
| src LOC | 23,475 | 13,226 |

Everything below is measured on this machine against both crates at the versions
above, not inferred from documentation. Method and reproduction are at the end.
Adoption metrics, star counts, and commit recency are deliberately excluded.

---

## 1. NIF safety

This is the axis that decides it.

### 1.1 `rs-trafilatura` aborts the process on deeply nested HTML

Nested `<div>`s, extracted via the public `extract()` with default options, on a
thread sized like a BEAM dirty CPU scheduler (320 KiB — ERTS `+sssdcpu` default of
40 kilowords):

| DOM depth | `rs-trafilatura` | `trafilatura` |
|---|---|---|
| 200 | ok | ok |
| 500 | ok | ok (empty — see §4.3) |
| 1000 | ok | ok (empty) |
| 2000 | ok | ok (empty) |
| **3000** | **`SIGABRT` — "has overflowed its stack"** | ok (empty) |
| 4000, 6000 | `SIGABRT` | ok (empty) |

Depth 3000 is roughly **18 KB of HTML**. This is not a caught panic — it is a stack
overflow, so `catch_unwind` cannot intercept it and the *entire BEAM node dies*,
taking every unrelated process with it. It is the one failure mode a NIF has no
defence against, and it is reachable from a single small document.

The cause is structural. `trafilatura` declares `MAX_TREE_DEPTH = 500` and checks it
at **every** recursive traversal in its DOM layer — 8 sites across
[`src/dom/tree.rs`](https://github.com/nchapman/trafilatura-rs/blob/main/src/dom/tree.rs)
and `src/dom/query.rs` — with a regression test for nesting past the limit.

`rs-trafilatura` exposes `Options.max_tree_depth`, defaults it to `100`, and asserts
that default in its own unit tests — but **no code ever reads the field**. Every
recursive traversal is unbounded. A dead knob is worse than no knob: it advertises a
bound that does not exist.

```
$ grep -rn 'max_tree_depth' rs/src rs/tests
rs/src/options.rs:184:    pub max_tree_depth: usize,     # declared
rs/src/options.rs:260:            max_tree_depth: 100,   # defaulted
rs/src/options.rs:304,379,387                            # asserted in its own tests
# ...and that is every occurrence. Never read.
```

### 1.2 A reachable panic, reproduced

`rs-trafilatura` panics at `src/extract.rs:1115`, calling `String::truncate` with a
**byte** index (`max_extracted_len`, default 1,000,000):

```
thread 'main' panicked at rs/src/extract.rs:1115:29:
assertion failed: self.is_char_boundary(new_len)
   3: <alloc::string::String>::truncate
        at rs/src/extract.rs:1115:29
        at rs/src/extract.rs:448:24
```

Triggered from the public `extract()` with **default options** on >1 MB of ordinary
accented text. Shifting the input by one byte flips it between clean and panicking:

```
rs  trunc/0    59.0ms  ok text_len=1000000
rs  trunc/1    PANIC (rc=101)
tr  trunc/0   138.2ms  ok
tr  trunc/1   126.6ms  ok
```

This is survivable in a NIF — `catch_unwind` handles it — but it is only the site
that happened to be easiest to reach. Static review found two further byte-indexed
slices on `String` that are panics waiting for the right input, both flagged
previously in `CONTEXT.md`'s safety section:

- `src/extract.rs:278` — `&desc_lower[..desc_lower.len().min(60)]` (category pages)
- `src/extract.rs:823` — `&content_lower[..content_lower.len().min(500)]` (ML feature extraction)

I could not construct inputs reaching those two paths, so treat them as
statically identified but unproven. The `.min(N)` guards the length, never the char
boundary. `trafilatura` has one comparable site (`src/metadata/mod.rs:1237`,
`s[..8]` evaluated before its own ASCII check); it is narrower but not provably
unreachable either.

### 1.3 Pathological time complexity

Same nested-`<div>` inputs, 8 MB stack, wall clock for a **single document**:

| depth | input size | `rs-trafilatura` | `trafilatura` |
|---|---|---|---|
| 5,000 | ~30 KB | 3.9 s | 58 ms |
| 20,000 | ~120 KB | **59.9 s** | 871 ms |
| 30,000 | ~180 KB | **121 s** | — |
| 50,000 | ~300 KB | **343 s** | — |
| 100,000 | ~600 KB | stack overflow | 20.7 s |

A ~300 KB document pins one dirty-scheduler thread for **5.7 minutes**. Since the
dirty pool is bounded (default: core count) and a NIF call is uninterruptible, a
handful of such documents exhausts the pool node-wide. Both crates degrade
super-linearly here; `rs-trafilatura` is ~69x worse at depth 20,000 and crashes
where `trafilatura` merely gets slow.

### 1.4 Unguarded thread-local (structural, not reproduced)

`rs-trafilatura` sets a `COMMENTS_ARE_CONTENT` thread-local to `true` at
`extract.rs:149` and resets it at `extract.rs:446` — with ~300 lines of parsing,
cleaning, scoring and DOM traversal in between and **no RAII guard**. A panic in
that window leaves the flag stuck on a scheduler thread, silently changing later
extractions on that thread. `catch_unwind` alone would not be sufficient; the flag
would need explicit resetting.

I could not trigger a panic inside that specific window (the §1.2 panic occurs
after the reset), so this is a structural hazard rather than a demonstrated bug.

`trafilatura` has **no thread-locals, no statics with interior mutability, and no
`unsafe`** anywhere in `src/`. Nothing to contaminate.

### 1.5 Concurrency determinism

300 real documents, serial vs. 8 threads, outputs compared byte-for-byte:

```
rs: 300 docs, 0 mismatches
tr: 300 docs, 0 mismatches
```

Neither shows cross-call state contamination in practice. Clean for both.

### 1.6 Already proven across an FFI boundary

`trafilatura` ships a UniFFI layer (`uniffi/`) with Python, Swift, and Kotlin
binding tests **running in CI**. Its public API is therefore already known to
survive a foreign-function boundary: flat owned types, no lifetimes or borrowed
handles leaking out. That is exactly the shape a Rustler NIF needs, and it means
the encoding work is largely a solved problem rather than a discovery exercise.

`rs-trafilatura` has no FFI exposure.

---

## 2. Performance, measured

925 real-world pages (the `go-trafilatura` comparison corpus), default options,
release build, this machine:

| | mean | p50 | p90 | p99 | max | throughput |
|---|---|---|---|---|---|---|
| `rs-trafilatura` | 13.00 ms | 9.92 | 22.67 | 63.76 | 183.6 | **77 docs/s** |
| `trafilatura` | 4.84 ms | 3.93 | 8.26 | 19.49 | 60.8 | **207 docs/s** |

`trafilatura` is **2.7x faster** at every percentile.

This also settles the scheduler question with real numbers rather than the crate's
self-report. `CONTEXT.md` reasoned from a vendor-published ~71 files/s; the measured
77 docs/s for `rs-trafilatura` confirms it, and `trafilatura`'s 207 docs/s does not
change the conclusion:

```
docs exceeding the ~1ms NIF budget:  rs = 923/925    tr = 915/925
```

**A dirty CPU scheduler is required either way.** ~99% of ordinary documents blow the
budget under both crates. Every constraint `CONTEXT.md` derives from that decision
(uninterruptible calls, bounded VM-wide thread pool, the open question of whether to
impose a concurrency limiter) stands unchanged.

---

## 3. Extraction accuracy, measured

Both crates scored on the **same 960 ground-truth entries** using the **same scoring
code** — a faithful reimplementation of `trafilatura`'s own `comparison_test.rs`.
Ground truth per document is a list of strings that must appear in the extracted
main content (`with`) and strings that must not (`without`).

| Mode | Crate | Precision | Recall | Accuracy | **F-score** |
|---|---|---|---|---|---|
| Balanced | `rs-trafilatura` | 0.860 | 0.904 | 0.878 | **0.881** |
| Balanced | `trafilatura` | 0.908 | 0.919 | 0.913 | **0.913** |
| FavorPrecision | `rs-trafilatura` | 0.859 | 0.892 | 0.873 | 0.875 |
| FavorPrecision | `trafilatura` | 0.920 | 0.902 | 0.912 | 0.910 |
| FavorRecall | `rs-trafilatura` | 0.859 | 0.900 | 0.876 | 0.879 |
| FavorRecall | `trafilatura` | 0.901 | 0.920 | 0.910 | 0.910 |

`trafilatura` wins on every metric in every mode. The precision gap in Balanced mode
(0.908 vs 0.860) means `rs-trafilatura` retains materially more boilerplate — it
extracted 5.3 MB across the corpus to `trafilatura`'s 4.5 MB, and the scoring says
the surplus is largely boilerplate rather than recovered main content.

### 3.1 `rs-trafilatura`'s precision/recall knobs are effectively inert

`CONTEXT.md` names precision-vs-recall "the core tuning axis" that "callers care
about". In `rs-trafilatura` it does not function:

```
rs precision across all three modes:  0.860 / 0.859 / 0.859
rs recall across all three modes:     0.904 / 0.892 / 0.900
```

Setting `favor_precision` moved precision by **−0.001** while costing 0.012 recall —
strictly worse on both axes than leaving it alone. `trafilatura`'s equivalent knob
moves precision 0.908 → 0.920 as documented.

If we bind `rs-trafilatura`, we would be exposing a tuning axis to Elixir callers
that does not do what its name says.

---

## 4. Where `rs-trafilatura` is genuinely better

Stating these plainly, because the recommendation is not unanimous across every axis.
All quantified against the same 925-page corpus.

- **Image extraction — but see §4.2.** An earlier draft of this document claimed
  `trafilatura` "has no equivalent at all". **That was wrong.** Both crates handle
  images; they differ in shape and in precision, and the gap is much smaller than
  raw counts suggest.
- **Publication-date granularity.** Both crates find dates about equally well, and
  scoring against the corpus's own 730 date ground truths shows **accuracy is a
  wash**:

  | | correct | wrong | no date found |
  |---|---|---|---|
  | `rs-trafilatura` | 430 (58.9%) | 72 | 228 |
  | `trafilatura` | 425 (58.2%) | 58 | 247 |

  They are differently wrong (62 pages only `rs` gets right, 57 only `trafilatura`
  does); `trafilatura` is the more conservative of the two — it answers less often
  but is right 88.0% of the time it does, vs 85.7%.

  The real difference is granularity — see §4.1, which is more nuanced than it
  first appears.
- **Richer typed metadata.** `Option<String>` fields vs `trafilatura`'s `String`
  with `""` meaning absent — maps more cleanly onto Elixir `nil`.
- **A `warnings` channel.** `Vec<String>` on every result; `trafilatura` has none.
  Measured, this is thinner than it sounds: **115/925 pages (12%) emit any warning**,
  141 warnings total, and most are strategy telemetry rather than quality signals —
  73 "Used fallback extraction", 38 "Used multi-candidate merge". Only 25 (2.7% of
  pages) report degraded output: 16 "Insufficient content after extraction" and 9
  "Content extraction failed - no main content found". Under `trafilatura` those 25
  arrive as a typed `Err(InsufficientContent { .. })` instead, which is arguably the
  better channel — so what we actually lose is the *telemetry*, not the diagnostics.
- **Dual MIT/Apache-2.0.** `trafilatura` is Apache-2.0 only. Since a NIF statically
  links the crate, the distributed artifact carries Apache-2.0 obligations
  regardless. Not a blocker — Python trafilatura is Apache-2.0 too.

  **Resolved:** this project went Apache-2.0 only rather than keep a dual license
  binary users could not exercise. `LICENSE-MIT` was removed and `LICENSE-APACHE`
  renamed to `LICENSE`. Worth noting for the record that the upstream crate ships
  **no `NOTICE` file**, so Apache-2.0 §4(d) propagation does not apply; and that
  exactly one crate in the 108-crate linked tree is Apache-2.0-only (`trafilatura`
  itself), while four are MPL-2.0 (`cssparser`, `cssparser-macros`, `selectors`,
  `dtoa-short`, reached via `scraper`). Nothing in the tree is GPL/LGPL/AGPL.
- **Markdown without a feature flag.** `content_markdown` is computed into the
  result; `trafilatura` puts it behind the `markdown` feature as a method.

### 4.1 Time-of-day: discarded, not missing — and the day itself is more correct

`trafilatura` carries no time anywhere. This is exhaustive, not just the public
field: every signature in the date pipeline is `NaiveDate` — `extract_date`,
`examine_meta_date`, `json_search_date`, `extract_url_date`, `collect_json_dates`,
`fast_parse_date` — as is `Options.html_date_override`, and the UniFFI layer exposes
`Option<String>` documented as `YYYY-MM-DD`. No `NaiveDateTime`, `DateTime`,
`FixedOffset` or `Timelike` appears in any return type in `src/`.

But it **parses the time and then explicitly discards it**, at two adjacent sites in
`src/metadata/mod.rs`:

```rust
// 1. Try RFC 3339 / ISO 8601 datetime (most common in meta attributes).
//    chrono's parse_from_rfc3339 handles "2020-01-20T09:49:32Z", "+05:30", etc.
if let Ok(dt) = chrono::DateTime::parse_from_rfc3339(s) {
    let d = dt.date_naive();          // <-- offset-aware datetime, narrowed to a day
    ...
if let Ok(dt) = chrono::NaiveDateTime::parse_from_str(s, "%Y-%m-%dT%H:%M:%S") {
    let d = dt.date();                // <-- same
```

So the crate holds exactly the information `rs-trafilatura` holds, at the same point
in the pipeline, and throws it away by narrowing the type. Recovering it is widening
`NaiveDate` → `NaiveDateTime` through ~8 signatures plus `result.rs`, `options.rs`
and the UniFFI mapping — mechanical, and upstreamable. It is not a missing feature.

**And on the calendar day it does keep, `trafilatura` is the more correct of the
two.** `rs-trafilatura` normalises to UTC (`dt.with_timezone(&Utc)`) and reports the
UTC day; `trafilatura` keeps the publisher's local day. Measured on synthetic
timestamps:

| `article:published_time` | `rs-trafilatura` | `trafilatura` |
|---|---|---|
| `2020-01-21T02:00:00+05:30` | 2020-01-**20** 20:30 UTC | 2020-01-**21** |
| `2020-01-20T20:30:00-06:00` | 2020-01-**21** 02:30 UTC | 2020-01-**20** |
| `2020-01-20T09:49:32Z` | 2020-01-20 09:49 UTC | 2020-01-20 |

"Published January 20" means the publisher's January 20. `rs-trafilatura` reports the
wrong publication day for any US-evening or Asia-early-morning article — which likely
explains part of the 34-page calendar-day disagreement measured above.

`trafilatura` additionally validates with `is_plausible_date` (year within
1995..=now+1); `rs-trafilatura` has no equivalent bound and will accept any
syntactically valid date.

Net: the time-of-day gap is real but shallow and fixable, and it comes attached to
*better* date semantics — not worse.

### 4.2 Images: a difference of shape and precision, not presence

`trafilatura` does images. It has `Options.include_images` with a `.with_images(bool)`
builder, `Metadata.image` for `og:image`, `is_image_element` / `is_image_file`
helpers, `DISCARDED_IMAGE` selector rules that drop image-caption containers, and
`img` in its preserved-tags and attribute allowlists.

The difference is **shape**:

- `rs-trafilatura` returns a structured sidecar: `Vec<ImageData>` with `src`,
  `filename`, `alt`, `caption`, `is_hero`.
- `trafilatura` preserves `<img>` **inside `content_html`**, the way go-trafilatura
  and Python trafilatura do. Structure has to come from parsing that fragment.

For our purposes that shape difference is the honest cost — we would parse
`content_html` in Elixir (Floki) to get a structured list. Raw coverage on the
925-page corpus:

| | docs with ≥1 image | images | with `src` | with `alt` | `og:image` |
|---|---|---|---|---|---|
| `rs-trafilatura` | 891 (96%) | 5,696 | — | 3,214 (56%) | 747 (81%) |
| `trafilatura` | 400 (43%) | 1,554 | 1,552 (100%) | 768 (49%) | 734 (79%) |

With `with_images(false)`, `trafilatura` emits 0 `<img>` — the option is doing the
work, not an accident of markup.

**But the 3.7x gap is mostly boilerplate, not recall.** `rs-trafilatura`'s
`extract_images` looks inside the main content node, and *if that yields nothing,
falls back to scanning the entire `<body>`* — which is precisely how you collect
navigation and footer chrome. Of the 4,506 images it returns that `trafilatura` does
not keep, a URL/alt signature match flags 27% as boilerplate outright (vs 20% for
`trafilatura`) and 4% are `data:` URI lazy-load placeholders — stub SVGs whose real
image lives in `data-src`, so they carry no usable URL at all. Inspecting the
remainder, the true share is clearly higher than the matcher catches. A representative
sample:

```
https://zeit.met.vgwort.de/na/586caad5...   alt=""                       # tracking beacon
/media/img/main/socialicons/facebook.png    alt="watson auf Facebook"    # share icon
/media/img/main/socialicons/whatsapp.png    alt="In Whatsapp teilen"     # share icon
/media/img/main/logos/logo_watson.png       alt="Logo watson News"       # site logo
/media/img/main/icons/icon_navi.png         alt="Navigation"             # nav chrome
/media/img/main/weather/w-55.svg?abd        alt="freundlich"             # weather widget
/media/img/main/arrows/arrow_video_play.png alt="abspielen"              # UI control
data:image/svg+xml;charset=utf-8,%3Csvg...  alt="Lotte Tobisch..."       # lazy placeholder
```

This is the same recall-biased behaviour that costs `rs-trafilatura` text precision
in §3 (0.860 vs 0.908), showing up in a second output channel. Its 96%-of-pages
figure is not 96% of pages having extractable content imagery.

Caveat on `is_hero`: it prefers a match against `og:image` but otherwise just marks
the first image, so exactly one per document is always flagged. It is a weak hint,
not a classification — and `Metadata.image` (present on ~80% under **both** crates)
carries the same `og:image` signal directly.

**Net:** the real losses are the structured sidecar (recoverable by parsing
`content_html`), `<figcaption>` captions as a discrete field (329 across the corpus),
and `filename`. Those are modest. What looked like a 96%-vs-nothing gap is closer to
a shape difference plus a precision difference that favours `trafilatura`.

### 4.3 `trafilatura`'s depth guard costs nothing on real pages — measured

On synthetic input the `MAX_TREE_DEPTH = 500` guard is a hard cliff: content nested
deeper than 500 comes back empty, where `rs-trafilatura` still returns it. That made
it look like a correctness-for-safety trade. Measured against real pages, it is not.

Nesting depth of the source HTML across the 925-page corpus:

```
p50=19   p90=31   p99=151   max=1535
deeper than  50:  39/925 (4.2%)
deeper than 500:   3/925 (0.3%)
```

Three pages do nest past 500 in raw markup — but extracting them shows no loss:

| source depth | `rs` bytes | `tr` bytes |
|---|---|---|
| 1535 | 1,501 | 1,498 |
| 581 | 29,366 | 29,782 |
| 549 | 2,418 | 2,414 |

The reason is that the guard applies to the **parsed tree**, not the raw tag stream.
`html5ever` auto-closes unclosed and mis-nested tags during tree construction, so
documents whose markup nests 1,500 deep produce trees far shallower than 500. Deep
raw nesting is a symptom of sloppy markup, not of deeply nested content.

So this is a real limit, but not a practical cost — and it is what buys the §1.1
crash immunity. (The one page in the corpus where `trafilatura` extracts markedly
less than `rs-trafilatura` — `vinosytapas.de.rioja.html`, 1,484 vs 6,925 bytes — sits
at depth 177, well inside the guard, so it is an extraction-strategy difference, not
this.)

---

## 5. Engineering practice

| | `rs-trafilatura` | `trafilatura` |
|---|---|---|
| `cargo build --lib` warnings | **179** | **0** |
| CI clippy | `cargo clippy --lib` (warnings don't fail) | `cargo clippy --locked -- -D warnings` |
| CI lockfile pinning | no | `--locked` throughout |
| Tests | 919, synthetic inline HTML | 521 + 925-doc ground-truth suite |
| HTML fixtures | 5 | 1,077 |
| Accuracy regression gate | none | asserted F-score floors in CI |
| Fidelity ledger | none | `DEVIATIONS.md` |
| Logging in lib code | 32 raw `eprintln!` | `tracing` (15 sites), 0 raw prints |
| `unsafe` | forbidden | none present |
| Cross-language bindings tested in CI | none | Python, Swift, Kotlin |

Both suites pass cleanly on this machine.

Two things stand out beyond the counts:

**`DEVIATIONS.md`.** `trafilatura` maintains an explicit ledger of every intentional
divergence from its Go reference — including naming its two `#[ignore]`d integration
tests and explaining exactly why (`readability-rs` includes comment sections where
`go-readability` does not). Ignoring a test and documenting the reason in the crate's
public deviation record is the behaviour you want from a dependency.

**Ground-truth accuracy gating.** `trafilatura` commits Python trafilatura's own
results (`comparison-data/python_results.jsonl`) alongside its own and asserts
minimum precision/recall/accuracy/F-score in a test. Extraction quality cannot
silently regress. `rs-trafilatura`'s 919 tests are all self-authored assertions over
hand-written HTML snippets — they verify it does what its author expected, never that
it matches the reference implementation.

### 5.1 Lineage

`trafilatura` ports `go-trafilatura`, a mature and independently validated port of
Python trafilatura, and reaches for `justext` and `libreadability` — Rust ports of
the *actual algorithms* Python trafilatura falls back to. The behaviour has been
through two rounds of independent reimplementation against a reference.

`rs-trafilatura` is a direct from-scratch port that additionally invents a
`web-page-classifier` ML page-type classifier with no counterpart in Python
trafilatura. `CONTEXT.md` states the upstream crate's behaviour "is the source of
truth for extraction semantics" — of the two, only `trafilatura` demonstrates
fidelity to that source.

Both crates lean on sibling crates published by their own author days beforehand
(`html-cleaning`/`quick_html2md`/`web-page-classifier` vs
`justext`/`libreadability`/`html2markdown`). That is symmetric and not a
differentiator. Neither pulls C dependencies, network code, or native build scripts
into the default library build — both are clean to compile inside a NIF (92 vs 105
transitive crates).

---

## 6. Consequences for `CONTEXT.md`

Switching crates invalidates much of the current "What the crate forces" section.
Re-decide, don't port over:

- **Error representation.** `trafilatura` *does* return `Err` — I measured
  `Err(InsufficientContent { text_len: 0, comment_len: 0, min_output_size: 1, .. })`
  on an empty document, with structured fields. This settles the open question
  "whether to expose empty-extraction as an error" in the affirmative and removes
  `rs-trafilatura`'s awkward `Ok("")`-plus-warnings shape.
- **`warnings` is gone.** The open question about surfacing warnings in Elixir is
  moot; the glossary entry needs rewriting.
- **Output shape changes.** `content_text` / `content_html` / `comments_text` /
  `comments_html` are all plain `String` (empty = absent), Markdown is a method
  behind a feature flag, and metadata fields are `String` not `Option<String>`.
  Elixir-side `nil` mapping becomes our job.
- **Comments.** Still supported, still opt-in — but via `exclude_comments`
  (inverted sense from `rs-trafilatura`'s `include_comments`).
- **Metadata is still not separable.** One call returns content and metadata
  together; unchanged.
- **The panic/thread-local safety section** is `rs-trafilatura`-specific and should
  be replaced. `catch_unwind` remains mandatory regardless — but note it does *not*
  protect against §1.1-style stack overflow, which is why the depth guard matters.
- **The dirty-scheduler decision stands**, now on measured rather than vendor data.

---

## Method and reproduction

Rust 1.97.1, macOS (darwin 25.5.0), release builds with debug symbols. Both crates
cloned from their upstream repos at the published versions; `.crate` archives exclude
the test corpora. Harnesses are in the session scratchpad:

- `harness/` — adversarial inputs (nesting depth, multi-byte boundary straddling,
  truncation parity sweep) and the corpus latency benchmark. Each adversarial case
  runs as its own process so an uncatchable abort is observable as a signal.
- `stack/` — re-runs extraction on a thread sized to the ERTS dirty-scheduler
  default (320 KiB) rather than the 8 MB main-thread stack.
- `score/` — the head-to-head accuracy scorer; a reimplementation of
  `trafilatura`'s `tests/comparison_test.rs` scoring applied to both crates.
- `conc/` — serial vs. 8-thread output equivalence.
- `feat/`, `deep/`, `dates/` — the §4 feature-cost measurements: nesting-depth
  distribution, warning frequency, image yield, and date scoring against the
  corpus's 730 ground-truth publication dates.

Caveats worth keeping:

- Latency figures are one machine, single run, no warmup control. The 2.7x gap is
  far larger than that noise, but do not quote the absolute ms as a spec.
- Accuracy scoring is substring containment against the corpus's own ground truth.
  It is the metric `go-trafilatura` and `trafilatura` both gate on, which makes it
  the fair shared yardstick — but the corpus ships *with* `trafilatura`, so treat a
  small home-field advantage as possible. The 0.032 F-score gap and the inert-knob
  finding are both larger than plausible bias.
- The two additional `rs-trafilatura` slice panics (§1.2) are statically identified,
  not reproduced.
