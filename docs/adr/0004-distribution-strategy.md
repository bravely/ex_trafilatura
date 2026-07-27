# ADR-0004: Distribution strategy for v0.1.0

- **Status:** Accepted
- **Date:** 2026-07-27
- **Ticket:** [#12 Decide the distribution strategy](https://github.com/bravely/ex_trafilatura/issues/12)

## Context

Precompiled binaries are in scope for v0.1.0 — a user running `mix deps.get` must end
up with a working NIF without a Rust toolchain. That decision was already made; this
ADR settles everything it drags in.

Three facts from earlier decisions shape the whole answer:

- **The dependency tree is pure Rust.** With the crate's `cli` feature off, nothing in
  the graph needs a C toolchain, OpenSSL, or a `build.rs` — `reqwest` is the only
  network dependency and it lives behind `cli`, which we do not enable. Cross-compiling
  is therefore unusually cheap, and the usual reason precompilation projects collapse
  does not apply.
- **The crate is vendored and patched.** [ADR-0002](0002-vendor-the-patched-rust-crate.md)
  puts a patched copy at `native/ex_trafilatura/vendor/trafilatura/`, referenced through
  `[patch.crates-io]`, carrying both reachable panics' fixes. Whatever CI builds, those
  fixes are inside it — and users cannot patch a binary they did not build.
- **`crate_version/0` ships**, returning the vendor marker `"0.3.0+extrafilatura.1"`
  ([#11](https://github.com/bravely/ex_trafilatura/issues/11)). Its whole purpose is to
  let a user establish what they actually have. Anything that lets two users hold
  materially different extractors under one marker makes it lie.

[ADR-0003](0003-verification-posture.md) resolved in parallel with this ticket and
hands over one constraint and one boundary. The constraint: once precompiled binaries
exist, **CI's `mix test` must be forced to build from source**, or the test job
silently validates a downloaded artifact instead of the tree it is testing. The
boundary: ADR-0003 §4 explicitly leaves the release build matrix to this ADR.

`rustler_precompiled` 0.9.0 is the ecosystem norm and is indifferent to what
`Cargo.toml` does, so the vendored patch is invisible to it. The checksum file is
mandatory and must appear in the Hex package's `files:`. The release ordering is forced
by the tooling: checksums cannot be generated until the artifacts exist.

## Decision

**Ship eight precompiled targets via `rustler_precompiled`, fail loudly rather than
silently building from source, and treat published artifacts as immutable.**

### 1. `rustler_precompiled` 0.9.0, artifacts on GitHub Releases

The alternatives fail for a different reason each: hand-rolling the download means
reimplementing checksum verification and target detection badly; source-only requires
every user to have a Rust toolchain, which is the thing being eliminated. There is no
third contender with meaningful adoption.

The ecosystem norm is also a security argument — the committed checksum file is a
supply-chain control users already know how to audit.

The accepted cost: **GitHub Releases becomes infrastructure, not a convenience.**
Bucket-hosting behind a stable domain is the usual escape, but it trades a GitHub
dependency for a domain-and-billing dependency, which for a 0.x is worse.

### 2. Source builds are opt-in only, never automatic

A target with no matching artifact fails at compile time. `EX_TRAFILATURA_BUILD=1`
enables a source build; `RUSTLER_PRECOMPILED_FORCE_BUILD_ALL=1` works globally.

The argument against automatic fallback is not that source builds are slow — it is
**where the failure lands**. A developer on an unlisted target with Rust installed gets
a silent source build that succeeds, and then the same `mix deps.get` hard-fails inside
the toolchain-free deploy container. Automatic fallback does not remove the failure; it
defers it to the worst possible moment and strips the diagnostic. Failing at
`mix deps.get` puts it in front of the person who can act on it.

Two consequences follow. The vendor directory and the full Rust source must ship in the
Hex tarball, since the opt-in path is the *only* recourse for an unlisted target. And
`force_build` flips to `true` automatically for pre-release versions, so any
`0.1.0-rc.N` is a source build for everyone regardless.

### 3. Eight targets

`rustler_precompiled`'s default ten, minus `riscv64gc-unknown-linux-gnu` and
`arm-unknown-linux-gnueabihf`:

| Target | Constituency |
| --- | --- |
| `x86_64-unknown-linux-gnu` | the default server |
| `aarch64-unknown-linux-gnu` | Graviton, Ampere, ARM cloud |
| `x86_64-unknown-linux-musl` | Alpine containers |
| `aarch64-unknown-linux-musl` | Alpine on Apple Silicon Docker |
| `aarch64-apple-darwin` | dev machines, 2020 onward |
| `x86_64-apple-darwin` | dev machines, pre-2020 |
| `x86_64-pc-windows-msvc` | official OTP Windows builds |
| `x86_64-pc-windows-gnu` | MSYS2 Erlang |

The cost of a target is not CI minutes. It is that **a broken exotic cross-build blocks
the entire release** — under §2 we cannot ship a partial artifact set without silently
handing some users a wall, so the flakiest target sets the release cadence for everyone.
RISC-V and 32-bit ARM are the two most likely to break and serve the two constituencies
a server-side HTML extraction library plausibly does not have.

This does rule out Nerves and 32-bit Raspberry Pi as *precompiled* platforms. They fall
to the source-build path, which is a real cost and is accepted rather than overlooked.

### 4. One NIF version: 2.15

Eight artifacts total, one per target. NIF versions are backward compatible, so a 2.15
artifact loads on any ERTS reporting 2.15 or higher.

Building 2.15 *and* 2.16 would double the artifact count and the checksum file for no
capability in use: dirty CPU schedulers — the one ERTS feature this binding depends on
([ADR-0001](0001-resource-safety-posture.md)) — arrived in NIF 2.7, long before any
version in play.

### 5. `elixir: "~> 1.15"`

Replacing the scaffold's `~> 1.20`, which was a `mix new` stamp rather than a decision
and would have shipped as the narrowest possible support claim by accident.

The principle: **the declared floor is the oldest pair CI actually tests.** Declaring a
floor that is never exercised is not support, it is an untested claim that will
eventually be wrong in public. Nothing in this library is version-sensitive, and both
Rustler and `rustler_precompiled` sit far below any floor we would plausibly pick, so
the constraint is entirely ours.

Note the NIF decision does not bind here — 2.15 permits OTP 22, so **Elixir is the
floor, not ERTS**. Mix has no `otp:` requirement key, so the OTP floor exists only in
the README and the test matrix.

**This amends [ADR-0003](0003-verification-posture.md) §4**, which specifies one CI job
on one Elixir/OTP pair and no matrix. The every-push suite runs on **two** pairs: the
declared floor and current/current. The amendment is scoped narrowly and does not
disturb §4's reasoning — that section's targets are Dialyzer, Credo, and combinatorial
OTP×Elixir sprawl, none of which return here. The asymmetry that decides it: an
untested floor is a *published promise*, visible on Hex to every user, while the second
entry costs roughly ninety seconds. Everything else in §4 — the single job's steps, the
scoped clippy run, the vendor-integrity check — is unchanged and simply runs twice.

The alternative considered was declaring only the pair a single job tests, which is
honest but narrows the support claim to almost nothing for a library that is not
version-sensitive in the first place.

### 6. Automated builds, manual publish

CI builds and attaches the eight artifacts on tag push, using
`philss/rustler-precompiled-action` rather than a hand-rolled `cross` matrix — the
target-name-to-artifact-name mapping must match what `RustlerPrecompiled` expects at
download time, and that is not worth reimplementing.

**The every-push test job sets `EX_TRAFILATURA_BUILD=1`**, honouring
[ADR-0003](0003-verification-posture.md) §4's inherited constraint. Without it, once
artifacts exist for `x86_64-unknown-linux-gnu`, CI's `mix test` downloads one and tests
that instead of the working tree — so a change to `native/` would pass CI without ever
being compiled. This also makes ADR-0003 §4's "does the vendor directory actually build"
property hold, which silently evaporates the moment a precompiled artifact is available
for the runner.

Publishing stays manual. A Hex publish is effectively irreversible, and more sharply:
full automation needs a write-scoped `HEX_API_KEY` in CI, which turns every workflow-file
change and every action dependency into a path to publishing under the maintainer's
name. For a package whose security story is "audit the committed checksum file," that is
an odd asymmetry to introduce at v0.1.0.

### 7. The checksum file is committed to git

`checksum-Elixir.ExTrafilatura.Native.exs` lives in the repository *and* in `files:`.

It is the supply-chain control for this package — the only thing between a user and
whatever bytes a GitHub Release URL happens to serve. Keeping it in git means a change
shows up in a diff, in a PR, in `git log`. A checksum file existing only inside a Hex
tarball is one nobody will ever review, which makes it a formality rather than a
control.

The awkwardness is accepted: checksums can only be generated after the tag is built, so
the commit carrying them sits *after* the tag, and the published tarball contains a file
the tag does not. **The tag is not moved to swallow it** — a moved tag breaks anyone who
already fetched it, and buys tidiness in a file nobody diffs against the tag anyway.

### 8. Published release assets are immutable

A broken artifact gets a new patch version. It is never re-uploaded under an existing
name.

`rustler_precompiled` resolves `base_url` at the *user's* compile time, so an asset's
bytes are a live dependency of `mix deps.get` forever, not just at publish. Deleting a
release, renaming an asset, or re-uploading different bytes each retroactively break a
working install — and re-uploading also silently invalidates the committed checksums,
turning every downstream `mix deps.get` into a checksum failure for a version the user
never changed.

Ordinary software instinct says "the artifact is wrong, replace it." Here that instinct
is actively harmful, which is exactly why the policy is written down rather than assumed.

### 9. `Cargo.lock` is committed and shipped

Rust convention says libraries do not commit a lockfile, but a Rustler NIF is a
`cdylib` — an end artifact — so the convention pointing the other way applies.

The specific reason is §2 and §8 together. The source path is the only recourse for an
unlisted target, and without a committed lock it does not reproduce the artifact: a
force-building user gets today's semver-compatible resolution of `html5ever`, `scraper`,
`ego-tree`, and `tendril` — **exactly the axis [ADR-0002](0002-vendor-the-patched-rust-crate.md)
was fought on**, since those four bumps are what fix the `ego-tree` panic. Two users on
the same package version would hold materially different extractors while
`crate_version/0` reported `"0.3.0+extrafilatura.1"` for both.

### 10. The release gate gains one check: a per-artifact smoke test

[ADR-0003](0003-verification-posture.md) §7 already defines the release gate — the
every-push suite, the vendor-integrity check, and the differential run with its 0.01
F-score tripwire. **This ADR adds exactly one thing to it**, because precompiled
artifacts introduce a failure mode none of those checks can see: ADR-0003's gate proves
the *source tree* is correct, and says nothing about the eight binaries built from it.

So before artifacts are attached, every artifact that can execute on an available runner
is loaded and `crate_version/0` called on it.

Seven of the eight are reachable — GitHub offers ARM64 Linux runners for public repos,
the musl pair runs in Alpine containers, both Darwin targets run natively, and
`x86_64-pc-windows-msvc` runs on a Windows runner. Only `x86_64-pc-windows-gnu` has no
practical home, needing a MinGW-built ERTS. **The coverage is labelled partial and the
eighth is not chased.**

The smoke test earns its place because the failure it catches — bad build config, a
missing symbol, a `cdylib` that will not load — is overwhelmingly target-*independent*.
Seven of eight is less a hole in the gate than a very good sample of one.

**`crate_version/0` is the right probe** rather than a fuller extraction run. It
exercises the whole chain that can plausibly break per-target — the artifact downloads,
the `cdylib` loads, a NIF is callable, and it returns a value that came out of the
vendored crate — while staying cheap enough to run on seven runners without touching
release cadence. Running the full every-push suite per target would instead re-verify,
eight times, behaviour ADR-0003 already proved once about the source tree.

### 11. Two documents, and an intent-level requirement on the failure

**README** (user-facing): the eight-target table, the Elixir and OTP floors, and an
explicit "your target is not listed" section naming `EX_TRAFILATURA_BUILD=1` and the
Rust toolchain requirement.

**A committed release checklist** (maintainer-facing). It lives in the repo rather than
only in this ADR because it is a procedure someone follows under time pressure, not a
rationale they read once.

**This ADR creates it, and it is the only one.** Both
[ADR-0002](0002-vendor-the-patched-rust-crate.md) §5 and
[ADR-0003](0003-verification-posture.md) §9 already refer to "the release checklist" as
though it exists; nothing had created it. Rather than a third document, this one absorbs
their lines — ADR-0002 §5's upstream-movement check, ADR-0003 §7's pre-release
differential run and §6's adversarial re-measurement — alongside the ordering below and
§8's immutability policy. A release procedure split across three ADRs is a procedure
nobody executes completely.

```
check upstream (ADR-0002 §5) → differential + adversarial runs (ADR-0003 §6, §7)
  → tag v0.1.0 → CI builds, smoke-tests, attaches 8
  → mix rustler_precompiled.download --all --print
  → commit checksums to main → mix hex.publish
```

The failure a user hits on an unlisted target **must name the target, the eight
supported targets, and `EX_TRAFILATURA_BUILD=1`**. This is stated as intent, not
mechanism: whether `rustler_precompiled`'s own message already does this — hexdocs does
not say — or whether we add a pre-flight check of our own is an implementation question.
A README is invisible to the person who needs it, since they are looking at a compile
error, not documentation.

## Consequences

- **`mix.exs` gains a `package` block and a `files:` list**, which must include the
  vendored crate, the full `native/` source, `Cargo.lock`, and the checksum file.
  Omitting any of them breaks the opt-in source build silently — it will only be
  discovered by a user on an unlisted target.
- **A committed `Cargo.lock` goes stale.** Dependabot or a periodic bump is needed so
  security advisories surface between releases rather than at one.
- **Nerves and 32-bit Pi users are told to install Rust.** If either turns out to be a
  real constituency, adding `arm-unknown-linux-gnueabihf` is additive and cheap — but
  `rustler_precompiled` has known friction with Nerves beyond target coverage, so that
  would be its own decision.
- **The eighth target is untested at release.** `x86_64-pc-windows-gnu` ships on the
  strength of the other seven and a successful build. It is the most likely artifact to
  be wrong.
- **[ADR-0003](0003-verification-posture.md) §4 is amended, narrowly**, to two CI pairs
  rather than one. Its every-push job, scoped clippy, and vendor-integrity check are
  untouched; they run twice.
- **ADR-0003's every-push suite is now also a release-cadence cost**, not only a
  CI-cost, since §10 gates the release on it. Its runtime was chosen when it was one
  job on one pair; it is now two pairs plus seven smoke tests.
- **The package's public presentation is now specifiable.** Hex metadata, the wording of
  the instability notice, and what the README must state were waiting on this decision
  and on [#10](https://github.com/bravely/ex_trafilatura/issues/10) /
  [#14](https://github.com/bravely/ex_trafilatura/issues/14).
- **One fact is deliberately unverified**: `rustler_precompiled`'s exact behaviour and
  message when no artifact matches the target. Hexdocs does not state it. §11 is written
  at intent level for that reason, and the implementation brief must pin it down against
  the library's source.
