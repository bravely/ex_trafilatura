# ADR-0006: Result and error representation for v0.1.0

- **Status:** Accepted
- **Date:** 2026-07-27
- **Ticket:** [#10 Decide the result and error representation](https://github.com/bravely/ex_trafilatura/issues/10)

> **§4's reason for `nil` on `{:language_mismatch, _}` is corrected by
> [#32](https://github.com/bravely/ex_trafilatura/issues/32).** `nil` does **not** identify
> which of the crate's two construction sites fired. The late site emits an empty `got` too
> — `language_classifier` returns `""` when `whatlang` cannot place the text
> (`src/utils/language.rs:106`), and the crate rejects on that rather than passing it
> (`src/lib.rs:266`, "reject even when lang is `""` (unknown)"). So `nil` means *could not
> determine* and nothing more.
>
> **The decision is unchanged** — the term still carries only the detected language, and
> `nil` is still worth keeping for exactly the reason it is *usable*: a caller can tell
> "wrong language" from "no idea what language". What was wrong was the second reason given
> for it, and it is corrected in place below.

> **§5's stub page cannot carry a `<title>`, also per
> [#32](https://github.com/bravely/ex_trafilatura/issues/32).** A document with a `<title>`
> and no body does **not** return `:insufficient_content` — it extracts successfully, with
> the title's own text for a body. The crate's last-resort `baseline` pass falls through to
> the whole document's text content (`src/extraction/baseline.rs:133`), and `<title>` is
> inside it, so any `<title>` at all is enough content to clear the guard.
>
> **The argument in §5 is unchanged**, and so is the limitation it records: a stub page
> whose metadata is entirely in `<meta>` tags — `og:title`, `og:image`, an author — reaches
> `:insufficient_content` and loses all of it. Only the illustration was unbuildable, and it
> is corrected in place below, along with the fixture that Consequences prescribed from it.

## Context

This is the public return contract: what `ExTrafilatura.extract/2` hands back when it
works, and what it hands back when it doesn't. Everything else about the API was settled
by [#11](https://github.com/bravely/ex_trafilatura/issues/11) — a flat keyword list of 13
option keys, `extract/1` and `extract/2`, no bang variant. What crosses back over the NIF
boundary is what remains.

`CONTEXT.md` carried this as two open questions ("How errors map to Elixir", "Empty string
vs `nil`") framed as one trade: how much of the crate's own shape to preserve versus how
idiomatic to make the Elixir surface. Reading `trafilatura` 0.3.0's source with #11's
option set already fixed showed that framing to be a **false trade for most of the
surface** — several of the choices it presents as costly turn out to cost nothing, because
the information supposedly at stake does not exist.

### What the crate actually returns

Six facts, all read from 0.3.0's source, that were not in the ticket:

- **`metadata` is a field on the result, not a sibling return value.** `ExtractResult`
  (`src/result.rs:8`) has five fields: `content_text`, `comments_text`, `content_html`,
  `comments_html`, and `metadata: Metadata`.

- **`Metadata` has 15 fields, not the 8 the ticket listed** (`src/result.rs:55`). Beyond
  title, author, date, sitename, description, categories, tags and license it also carries
  `url`, `hostname`, `language`, `image`, `page_type`, `id` and `fingerprint`.

- **`id` and `fingerprint` are never assigned anywhere in `src`.** `fingerprint` appears
  exactly once in the entire crate — its own declaration at `src/result.rs:66`. They are
  permanently `""`. This is the same species of finding as `enable_log` in #11: a member of
  the public surface that does nothing, discoverable only by reading the source.

- **`InsufficientContent`'s payload is four constants.** `Config::default()` sets
  `min_output_size: 1` and `min_output_comment_size: 1` (`src/options.rs:63-64`), and #11
  omitted `config` from the options surface, so the guard at `src/lib.rs:245` is
  `len_text < 1 && len_comments < 1`. It fires only when the document yields **literally
  zero characters of both streams**, which means the error always carries
  `text_len: 0, comment_len: 0, min_output_size: 1, min_output_comment_size: 1`. Four
  typed fields, zero information.

- **`MissingMetadata(String)` is a closed set of three.** It is constructed at exactly
  three sites — `"title"`, `"url"`, `"date"` (`src/lib.rs:163`, `:166`, `:169`) — checked
  in that order, and only when `has_essential_metadata` is set. The `String` is an
  enumeration wearing a string's clothes.

- **`LanguageMismatch` has two construction sites, and `got` carries two different
  failures.** `src/lib.rs:151` is the pre-extraction check on the document's declared
  language and sets `got: String::new()` unconditionally; `src/lib.rs:269` carries the
  verdict of `language_classifier` over the extracted text. So `got == ""` means *could not
  determine* and `got == "de"` means *determined, and wrong* — two different failures. Its
  `expected` field is the caller's own `target_language`, echoed back.

  **The two distinctions do not line up**, and #32 found the ADR originally implying they
  did. `language_classifier` returns `""` when `whatlang` fails
  (`src/utils/language.rs:106`) and the late site rejects on that rather than passing it
  (`src/lib.rs:266-268`), so an empty `got` comes back from **both** sites. Which site
  fired is not observable, and nothing downstream needs it to be.

### What the payloads are worth

Laying the five error sources against what the caller already holds:

| error | payload | information to the caller |
|---|---|---|
| `InsufficientContent` | `text_len`, `comment_len`, `min_output_size`, `min_output_comment_size` | **none** — all four are constants |
| `MissingMetadata` | one of `"title"` / `"url"` / `"date"` | **real**, closed set |
| `LanguageMismatch` | `expected`, `got` | `expected` is an echo; `got` is **real** |
| oversized input ([ADR-0001](0001-resource-safety-posture.md) §3) | actual size, permitted size | **none** — `byte_size/1` and the caller's own `max_input_bytes` |
| invalid UTF-8 ([ADR-0005](0005-utf8-input-contract.md) §3) | byte offset | **real**, and free from the mechanism |

Three of five payloads are constants or echoes. The ticket's "flat and idiomatic versus
structured and informative" is therefore not the axis; **the axis is whether a given
payload says anything at all.**

### Inherited constraints

- [ADR-0001](0001-resource-safety-posture.md) §3 fixes that there is a sixth,
  Elixir-originated error for oversized input, and leaves its term here.
- [ADR-0005](0005-utf8-input-contract.md) §3 fixes the reason `:invalid_utf8` and leaves
  its payload here, with a warning attached: `rest` from
  `:unicode.characters_to_binary/3` is a **sub-binary over the input**, so carrying the
  offending bytes would retain up to 10 MB against GC for a three-byte diagnostic.
- [#11](https://github.com/bravely/ex_trafilatura/issues/11) fixes the invariant that
  **exceptions mean exactly one thing: you called it wrong.** Everything that arrives from
  the network at runtime is a return value, never a raise.
- [#11](https://github.com/bravely/ex_trafilatura/issues/11) §5 fixes that crate names are
  used verbatim, mixed senses and all, so the caller can read the crate's own docs.
- [#7](https://github.com/bravely/ex_trafilatura/issues/7) measured result encoding at
  **≤2% on top of extraction at every size**, so a rich result shape is free, and found
  that Rustler 0.38 already wraps NIF bodies in `catch_unwind` but **discards the panic
  payload**, leaving Elixir a bare `:nif_panicked` while the message goes to OS stderr
  rather than `Logger`. It left the term for any guard of ours to this decision.

## Decision

**Two nested structs on success. Seven error reasons on failure, generated by a single
rule: the term carries exactly what the caller does not already have.**

### 1. Two structs, nested, mirroring the crate

```elixir
@spec extract(binary(), keyword()) :: {:ok, ExTrafilatura.Result.t()} | {:error, reason()}
```

```elixir
%ExTrafilatura.Result{
  content_text:  String.t(),
  comments_text: String.t(),
  content_html:  String.t(),
  comments_html: String.t(),
  metadata:      ExTrafilatura.Metadata.t()
}
```

Structs rather than plain maps. `#[non_exhaustive]` cuts *for* a struct rather than
against it: upstream adding a field is one `defstruct` line for us and additive for callers
either way, while a struct buys a documented field list in ExDoc, a `@type t()` for
Dialyzer, and a compile error on `%Result{content_txt: x}` where the equivalent map pattern
would silently never match. The cost is that neither struct is `Jason.encode`able without a
`@derive` we are not taking a dependency to add — `Map.from_struct/1` away, and not worth a
dependency in a 0.x.

Metadata stays **nested**, because that is where the domain draws the line. `CONTEXT.md`'s
glossary defines *Metadata* against *main content* — "the descriptive fields about a
document rather than its body" — and flattening would put `title` and `content_html` at the
same level in a 19-field struct, dissolving the one distinction the domain insists on. It
also matches the crate.

Named `Result` rather than `Extraction` or `Document`. `Extraction` is the glossary's word
for the **act**, so a struct by that name collides with the verb; `Document` is wrong on
the merits, since #7 established `{:ok, _}` never meant "this was a web page". `Result`
mirrors `ExtractResult` and collides with nothing in Elixir's stdlib.

### 2. Thirteen metadata fields — `id` and `fingerprint` omitted

```elixir
%ExTrafilatura.Metadata{
  title:       String.t() | nil,
  author:      String.t() | nil,
  url:         String.t() | nil,
  hostname:    String.t() | nil,
  description: String.t() | nil,
  sitename:    String.t() | nil,
  date:        Date.t()   | nil,
  categories:  [String.t()],
  tags:        [String.t()],
  license:     String.t() | nil,
  language:    String.t() | nil,
  image:       String.t() | nil,
  page_type:   String.t() | nil
}
```

Crate spellings verbatim per #11 §5 — `sitename` is one word in the crate, and
`page_type` is the raw `og:type` / JSON-LD `@type`. `date` is `Date.t()`, mapping
`chrono::NaiveDate`; #11 already types the `html_date_override` **input** key as
`Date.t()`, so the two sides agree.

`id` and `fingerprint` are omitted for the reason #11 omitted `enable_log`: **curate on
behaviour, not on the field list.** A field that is permanently `""` is indistinguishable
from "this document didn't have one" — a caller writing `if meta.fingerprint != ""` finds
it never fires and concludes no page on the web has a fingerprint. This is ADR-0005 §1's
asymmetry in a different costume: a silent wrong answer versus a loud absence. Absence is
loud (a `KeyError`, or no such field to reach for), and it is the reversible direction —
restoring a field is additive.

Considered and rejected: shipping all 15 verbatim, on the argument that a 1:1 mapping is
trivially auditable and that upstream wiring `fingerprint` up would then work with no
release from us. Since [ADR-0002](0002-vendor-the-patched-rust-crate.md) vendors the crate,
upstream cannot wire anything up without a deliberate re-vendor on our part, so that second
benefit does not exist.

### 3. Absent is `""` on `Result` and `nil` on `Metadata`

One rule per struct, falling on the same content/metadata line the nesting draws:

> `Result`'s four streams are always binaries. `Metadata`'s string fields are `nil` when
> absent. Lists are `[]`; `date` is `nil`.

The premise that made this look expensive is false. **The crate cannot distinguish empty
from absent** — `<title></title>` and no `<title>` at all both produce `""` — so mapping
`""` to `nil` destroys no information, because there is none to destroy. That removes the
standing objection that `""` is a legitimate extracted value the translation would erase.

Uniformity was rejected in both directions, on ergonomics:

- **`nil` everywhere** makes `content_text` nilable. That is the field every caller
  touches on every call, so every caller must write `(result.content_text || "")` forever
  — and because it is `nil` only in the rare comments-only case, the ones who don't have
  shipped a latent crash. `CONTEXT.md` names joining the two streams as a real use case
  (166 of 168 pages disjoint), and `content_text <> comments_text` must not be a landmine.
- **`""` everywhere** breaks `metadata.author || "Unknown"`, the idiom that field exists
  to serve, because `""` is truthy. It fails silently and reads as correct.

The ticket's instinct was "decide once, apply uniformly". Uniformity is the wrong master
here: the two structs are used differently — one with string operations, one with defaults
and pattern matching — and the rule that respects that is no harder to remember, because it
is stated per struct rather than per field.

### 4. Seven error reasons, generated by one rule

```elixir
@type reason ::
        :input_too_large                            # Elixir pre-flight — ADR-0001 §3
      | {:invalid_utf8, non_neg_integer()}          # Elixir pre-flight — ADR-0005 §3
      | :insufficient_content
      | {:missing_metadata, :title | :url | :date}
      | {:language_mismatch, String.t() | nil}
      | {:panic, String.t()}
      | {:unknown, String.t()}
```

Checked in that order, which is ADR-0005 §2's ordering extended: size cap, then encoding
gate, then the NIF.

**The rule is: carry exactly what the caller does not already have.** Flat where the
payload is constants or an echo of the caller's own input; a tagged tuple where it is
information the caller lacks. This is derivable rather than case-by-case, and it stays
correct under change — the day `config` is exposed and the minimums stop being constants,
`insufficient_content` grows a payload by the same rule that denies it one today.

Applied:

- `:insufficient_content` and `:input_too_large` are **bare atoms**, because their
  payloads are the constants and echoes tabulated above.
- `{:missing_metadata, :title | :url | :date}` carries an **atom, not the crate's string**.
  The set is closed at three by construction, and an atom is what a closed set of three
  is in Elixir.
- `{:language_mismatch, String.t() | nil}` carries **only the detected language**. The
  echoed `expected` is dropped by the rule, and `nil` preserves the one distinction the
  payload is worth having: `nil` is "could not determine", a binary is "determined, and
  wrong". It says nothing about *which* construction site fired, because an empty `got`
  reaches it from both — see the correction at the head of this document.
- `{:invalid_utf8, non_neg_integer()}` carries **the byte offset only**. It is free from
  the mechanism (`byte_size(accepted)`), and taking the offset rather than the bytes
  sidesteps ADR-0005 §3's sub-binary retention hazard entirely — an integer retains
  nothing.

Every payload is a single value. No error term is a map.

**An exception struct was considered and rejected.** `{:error, %ExTrafilatura.Error{}}`
would buy a uniform shape and a free `Exception.message/1`, but #11 already declined a bang
variant, so the raise path it exists to serve has no caller — leaving only a verbose thing
to pattern-match against.

### 5. "Nothing extracted" stays an error

`{:error, :insufficient_content}`, not a normalised `{:ok, empty_result}`.

#11 leaned the other way in passing, arguing against a bang variant on the grounds that
`InsufficientContent` "is what a page with no article legitimately returns" — which is
true, and is not sufficient. The construction site decides it: `src/lib.rs:245` returns
`Err` **before `ExtractResult` is ever constructed**, and `meta` — already fully populated,
since metadata extraction runs first in the pipeline — is dropped. There is no partial
result to normalise to. Normalising means **fabricating** one:

```elixir
{:ok, %Result{content_text: "", metadata: %Metadata{title: nil, ...}}}
```

For a stub page that genuinely carries `og:title`, `og:image` and a JSON-LD author, that
return value is a lie: it asserts the document had no title when it did.
`{:error, :insufficient_content}` asserts only that nothing came back, which is true.

The metadata has to be in `<meta>` tags for this page to exist at all, and that is a fact
about the crate rather than a convenience of the example: a `<title>` element's text is
itself content the `baseline` pass will extract, so a document carrying one never reaches
this error. See the correction at the head of this document.

The information loss is real and is recorded as a limitation below, not papered over.

### 6. The catch-all is `{:unknown, message}`

`TrafilaturaError` is `#[non_exhaustive]`, so the Rust-side match must be total. Four
variants fall into that bucket **today**, not hypothetically: `DuplicateContent` and
`TreeTooLarge` are unreachable by construction because #11 omitted both arming options, and
`ParseError` and `Io` are vestigial in 0.3.0.

`thiserror` generates a `Display` impl for every variant, so `e.to_string()` yields
`"output tree too large: 4231 elements"` from a single match arm, with no maintenance as
variants come and go, and a bug report arrives in the crate's own words.

**The string is diagnostic, not contract.** It is documented as such: never match on it.

Considered and rejected: pre-mapping the four known-but-unreachable variants to real atoms.
It is cheap in Rust and would make enabling `deduplicate` in 0.2.0 a smaller change, but it
ships four code paths no test can reach — and #11's posture is to omit what cannot happen
rather than carry it speculatively.

### 7. A panic guard of our own, returning `{:panic, message}` and logging it

`CONTEXT.md` parked this here explicitly: after #7 disproved that a panic takes down a
scheduler, a guard became an API choice rather than a safety one, "and the error term it
should produce belongs to the error-representation decision".

We take the guard. Our own `catch_unwind` inside the NIF body downcasts the payload and
returns `{:error, {:panic, message}}`, recovering the message Rustler discards. In Elixir,
receiving that term also emits a `Logger.error` naming the crate and pointing at our issue
tracker.

Two arguments carry it. **Consistency**: #11 fixed that exceptions mean "you called it
wrong", and a panic triggered by a hostile document off the network is not caller error —
ADR-0001 §3 made exactly this move for oversized input ("arrives from the network at
runtime, so it is a condition, not a caller bug"). **Diagnosability**: today the panic text
goes to OS stderr through Rust's default hook, which is not `Logger` and is invisible in
most deployments.

The `Logger.error` is what answers the real objection — that demoting a panic to
`{:error, _}` drops it into the same `case` clause as "no article on this page", where a
`_ -> :skip` swallows a crate bug forever. #11 declined per-call log noise, but that was
for option typos, a routine event. A panic is not routine, and this is the one place where
noise is the point.

Unwind safety is **satisfied rather than merely asserted**: extraction is a pure function
over a `&str`, and #7 verified serial and 8-thread runs over 300 documents are
byte-identical, so there is no observable state to leave inconsistent.

The guard's limit is unchanged and already documented: `catch_unwind` does not catch stack
overflow or abort. That is what the crate's `MAX_TREE_DEPTH = 500` bound is for, and why
the alternative crate was rejected.

### 8. The `"" → nil` mapping happens in Rust, at encode time

Not as a post-processing pass in Elixir. One pass instead of two, and it avoids allocating
empty binaries only to discard them. #7 measured result encoding at ≤2% of extraction at
every size, so there is headroom either way; this is the cheaper of two cheap options, and
it keeps the Elixir side free of a traversal that exists only to undo something.

## Consequences

- **[#22](https://github.com/bravely/ex_trafilatura/issues/22) and
  [#13](https://github.com/bravely/ex_trafilatura/issues/13) are unblocked.** #22 inherits
  a documentation obligation with three parts: the per-struct `""`/`nil` rule, the seven
  error reasons as a documented set, and the two omitted metadata fields explained rather
  than silently absent.

- **`CONTEXT.md`'s "Open questions" loses two of its four.** "How errors map to Elixir" and
  "Empty string vs `nil`" are both settled here. Images and upstream time-of-day remain.

- **The every-push suite gains fixtures**, all handwritten minimal HTML and therefore
  inside [ADR-0003](0003-verification-posture.md) §3 without amending it: an empty document
  asserting `{:error, :insufficient_content}`; a document whose `og:title`, `og:image` and
  author are all it carries asserting the same, which **pins §5's limitation** rather than
  its fix; `has_essential_metadata: true` against documents missing title, url and date in
  turn, asserting the checking order; `target_language` against both `LanguageMismatch`
  sites, asserting `nil` where nothing determined a language and a binary where the
  classifier did — a fixture per site, but **not** a claim that the payload identifies the
  site, per the correction at the head of this document; and a metadata document asserting
  `nil` for absent fields against `""` for present-but-empty streams.

- **ADR-0003's borrowed-expectation lever survives with one mechanical translation.** #11
  defined `extract/1` to equal `Options::default()`, letting upstream's inline-HTML unit
  tests supply our expectations. Those tests assert `assert_eq!(meta.title, "")`; ours
  assert `assert metadata.title == nil`. The mapping is total and one-directional, so it
  is a rewrite rule, not a porting problem.

- **Two error terms are unreachable in v0.1.0's test suite.** `{:panic, _}` requires a
  panic the vendored crate has been patched to prevent, and `{:unknown, _}` requires a
  variant nothing constructs. Both can be exercised in Rust unit tests inside the NIF crate
  against a synthetic error value; neither can be reached through `extract/2`. This is
  stated so their absence from coverage reads as a known consequence rather than a gap.

- **Adding a metadata field later is additive; removing one is not.** Which is the whole
  argument for §2, and the reason to prefer omitting on the way in.

### Known limitations, with tripwires

Following [ADR-0005](0005-utf8-input-contract.md) §8 and
[ADR-0003](0003-verification-posture.md) §7's practice of naming the condition rather than
settling it on release day:

> **`:insufficient_content` discards metadata the crate had already extracted.** A page
> with an `og:title`, an author and an `og:image` but no text anywhere in it returns an
> error carrying none of it. Recovering it means patching the vendored crate to return a
> partial result instead of `Err` — which changes extraction semantics, and
> [ADR-0002](0002-vendor-the-patched-rust-crate.md) §5 requires its own ADR for that. **This
> reopens if that patch is ever written**, and it is the strongest candidate we have for
> one.

> **`{:unknown, _}` currently absorbs four real variants.** `DuplicateContent` and
> `TreeTooLarge` **get real atoms the day #11's `deduplicate` or `max_tree_size` ships** —
> that is the tripwire, and it is in our own hands rather than upstream's.
