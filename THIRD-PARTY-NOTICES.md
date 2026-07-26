# Third-party notices

Precompiled builds of ExTrafilatura statically link the Rust crates below and
therefore redistribute them in object form. Their license terms are reproduced
or referenced here as required.

This file covers bundled third-party code only. ExTrafilatura's own license is
in [LICENSE](LICENSE) — Apache-2.0, the same license as the crate it binds.

> **Not yet authoritative.** The dependency tree below was enumerated from
> `trafilatura` 0.3.0 with the `markdown` feature (108 crates). It should be
> regenerated with `cargo about` or `cargo deny` once `native/` and a committed
> `Cargo.lock` exist, and this notice replaced with generated output.

---

## trafilatura

<https://github.com/nchapman/trafilatura-rs>

Copyright 2026 Nick Chapman. Licensed under the **Apache License, Version 2.0**.

This is the only Apache-2.0-*only* crate in the tree, and it is the reason
precompiled builds carry Apache-2.0 obligations.

ExTrafilatura is itself Apache-2.0, so [LICENSE](LICENSE) carries the same terms
— but under *ExTrafilatura's own* copyright line, not the crate's. It therefore
does not by itself discharge attribution for the bundled crate; the copyright
line above does, together with this document.

The upstream crate does **not** ship a `NOTICE` file, so no NOTICE contents need
to be propagated under Apache-2.0 §4(d).

### Lineage

The Rust `trafilatura` crate is a port of
[go-trafilatura](https://github.com/markusmobius/go-trafilatura) (Apache-2.0),
which is in turn a port of
[trafilatura](https://github.com/adbar/trafilatura), Copyright Adrien Barbaresi
and the Trafilatura contributors, also licensed under the Apache License 2.0.
None of these projects is affiliated with, nor endorses, these Elixir bindings.

---

## Directly relied-upon crates

These implement the extraction pipeline and are linked into every build.

| Crate | License | Source |
| --- | --- | --- |
| `trafilatura` | Apache-2.0 | <https://github.com/nchapman/trafilatura-rs> |
| `justext` | BSD-2-Clause | <https://github.com/nchapman/justext-rs> |
| `libreadability` | MIT | <https://github.com/nchapman/readability-rs> |
| `html2markdown` (`markdown` feature) | MIT | <https://github.com/nchapman/html2markdown-rs> |
| `scraper` | ISC | <https://github.com/rust-scraper/scraper> |
| `ego-tree` | ISC | <https://github.com/rust-scraper/ego-tree> |
| `html5ever` | MIT OR Apache-2.0 | <https://github.com/servo/html5ever> |
| `whatlang` | MIT | <https://github.com/greyblake/whatlang-rs> |

---

## Weak-copyleft dependencies (MPL-2.0)

Four crates reached through `scraper`'s CSS selector support are licensed under
the **Mozilla Public License 2.0**:

- `cssparser`
- `cssparser-macros`
- `selectors`
- `dtoa-short`

MPL-2.0 is file-level copyleft. Linking them into a larger work is permitted and
does not affect the license of ExTrafilatura's own code, but if any MPL-covered
file is modified, the modified file's source must be made available under
MPL-2.0. **We do not modify these crates**; they are consumed unmodified from
crates.io, and their source is available at
<https://github.com/servo/rust-cssparser> and
<https://github.com/servo/servo/tree/main/components/selectors>.

---

## Unicode data crates (Unicode-3.0)

Eighteen ICU crates (`icu_collections`, `icu_normalizer`, `icu_properties`,
`zerovec`, `yoke`, `tinystr`, and related) are licensed under the
**Unicode License v3**, reached via `idna` for URL handling. That license
requires retaining its notice, which this section provides; the full text is at
<https://www.unicode.org/license.txt>.

---

## License distribution across the linked tree

Enumerated across all 108 crates linked with the `markdown` feature:

| Count | License |
| --- | --- |
| 52 | MIT OR Apache-2.0 |
| 18 | Unicode-3.0 |
| 17 | MIT |
| 6 | Apache-2.0 OR MIT |
| 4 | MPL-2.0 |
| 3 | MIT/Apache-2.0 |
| 2 | Unlicense OR MIT |
| 2 | ISC |
| 1 each | Zlib; BSD-2-Clause; Apache-2.0; Zlib OR Apache-2.0 OR MIT; MIT OR Apache-2.0 OR Zlib; (MIT OR Apache-2.0) AND Unicode-3.0 |

No crate in the tree is GPL-, LGPL-, or AGPL-licensed, and none carries a
"no declared license" entry.

Permissive dual-licensed crates (`MIT OR Apache-2.0` and equivalents) are taken
under their MIT terms where offered. Their notices will be reproduced in full by
the generated version of this file.
