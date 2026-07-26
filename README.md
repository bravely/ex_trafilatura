# ExTrafilatura

Main content and metadata extraction for web pages — a Rust port of
[Trafilatura][trafilatura], exposed to Elixir through [Rustler][rustler].

> **Status: early development.** Nothing is implemented yet, and the package is
> not on Hex.

## What it does

Given the raw HTML of a page, Trafilatura returns the article body plus
metadata — title, author, date, site name — and discards navigation, sidebars,
boilerplate, and ads. It ranks among the best extractors in published
benchmarks, which is why it's worth porting rather than reimplementing.

## Why a Rust port

Trafilatura is Python. Calling it from Elixir means shelling out to an
interpreter, running a sidecar, or embedding Python in the release — each of
which puts a Python runtime and its dependency tree into every deploy target,
for what is fundamentally a pure function from HTML to text.

As a Rust NIF, the extractor ships inside the Elixir release instead: nothing
external to install, pin, or keep alive.

## Relationship to upstream Trafilatura

An independent port, not affiliated with or endorsed by the Trafilatura
project.

The goal is behavioural fidelity: same HTML and equivalent settings should
yield the same extraction as upstream. Undocumented divergence is a bug.

## Installation

Not yet published to Hex.

## Development

Requires Elixir and a Rust toolchain. Build and test instructions will land
once the port is underway.

## Contributing

Issues and pull requests welcome. Since this is a port rather than a new
design, the most useful contribution is a failing test case where extraction
differs from Trafilatura's output.

## License

Apache License 2.0 — see [LICENSE](LICENSE). Trafilatura is Copyright Adrien
Barbaresi and the Trafilatura contributors, also under Apache-2.0; the
attribution this port inherits is recorded in [NOTICE](NOTICE).

[trafilatura]: https://github.com/adbar/trafilatura
[rustler]: https://github.com/rusterlium/rustler
