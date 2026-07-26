# ExTrafilatura

Main content and metadata extraction for web pages — a Rust port of
[Trafilatura][trafilatura], exposed to Elixir through [Rustler][rustler].

> **Status: early development.** Nothing is implemented yet. The package is not
> on Hex and there is no usable API. This repository currently exists to hold
> the port as it gets written.

## What it does

Trafilatura takes the raw HTML of a web page and returns the part a reader
actually cares about — the article body — along with metadata such as title,
author, publication date, and site name. It discards navigation, sidebars,
boilerplate, and ads.

It is one of the strongest performers in published main-content extraction
benchmarks, which is why it is worth porting rather than reimplementing from
scratch.

## Why a Rust port

Trafilatura is a Python library. Calling it from Elixir means one of:

- shelling out to a Python interpreter,
- running a Python sidecar service, or
- embedding Python in the release.

All three put a Python runtime, its version constraints, and its dependency
tree into every deploy target — a lot of operational surface for what amounts
to a pure function from HTML to text.

Porting the extraction logic to Rust and loading it as a NIF removes that
entirely: the extractor becomes part of the Elixir release, with no external
runtime to install, pin, or keep alive.

## Relationship to upstream Trafilatura

This is an independent port. It is not affiliated with, endorsed by, or
maintained by the Trafilatura project.

The goal is behavioural fidelity: given the same HTML and equivalent settings,
this library should produce the same extraction as upstream Trafilatura. Where
it diverges, that is a bug in this port unless documented otherwise.

## Installation

Not yet published to Hex.

## Development

Requires Elixir and a Rust toolchain. This section will cover the build and
test workflow once the port is underway.

## Contributing

Issues and pull requests are welcome. Because this is a port rather than a new
design, the most valuable contributions are ones that improve fidelity to
upstream — failing test cases where extraction differs from Trafilatura's
output are especially useful.

## License

Apache License 2.0 — see [LICENSE](LICENSE) and [NOTICE](NOTICE).

Trafilatura is Copyright Adrien Barbaresi and the Trafilatura contributors,
and is also Apache-2.0 licensed. The Apache-2.0 attribution requirements this
port inherits from upstream are recorded in [NOTICE](NOTICE).

[trafilatura]: https://github.com/adbar/trafilatura
[rustler]: https://github.com/rusterlium/rustler
