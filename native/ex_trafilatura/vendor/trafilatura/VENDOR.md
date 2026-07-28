# Vendored `trafilatura`

This directory is a copy of the `trafilatura` crate with two patches applied. It
is not the published crate, and it is not a fork: the patches live next door in
`../patches/`, and this tree is what you get by applying them to the pristine
tarball. [ADR-0002](../../../../docs/adr/0002-vendor-the-patched-rust-crate.md)
records why we carry it at all.

## Provenance

| | |
|---|---|
| Upstream repository | <https://github.com/nchapman/trafilatura-rs> |
| Exact source | the crates.io tarball, <https://static.crates.io/crates/trafilatura/trafilatura-0.3.0.crate> |
| sha256 | `eb6f4be2db656bb2360d2dc9e575c3cf42ee8197558ba7a2df1e0daf0e1be8f7` |
| Upstream version | 0.3.0 |
| Vendored version | `0.3.0+extrafilatura.1` |
| Date vendored | 2026-07-27 |
| Licence | Apache-2.0, see `LICENSE` |

The **tarball** is the source, not a git checkout — it is what `cargo` would
have fetched, it is content-addressed by the sha256 above, and it is what the
integrity check re-fetches.

`0.3.0+extrafilatura.1` is semver build metadata: ignored for resolution, so it
still satisfies the `trafilatura = "0.3"` requirement in `../../Cargo.toml`, but
printed by `cargo tree`. Without it, `cargo tree` and SBOM tooling would report
this patched copy as stock 0.3.0.

### What was dropped

`Cargo.toml`, `src/` and `LICENSE` are kept — everything the crate needs to
compile, since it has no `build.rs` and no `include_str!`/`include_bytes!`.

Dropped: `comparison-data/` (3.4 MB of expected results whose inputs the crate's
own `exclude` removes from the tarball), `tests/` (not runnable without them),
`Cargo.lock`, `Cargo.toml.orig`, `README.md`, `DEVIATIONS.md`, `Makefile`,
`.github/`, and the Python tooling files. The 925-page corpus is upstream's;
anyone who needs it can clone `nchapman/trafilatura-rs` directly.

`Cargo.toml` still declares `[[test]]` and `[[bin]]` targets whose files are
gone. Cargo does not build those for a dependency, so this is inert — and
leaving the manifest untouched except by a named patch is worth more than
tidiness.

`cargo vendor`'s `.cargo-checksum.json` is deliberately **not** here. It only
engages for registry source replacement, not `path` dependencies, and where it
is checked, patched files fail verification. The sha256 above documents the
base instead.

## Patches

Applied in order, from `../patches/`:

| Patch | What | Upstream |
|---|---|---|
| `0001-bump-deps-upstream-pr-2.patch` | `ego-tree` 0.10→0.11, `html5ever` 0.36→0.39, `scraper` 0.25→0.26, `tendril` 0.4→0.5, fixing an `unwrap()` on `None` in `dom::tree::remove`. Also carries the `+extrafilatura.1` version marker. | issue [#1](https://github.com/nchapman/trafilatura-rs/issues/1), PR [#2](https://github.com/nchapman/trafilatura-rs/pull/2) |
| `0002-fix-char-boundary-panic.patch` | `fast_parse_date` sliced `s[..8]` behind a byte-length guard, so a multi-byte character straddling byte 8 panicked. Reachable from a meta tag in an untrusted document. | not reported upstream as of 2026-07-27; reporting it is [#40](https://github.com/bravely/ex_trafilatura/issues/40) |

**Patch `0001` moves this crate's own dependency edge and nothing else.**
`justext` and `libreadability` — the external fallback extractors — pin
`ego-tree` 0.10, `scraper` 0.25 and `html5ever` 0.36 themselves, so a build
links both stacks; `cargo tree` shows the pair. The panic upstream #1 reports is
in this crate's `dom::tree::remove`, which now uses 0.11, so the fix holds.
Whether the fallback path can reach the same defect through its own copy is
unexamined.

Both patched files — `Cargo.toml` and `src/metadata/mod.rs` — carry a
modification notice at the top. That is an Apache-2.0 §4(b) obligation, since
precompiled builds distribute this modified work in object form.

**Bug fixes land as ordinary patches. Anything that changes extraction or
metadata semantics needs its own ADR first** (ADR-0002 §5). A vendor directory
is exactly where "the crate's behaviour is the source of truth" erodes one
convenient patch at a time.

## Verifying this directory

```sh
tools/verify/vendor-integrity.sh
```

It re-fetches the tarball, checks it against the sha256 above, applies the
patches in order, and diffs the result against this directory. Empty diff or
fail, on every push. What it is guarding against, and why it runs that often,
is in [`tools/verify/README.md`](../../../../tools/verify/README.md).

It reads the version and the sha256 out of the table above, so those rows are
load-bearing rather than decorative.

## Re-vendoring

Check upstream at each ExTrafilatura release: has it moved, are any of our
patches now redundant (ADR-0002 §5). This is a line in the release checklist,
not an automated watch — Dependabot cannot track a patched path dependency.

- **Upstream ships PR #2 as 0.3.1** → drop patch `0001`, re-vendor, keep `0002`,
  bump the marker to `+extrafilatura.2`. Note that `0001` is also what carries
  the marker and the Cargo.toml modification notice today, so dropping it means
  writing a small replacement patch for those.
- **Upstream carries both fixes** → delete this directory, the `patches/`
  directory and the `[patch.crates-io]` block, and go back to a plain crates.io
  dependency. The vendored state is a liability we accept, not an asset we
  build.

Whatever the case, re-run the differential harness: the patched crate's output
is only known to match published 0.3.0 as far as the last run below proves.

## Verification

Per-re-vendor drift results, recorded here because the drift result is a
property of *the vendored state* (ADR-0003 §9). Each entry records the date, the
upstream commit SHA the corpus came from, pages compared, the diff result, and
the F-score if escalation triggered.

*No run yet.* The differential harness is
[#33](https://github.com/bravely/ex_trafilatura/issues/33), and it gates the
v0.1.0 release: patch `0001` swaps the HTML parser under an extraction library
measured at F-score 0.913, and that drift is currently **unmeasured**.
