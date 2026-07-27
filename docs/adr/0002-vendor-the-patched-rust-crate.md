# ADR-0002: Vendor the patched Rust crate

- **Status:** Accepted
- **Date:** 2026-07-27
- **Ticket:** [#8 Decide how we carry the 0.3.0 panic fix](https://github.com/bravely/ex_trafilatura/issues/8)

## Context

`trafilatura` 0.3.0 — the published version we bind — has **two reachable panics**,
and upstream will not fix either on a useful timescale.

- **The `ego-tree` panic.** An `unwrap()` on `None`, reached via `extract` →
  `extract_document` → `doc_cleaning` → `strip_elements` → `dom::tree::remove`.
  Reported as upstream
  [#1](https://github.com/nchapman/trafilatura-rs/issues/1). The fix is upstream
  [PR #2](https://github.com/nchapman/trafilatura-rs/pull/2), a pure dependency bump
  (`ego-tree` 0.10→0.11, `html5ever` 0.36→0.39, `scraper` 0.25→0.26, `tendril`
  0.4→0.5), verified to apply cleanly to 0.3.0 with no source changes.
- **The `s[..8]` panic.** `src/metadata/mod.rs:1237` guards a *byte* slice with a
  *byte*-length check, so a multi-byte character straddling byte 8 splits it.
  `CONTEXT.md` listed this as hypothetical; the boundary spike
  ([#7](https://github.com/bravely/ex_trafilatura/issues/7)) confirmed it is real and
  attacker-reachable — `<meta property="article:published_time" content="1234567é9">`
  panics with `end byte index 8 is not a char boundary`. The trigger is a meta tag
  value in an untrusted document. **Nobody has reported it upstream** (verified
  2026-07-27: one open issue, two open PRs, none of them this).

**Upstream is dormant.** Last commit 2026-03-10; crates.io still 0.3.0; PR #2 open
since 2026-03-18; the #1 reporter noted the repo "doesn't seem to have permission set
up for external contributors". Assume nothing merges.

**Severity is lower than this ticket was framed under, and the diagnostics are
worse.** Rustler 0.38 already wraps every NIF body in `catch_unwind`, so neither panic
takes down the node. But `rustler-0.38.0/src/codegen_runtime.rs:134` **discards the
panic payload** — `Err(_) => nif_panicked` — so Elixir sees a bare `:nif_panicked`
atom with no message, no Rust file:line, and no way to tell which panic fired. The
message reaches OS stderr via Rust's default panic hook, which is not `Logger`, is not
correlated with the failing call, and is absent from structured logs.

Three facts constrain the mechanism:

- **Both fixes require modified crate source.** All four dependency bumps are
  semver-incompatible, so no lockfile of ours can produce them — `trafilatura`'s own
  `Cargo.toml` must change. The `s[..8]` fix is a source edit with no upstream PR to
  point at. So `[patch.crates-io]` and "a fork" were never alternatives: the
  fork-or-vendor question is about *where the source lives*, and the patch entry is
  only *how it is referenced*.
- **Nothing else in our graph pulls `trafilatura`.** It is a leaf we depend on
  directly, so `[patch.crates-io]` buys no override reach a plain `path` dependency
  lacks.
- **The published crate is self-contained for compilation but not for testing.** No
  `build.rs`, no `include_str!`/`include_bytes!` in `src/`, so `Cargo.toml` + `src/` +
  `LICENSE` (~455 KB) compiles standalone. But the crate's own `exclude` drops
  `test-files/` — the 925-page corpus — while shipping `comparison-data/` (3.4 MB of
  *expected results* whose inputs are therefore absent). Upstream's suite is not
  runnable from the tarball at all.

Finally, **precompiled binaries are in scope for v0.1.0**, so whatever we carry is
baked into artifacts users cannot patch.

## Decision

**We vendor a patched copy of the crate in-tree and reference it through
`[patch.crates-io]`.**

### 1. Carry both panic fixes

The `s[..8]` fix is one line, attacker-reachable, and behaviourally risk-free —
declining it is indefensible. The `ego-tree` bump is the riskier half: it swaps the
HTML parser under an extraction library whose accuracy we measured at F-score 0.913.
We take it anyway, because a reachable `unwrap()` on `None` is worse than parser
drift and PR #2 was verified to build and test green — but see the consequences, the
drift is real and currently unmeasured.

Patching these two is **not** a claim the crate is panic-free. A wrapper that turns a
panic into a legible error term is wanted regardless; its shape belongs to
[#10](https://github.com/bravely/ex_trafilatura/issues/10).

### 2. Vendor in-tree, not a fork

The vendored crate lives at `native/ex_trafilatura/vendor/trafilatura/` —
`Cargo.toml` + `src/` + `LICENSE`, ~455 KB. `comparison-data/` and `tests/` are
dropped.

The deciding argument is that **we must author a source patch either way, and
vendoring makes the patch just be the code**: no second repository, no rebase story,
no cross-repo review. Both fixes land as an ordinary diff in an ordinary PR against
this repo.

A long-lived fork at `bravely/trafilatura-rs` was rejected for putting a GitHub remote
we own on the critical path of every source build of the published package, forever,
in exchange for two small patches. Publishing a renamed fork to crates.io was rejected
as disproportionate.

Vendoring is *not* justified by self-containment — a source build still pulls
`chrono`, `scraper`, `regex` and a dozen others from crates.io, so it does not work
offline. What it buys is **working behind a crates.io mirror**, since shops that
mirror the registry generally do not proxy arbitrary git remotes. It also does not
freeze the dependency tree: only `trafilatura` itself is pinned, and `cargo update`
still moves everything underneath it.

The 925-page corpus is *not* an argument for forking. It is upstream's, and anyone who
needs it can clone `nchapman/trafilatura-rs` directly.

### 3. Reference it through `[patch.crates-io]`

```toml
trafilatura = "0.3"

[patch.crates-io]
trafilatura = { path = "vendor/trafilatura" }
```

Both forms build identically; this one keeps the registry range we consider ourselves
bound to visible in `[dependencies]`, and makes un-vendoring a deletion. A patch entry
wins over any matching registry version, so if upstream ever publishes 0.3.1 we are
not silently moved off the vendored copy — the switch stays deliberate.

### 4. Provenance is recorded in four places

Vendoring's characteristic failure is losing track of what was vendored. A naive
vendor leaves `version = "0.3.0"` in place, so `cargo tree` and SBOM tooling report
stock 0.3.0 — misleading in both directions.

- **The version string carries the marker**: `version = "0.3.0+extrafilatura.1"`.
  Semver build metadata is ignored for resolution, verified to resolve through
  `[patch.crates-io]` against a `"0.3"` requirement, and `cargo tree` prints it.
- **`vendor/trafilatura/VENDOR.md`** records the upstream repo, the exact source
  (crates.io tarball for `trafilatura` 0.3.0), its sha256
  `eb6f4be2db656bb2360d2dc9e575c3cf42ee8197558ba7a2df1e0daf0e1be8f7`, the date, what
  was dropped, and one line per patch linking its upstream issue or PR.
- **The patches are kept as files** — `vendor/patches/0001-bump-deps-upstream-pr-2.patch`,
  `0002-fix-char-boundary-panic.patch` — so each deviation is individually named and
  re-appliable to a future upstream release.
- **The git history is shaped to be the record**: pristine tarball import as one
  commit, patches as the next, so `git log -p -- native/ex_trafilatura/vendor/trafilatura`
  is an exact account of every deviation.

`cargo vendor`'s `.cargo-checksum.json` is deliberately **not** used: it only engages
for registry source replacement, not `path` dependencies, and where it is checked,
patched files fail verification. The checksum documents the base, in `VENDOR.md`.

### 5. Bug fixes land freely; semantics changes need their own ADR

- **Cadence.** Check upstream at each ExTrafilatura release — has it moved, are any of
  our patches now redundant. A line in the release checklist, not an automated watch;
  Dependabot cannot track a patched path dependency, and two patches do not justify a
  polling job.
- **How this ends.** If upstream ships PR #2 as 0.3.1: drop patch `0001`, re-vendor,
  bump to `+extrafilatura.2`, keep `0002`. If upstream ever carries both: delete the
  vendor directory and the `[patch]` block and return to a plain crates.io dependency.
  The vendored state is a liability we accept, not an asset we build.
- **What is admissible.** Bug fixes land as ordinary patches. **Anything that changes
  extraction or metadata semantics requires its own ADR first.** The guardrail exists
  because a vendor directory is precisely where "the crate's behaviour is the source
  of truth" erodes one convenient patch at a time. It is not a ban: the time-of-day
  widening (`Metadata.date` discarding a parsed time) is a case `CONTEXT.md` already
  says to design for landing in our tree — out of scope for v0.1.0, not forbidden
  forever.

### 6. Report the `s[..8]` panic upstream

File the issue *and* the one-line PR at `nchapman/trafilatura-rs`, including the
repro, and link both from `VENDOR.md`. Expect nothing and block on nothing — PR #2 has
sat four months.

This is not load-bearing for our release; we patch regardless. It is here because the
alternative is knowingly sitting on an attacker-reachable crash in someone else's
shipped code that nobody else knows about. A RustSec advisory was considered and
rejected for an experimental 0.x: it carries disclosure etiquette requiring a
maintainer notice window first, and it would flag our own vendored version in
`cargo audit` output.

### 7. The modification is documented, twice as a licence obligation

Distributing a *modified* Apache-2.0 work in object form triggers §4(b) — modified
files must carry prominent notices stating we changed them — which the existing
notices file does not address, because when it was written we were not modifying
anything.

- **Modification headers** in the two patched files. *Obligation.*
- **A modification statement in `THIRD-PARTY-NOTICES.md`**: that precompiled builds
  bundle a patched `trafilatura` 0.3.0, what changed, linking `VENDOR.md`. *Obligation,
  and the surface that covers binary distribution.* Note its dependency table lists
  `ego-tree`, `html5ever` and `scraper` at versions patch `0001` moves, so it needs
  revisiting regardless — it already carries a "regenerate with `cargo about`" flag.
- **One README line** that the bundled crate is patched, linking `VENDOR.md`. Not an
  obligation, but a user should not have to read the notices file to learn the binary
  is not stock.

Precompilation does **not** change any of the above — it reinforces it. Under a
source-only model a user could add their own `[patch.crates-io]`; with binaries they
cannot, so our carrying the fix is the only way most users will ever get it.

## Consequences

- **The `ego-tree` bump moves ground [ADR-0001](0001-resource-safety-posture.md)
  stands on, and the drift is unmeasured.** ADR-0001's central figures — 871 ms at
  depth 20,000, **20.7 s at depth 100,000** — were measured against stock 0.3.0, i.e.
  `ego-tree` 0.10 / `html5ever` 0.36 / `scraper` 0.25. Patch `0001` swaps all three,
  and the tarpit lives in exactly that DOM layer (upstream #1 is itself an `ego-tree`
  panic in `dom::tree::remove`). The posture survives the numbers moving either way,
  but ADR-0001 §6 specifies publishing 20.7 s in the README as a concrete figure. Both
  this and extraction-output drift against F-score 0.913 must be re-measured on the
  patched build before v0.1.0 ships — the verification ticket carries it.
- **This does not contradict ADR-0001 §5.** That section rejects pre-flight checks
  partly because "the crate's behaviour is the source of truth, and this library
  exposes it rather than second-guessing it". Decision 5 above holds exactly that line:
  we patch bugs, never behaviour, without an ADR.
- **Fixing the smaller hazard while documenting the larger one is deliberate.**
  ADR-0001 accepts an unmitigated node-wide stall; this ADR insists on patching a panic
  whose worst case is one failed extraction. The distinguishing axis is **cost, not
  severity**: one line inside a vendor we carry anyway, versus a Floki dependency and a
  double parse. Both ADRs follow one rule — fix what is cheap and certain, document
  what is expensive and uncertain.
- **ADR-0001's 10 MB input cap offers zero protection against either panic.** The
  `s[..8]` trigger fits in a 1 KB document. The two ADRs are orthogonal; neither
  partially mitigates the other.
- **We now own a vendored dependency**, with the standing obligation to check upstream
  at each release and the standing temptation to patch behaviour into it.
- **Implementation obligations for the brief**
  ([#13](https://github.com/bravely/ex_trafilatura/issues/13)): vendor the tarball and
  write both patches; write `VENDOR.md` and the modification headers; amend
  `THIRD-PARTY-NOTICES.md` and the README; file the upstream issue and PR.
- **[#12](https://github.com/bravely/ex_trafilatura/issues/12) inherits two
  constraints**: the vendor directory must be in the Hex package's `:files` or source
  builds of the published package cannot find it, and the source-build fallback is now
  load-bearing rather than a nicety, because a precompiled user has no escape hatch
  from our patches.
