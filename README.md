# ExTrafilatura

Main content and metadata extraction for web pages. Elixir bindings for the Rust
[trafilatura][trafilatura-rs] crate, loaded as a NIF via [Rustler][rustler].

> **Status: early development.** Nothing is implemented yet, and the package is
> not on Hex.

## What it does

Given the raw HTML of a page, the extractor returns the article body plus
metadata — title, author, date, description, categories, tags — and discards
navigation, sidebars, boilerplate, and ads. Reader comments come back as a
separate stream, and content is available as plain text, cleaned HTML, or
Markdown.

This library makes that available to Elixir. It is a binding layer: extraction
logic lives upstream, not here.

## Why a NIF

The reference implementation, [Trafilatura][trafilatura-py], is Python. Calling
it from Elixir means shelling out to an interpreter, running a sidecar, or
embedding Python in the release — each of which puts a Python runtime and its
dependency tree into every deploy target, for what is fundamentally a pure
function from HTML to text.

[trafilatura][trafilatura-rs] is a Rust port of that work, so binding to it as a
NIF ships the extractor inside the Elixir release instead: nothing external to
install, pin, or keep alive.

## How this relates to upstream projects

Four layers, each independent of the others:

| Project | Role |
| --- | --- |
| [trafilatura][trafilatura-py] (Python) | Original implementation and reference behaviour |
| [go-trafilatura][go-trafilatura] (Go) | Port of that behaviour |
| [trafilatura][trafilatura-rs] (Rust) | Port of the Go implementation |
| **ExTrafilatura** (Elixir) | NIF bindings for the Rust crate |

This project is not affiliated with or endorsed by any upstream.

Practically, this splits bug reports: *what* gets extracted from a page is the
Rust crate's behaviour and belongs in [its tracker][trafilatura-rs-issues].
Anything about the Elixir API, type conversion across the NIF boundary, build,
or packaging belongs here.

> **Naming.** "Trafilatura" refers to several projects. In this repository,
> unqualified `trafilatura` means the Rust crate we bind; the Python original is
> "Python trafilatura". A second, unrelated Rust port called `rs-trafilatura`
> exists and is **not** what this binds — see
> [docs/research/crate-comparison.md](docs/research/crate-comparison.md) for why.

## Installation

Not yet published to Hex.

## Development

Requires Elixir and a Rust toolchain. Build and test instructions will land
once the bindings exist.

## Contributing

Issues and pull requests welcome — see the split above for where extraction
problems should go.

## License

Licensed under the [Apache License 2.0](LICENSE).

This matches the crate it binds and the whole upstream lineage — the Rust
`trafilatura` crate, `go-trafilatura`, and Python trafilatura are all
Apache-2.0. Since a NIF statically links its Rust dependencies, precompiled
builds are a combined work that must satisfy Apache-2.0 anyway; licensing this
project the same way keeps source and binary terms identical instead of offering
a choice that binary users could not actually exercise.

Unless you state otherwise, any contribution you intentionally submit for
inclusion in this project shall be licensed as above, without additional terms
or conditions.

**Note on binary distributions.** Beyond Apache-2.0, several transitive
dependencies carry MPL-2.0, Unicode-3.0, and other terms that apply to the
precompiled artifact. Details and reproduced notices are in
[THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md).

[trafilatura-py]: https://github.com/adbar/trafilatura
[go-trafilatura]: https://github.com/markusmobius/go-trafilatura
[trafilatura-rs]: https://github.com/nchapman/trafilatura-rs
[trafilatura-rs-issues]: https://github.com/nchapman/trafilatura-rs/issues
[rustler]: https://github.com/rusterlium/rustler
