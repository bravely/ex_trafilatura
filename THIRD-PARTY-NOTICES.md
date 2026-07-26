# Third-party notices

Precompiled builds of ExTrafilatura statically link the Rust crates below and
therefore redistribute them in object form. Their license terms are reproduced
here as required.

This file covers bundled third-party code only. ExTrafilatura's own license is
in [LICENSE-APACHE](LICENSE-APACHE) and [LICENSE-MIT](LICENSE-MIT).

---

## rs-trafilatura

<https://github.com/Murrough-Foley/rs-trafilatura>

Available under `MIT OR Apache-2.0`. Reproduced below under the MIT terms.

```
MIT License

Copyright (c) 2025-2026 Murrough Foley

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

### Lineage

rs-trafilatura is a Rust port of
[trafilatura](https://github.com/adbar/trafilatura), Copyright Adrien Barbaresi
and the Trafilatura contributors, licensed under the Apache License 2.0, and of
[go-trafilatura](https://github.com/markusmobius/go-trafilatura). Neither
project is affiliated with, nor endorses, these Elixir bindings.

---

## Transitive dependencies

rs-trafilatura pulls in further crates that are also linked into precompiled
builds. This file will be regenerated to cover them once the Cargo dependency
tree is committed — `cargo about` or `cargo deny` can produce the list.
