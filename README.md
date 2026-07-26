# ExTrafilatura

Main content and metadata extraction for web pages. Elixir bindings for
[rs-trafilatura][rs-trafilatura], loaded as a NIF via [Rustler][rustler].

> **Status: early development.** Nothing is implemented yet, and the package is
> not on Hex.

## What it does

Given the raw HTML of a page, rs-trafilatura returns the article body plus
metadata — title, author, date, description, categories — and discards
navigation, sidebars, boilerplate, and ads. It also classifies page type,
scores its own extraction confidence, and can emit Markdown.

This library makes that available to Elixir. It is a binding layer: extraction
logic lives upstream, not here.

## Why a NIF

The reference implementation, [Trafilatura][trafilatura], is Python. Calling it
from Elixir means shelling out to an interpreter, running a sidecar, or
embedding Python in the release — each of which puts a Python runtime and its
dependency tree into every deploy target, for what is fundamentally a pure
function from HTML to text.

rs-trafilatura is a Rust port of that work, so binding to it as a NIF ships the
extractor inside the Elixir release instead: nothing external to install, pin,
or keep alive.

## How this relates to upstream projects

Three layers, each independent of the others:

| Project | Role |
| --- | --- |
| [trafilatura][trafilatura] (Python) | Original implementation and reference behaviour |
| [rs-trafilatura][rs-trafilatura] (Rust) | Port of that behaviour, plus page-type classification and quality scoring |
| **ExTrafilatura** (Elixir) | NIF bindings for rs-trafilatura |

This project is not affiliated with or endorsed by either upstream.

Practically, this splits bug reports: *what* gets extracted from a page is
rs-trafilatura's behaviour and belongs in
[its tracker][rs-trafilatura-issues]. Anything about the Elixir API,
type conversion across the NIF boundary, build, or packaging belongs here.

## Installation

Not yet published to Hex.

## Development

Requires Elixir and a Rust toolchain. Build and test instructions will land
once the bindings exist.

## Contributing

Issues and pull requests welcome — see the split above for where extraction
problems should go.

## License

Apache License 2.0 — see [LICENSE](LICENSE). rs-trafilatura is Copyright
Murrough Foley under `MIT OR Apache-2.0`; attribution for it and for the
upstream Python project is recorded in [NOTICE](NOTICE).

[trafilatura]: https://github.com/adbar/trafilatura
[rs-trafilatura]: https://github.com/Murrough-Foley/rs-trafilatura
[rs-trafilatura-issues]: https://github.com/Murrough-Foley/rs-trafilatura/issues
[rustler]: https://github.com/rusterlium/rustler
