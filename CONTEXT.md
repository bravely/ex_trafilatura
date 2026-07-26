# Context: ExTrafilatura

Elixir NIF bindings for `rs-trafilatura` — main content and metadata extraction for web pages, with no Python at deploy time.

> **Seed document.** The library is still scaffolding, so most of this is stated purpose rather than settled design. Terms marked _(provisional)_ haven't been fixed by real code yet. Sharpen this with `/domain-modeling` as decisions land, and record the load-bearing ones as ADRs in `docs/adr/`.

## Why this exists

Python's `trafilatura` is the reference implementation for this kind of extraction, but depending on it from Elixir means shipping a Python runtime — a port, a pool, or a subprocess — into production. This library binds the Rust port instead, so extraction happens in-process over a NIF and deployment stays a single BEAM release.

**No Python at deploy time** is the project's defining constraint. A change that reintroduces a Python dependency in the runtime path defeats the purpose of the library.

## Glossary

- **Extraction** — the whole job: given an HTML document, return the parts a reader actually wants.
- **Main content** — the article body. The thing extraction is trying to keep.
- **Boilerplate** — navigation, sidebars, headers, footers, ads, share widgets, related-post blocks. The thing extraction is trying to drop. "Main content vs boilerplate" is the central distinction in this domain; prefer these two terms over vaguer ones like "the text" or "junk".
- **Metadata** — the descriptive fields about a document rather than its body: title, author, date, site name, description, categories, tags, license. Extracted from a mix of meta tags, JSON-LD, and heuristics over the markup.
- **Comments** — reader comments. Upstream trafilatura treats these as a separate extractable stream from main content, not as boilerplate. _(Provisional — confirm whether `rs-trafilatura` exposes them.)_
- **Precision vs recall** — the core tuning axis. Favouring precision drops more borderline blocks (cleaner output, risks losing real content); favouring recall keeps more (fuller output, risks retaining boilerplate). Callers care about this tradeoff, so name it in these terms rather than as "strict"/"loose".
- **NIF boundary** — the line between Elixir and the Rust crate. Anything crossing it is subject to BEAM scheduler rules: long work must not block a normal scheduler.
- **`rs-trafilatura`** — the upstream Rust crate being bound. Its behaviour is the source of truth for extraction semantics; this library's job is to expose it idiomatically, not to reimplement or second-guess it.

## Open questions

Unresolved. Each of these is an ADR waiting to be written, not a gap to paper over:

- **Error representation** — `{:ok, result}` / `{:error, reason}` tuples, bang variants, or both? What counts as an error versus an empty extraction? A page with no detectable main content is a plausible success-with-nothing rather than a failure.
- **Scheduler strategy** — dirty CPU schedulers, yielding NIFs, or a size threshold that routes large documents differently. Extraction over a big document is not obviously short enough for a normal scheduler.
- **Output shape** — plain text, Markdown, and structured XML are all things upstream trafilatura can emit. Which does this library expose, and is the choice a per-call option or separate functions?
- **Metadata as a separate call** — one function returning content and metadata together, or independent functions so callers can pay only for what they need.
- **Input type** — binary only, or also a URL-fetching convenience layer. Fetching pulls in an HTTP client and a whole class of failure modes that extraction itself doesn't have.

## Conventions

- The public module is `ExTrafilatura`. Bound Rust lives behind it; callers shouldn't need to know a NIF is involved to use the library.
- When naming things in issues, tests, or proposals, use the glossary's terms above. If the concept you need isn't here, that's a signal — either the language is being invented (reconsider) or there's a real gap (note it for `/domain-modeling`).
