# Verification tooling

What each tool is, and exactly when it runs. Nothing here ships: this directory
is excluded from the Hex package's `:files`.
[ADR-0003](../../docs/adr/0003-verification-posture.md) is the posture these
implement.

| Tool | What it answers | When it runs | Gates? |
|---|---|---|---|
| `vendor-integrity.sh` | Is `native/ex_trafilatura/vendor/trafilatura/` exactly the published tarball plus our patches? | every push | yes |
| `drift.sh` | Did the patched crate's output move? | pre-release, re-vendor | yes, with an escalation |
| `escalate.sh` | If it moved, is the move acceptable? | only when `drift.sh` reports a diff | yes |
| `adversarial-bench/` | What does the nesting tarpit cost, in wall clock? | pre-release, re-vendor — **never CI** | no, it *produces* a figure |
| `artifact-smoke.sh` | Does *this built binary* load and answer? | every tag push, once per artifact | yes, before the artifact is attached |

"Every push" means [`.github/workflows/ci.yml`](../../.github/workflows/ci.yml)
and "every tag push" means
[`.github/workflows/release.yml`](../../.github/workflows/release.yml). Those two
are the only automated callers of anything here; the middle three are run by
hand, from the invocations below.

## `vendor-integrity.sh`

```sh
tools/verify/vendor-integrity.sh
```

Fetches the crates.io tarball, checks it against the sha256 in
[`VENDOR.md`](../../native/ex_trafilatura/vendor/trafilatura/VENDOR.md), applies
`vendor/patches/*.patch` in order, drops what we do not vendor, and diffs the
result against the vendored tree. Empty diff or fail. Needs network and `git`.

It runs on **every push**, not behind a `vendor/**` path filter: it takes
seconds, and a path filter is wrong the first time someone moves a directory. A
provenance check you have to remember to run is a provenance claim, not a check.

The specific rot it catches: someone fixes something by editing
`vendor/trafilatura/src/` directly without updating the `.patch` file.
Everything builds, tests pass, `VENDOR.md` still looks right — and it surfaces
months later at the exact moment we re-vendor onto a new upstream release,
which is when the patch files are the mechanism.

Its accepted cost is that it is the only CI step pinned to one specific fetched
artifact, so a yanked or relocated tarball breaks the build for a non-reason.
That is the same registry `cargo` is already hitting, and a yanked `trafilatura`
0.3.0 is news we would want.

## `drift.sh`

```sh
tools/verify/drift.sh [--refresh]
```

Runs `trafilatura::extract` over a corpus of real pages twice — once linked
against stock crates.io 0.3.0, once against the vendored copy — and diffs the
two dumps byte for byte. Needs network, `cargo` and `git`, and takes a few
minutes. `--refresh` re-clones the corpus instead of reusing the one on disk.

It asks **"did the output change?"**, not "did the accuracy change?". Byte
equality is the stronger claim and the more sensitive instrument: an F-score
averages away compensating changes that a diff surfaces, and a diff needs input
HTML only — no ground truth and no scoring code (ADR-0003 §1).

### One harness compiled twice

```
drift/dump.rs             the harness — the whole of it
drift/stock/Cargo.toml    links trafilatura "=0.3.0" from crates.io
drift/patched/Cargo.toml  links the vendored copy, through the same
                          [patch.crates-io] entry the NIF crate uses
```

Twice rather than once because the two cannot coexist in one build:
`[patch.crates-io]` rewrites every path to that crate, including a renamed
`package = "trafilatura"` dependency. Two thin manifests over one shared source
file is what that constraint looks like in practice — shared rather than copied,
so the two sides cannot drift apart and quietly compare different things.

Both sides call `trafilatura::extract(html, &Options::default())`, which is
exactly what `extract/1` is defined to equal, so the diff measures the call path
our callers take rather than a neighbouring configuration.

**The failure mode this guards hardest against is a false clean.** If the patch
entry ever stopped engaging, both sides would build stock, the diff would be
empty, and an empty diff is what we ship on. So before running anything,
`drift.sh` asks `cargo tree` what each side actually resolved and fails unless
the patched side names the vendored directory and the stock side does not.

### What the dump contains

Every field of `ExtractResult` and every field of `Metadata`, each as a header
line naming and sizing it followed by its bytes — emitted even when empty, so
the two sides stay line-aligned and a diff points straight at the field that
moved. Sizes are what make it unambiguous: extracted content can contain
anything, including a line that reads exactly like a header.

It includes `id` and `fingerprint`, which
[ADR-0006](../../docs/adr/0006-result-and-error-representation.md) §2 keeps off
the Elixir struct. The instrument watches the crate, not our projection of it.

An error and a panic are recorded as outcomes rather than as a missing dump: an
error that becomes a success, or a panic that stops happening, is drift. The
harness installs a panic hook and catches unwinds so one bad page does not end
the run — patch `0002` fixes a panic reachable from a meta tag, so the stock
side hitting one is a foreseeable outcome, not a crash to debug.

Pages that are not valid UTF-8 are decoded lossily and counted. Both sides are
handed the identical string, so the decode cannot hide drift — it only decides
what the corpus means. Upstream's own loader sniffs windows-1252, but that is
its scoring loader, not anything on `extract/1`'s path
([ADR-0005](../../docs/adr/0005-utf8-input-contract.md)).

### The corpus

Shallow-cloned on demand from `nchapman/trafilatura-rs` into
`tools/verify/.corpus/`, which is gitignored. It never enters this repository
and never enters the Hex package: the corpus is upstream's, and vendoring a
subset would quietly reverse ADR-0002 §2 while weakening the instrument exactly
where breadth is the point (ADR-0003 §2).

The cost of not vendoring is paid by recording provenance — **every result
records the upstream commit SHA the corpus came from**, or the run is not
reproducible once upstream moves.

`drift.sh` takes every `.html` file under `test-files/`, which is more than the
925 pages ADR-0003 describes: that figure is the `comparison/` set, the corpus
has grown since, and breadth is free here. The recorded page count is what the
run actually compared.

### Reading the result

- **Empty diff** → ship. The dependency bump is output-neutral and the
  accuracy-drift concern closes permanently.
- **Non-empty diff** → not a stop by itself. A diff says *whether* output moved,
  not whether the move is an improvement. Escalate, below.

`drift.sh` exits non-zero on a non-empty diff so it can be used as a gate, and
prints a table ready to paste into the Verification section of
[`VENDOR.md`](../../native/ex_trafilatura/vendor/trafilatura/VENDOR.md) — the
right home because the drift result is a property of *the vendored state*
(ADR-0003 §9).

## `escalate.sh`

```sh
tools/verify/escalate.sh
```

**Only run this when `drift.sh` reports a non-empty diff.** It clones upstream
at the tag the vendored copy came from, re-applies what the vendored copy
carries, and runs upstream's own `tests/comparison_test.rs` unmodified against
its own 960-entry ground truth. No scorer of ours, and nothing to keep in step
with upstream's.

The two patches are re-applied differently, and the script says so:

- `0002` touches `src/` only, so `git apply` takes it as-is.
- `0001` cannot be applied: it edits the **normalised** manifest cargo generates
  when it packages a crate, which is not the hand-written `Cargo.toml` in the
  repository. Its substance is four dependency bumps, so those four are
  re-applied by name against their exact current values — and the script fails
  if any of them is not found rather than scoring a crate missing the bump.

It also fails if the patch set is not exactly the two it knows about. A third
patch that got silently skipped would produce a score for a crate we do not
ship, which is worse than no score.

### The tripwire

**F-score below 0.903 reopens [ADR-0002](../../docs/adr/0002-vendor-the-patched-rust-crate.md) §1**,
where taking patch `0001` at all was decided. At or above it, ship with the
delta and the affected page count recorded. `escalate.sh` exits non-zero below
the line.

The number is written down rather than argued on release day because the
alternative is indistinguishable from not checking: the decision otherwise gets
made by someone who wants to ship, looking at a figure they can rationalise
either way. This measurement has no run-to-run noise — same corpus, same
deterministic scoring code — so any movement is a real behavioural change
(ADR-0003 §7).

**The gated row is "Balanced (no fallback)".** Upstream's test reports four
configurations; that one is `Options::default()`, because `enable_fallback`
defaults to `false` and `focus` defaults to `Balanced`. The other three are
printed but do not gate — scoring a configuration we do not ship would be
measuring someone else.

Worth knowing before release day: **the 0.913 figure ADR-0002 and ADR-0003 cite
is the fallback configuration, not the one `extract/1` uses.** Measured on the
patched crate at `v0.3.0`, "Balanced (no fallback)" is 0.903 and "Balanced +
Fallback" is 0.913. So the tripwire sits *at* our baseline rather than 0.01
below it, and the 0.01 band ADR-0003 §7 describes is not the margin it reads
like. That is a question for ADR-0002 rather than for this script, which gates
on the row our callers actually get.

## `adversarial-bench/`

```sh
cd tools/verify/adversarial-bench && cargo run --release
```

Generates nesting-adversarial HTML at a range of depths, times
`trafilatura::extract` on each, and emits a markdown block on stdout. Progress
goes to stderr, so the block is pasteable as-is. Needs no network and no corpus:
the input is generated, which is why this is the one pre-release tool that runs
from a clean checkout with nothing fetched.

Takes about three minutes at the defaults, nearly all of it the depth-100,000
row. `--depths` and `--repeats` narrow it while investigating; `--help` lists
them.

### It produces a figure. It does not pass or fail.

Nothing in it asserts a threshold, and **it is deliberately not in CI**. Wall
clock on a shared runner is noise, and a benchmark that fails spuriously gets
muted within a month (ADR-0003 §6). It runs pre-release and at each re-vendor.

**If the figure has moved, amend [ADR-0001] §6 and the project README's
`## Resource safety` section in place, and ship.** ADR-0001 is not superseded:
its posture explicitly survives the numbers moving either way, so only the
figure changes. It becomes a decision point only if the tarpit has got
dramatically worse in a way that reopens ADR-0001 §4 or §5.

That is the whole reason this is standing infrastructure rather than a
scratchpad someone ran once. ADR-0001 §6 puts a concrete figure in a document we
publish, and ADR-0002 §5's re-vendor cadence moves the ground under it every
time. A published number with no reproducible way to regenerate it decays into
folklore, and the person who has to update it after the next re-vendor is a
stranger reading `VENDOR.md`.

### The method, and why each part of it is fixed

| | |
|---|---|
| Input | `<div>\n` repeated — unclosed `<div>`s, one per line |
| Options | `Options::default()`, which `extract/1` is defined to equal |
| Stack | 8 MiB per extraction thread |
| Reported | median of 5, with the fastest-to-slowest spread beside it |

**Unclosed `<div>`s, at six bytes per level.** `<div>` has no auto-close rule
against another `<div>`, so the parser nests them and the tag stream and the
parsed tree agree on the depth — `<p>` or `<li>` would auto-close and flatten
the tree to depth 1. A unit test pins that, because it is the assumption the
whole measurement rests on and it is invisible in the output if it breaks.

Six bytes per level is also what makes the emitted sizes comparable with the
published ones: ADR-0001 pairs depth 20,000 with ~120 KB and depth 100,000 with
~600 KB, which is exactly this shape. There is no text payload for the same
reason — the published figures were measured against bare nested `<div>`s, and
adding content would emit numbers that are not comparable with the ones this
exists to regenerate.

**8 MiB is the stack the published figures were measured on**, and it is a
constant rather than a flag: a benchmark whose stack size varies per run emits
numbers that cannot be compared with the ones it is meant to replace.

**Run it on an idle machine.** The `range` column is there to make contamination
visible rather than let it average into the figure — measured on a busy laptop,
depth 20,000 reported a 1.0 s median over a 708 ms–1.5 s spread, and 604 ms over
601–611 ms once the machine was idle. A wide range means re-run it, not publish
it.

### Two things the number does not say

**It is not the stack a NIF call gets.** ERTS sizes dirty scheduler stacks far
smaller than 8 MiB, so these figures describe how expensive the crate is, not
how deep a document the BEAM survives. The README's claim is about cost, and
that is what this measures.

**An `Err InsufficientContent` outcome is not a failed run.** The crate's own
depth guard declines documents nested this far, and the wall clock is what it
costs to reach that conclusion. The time is spent whether or not anything comes
back, which is precisely why ADR-0001 §5 rejects a pre-flight check: the work
happens before anything can decline it.

[ADR-0001]: ../../docs/adr/0001-resource-safety-posture.md

## `artifact-smoke.sh`

```sh
tools/verify/artifact-smoke.sh path/to/libex_trafilatura-v0.1.0-nif-2.15-<target>.so.tar.gz
```

Loads one built artifact through the path a user's `mix deps.get` takes and calls
`crate_version/0` on it. Needs Elixir and a `_build` it may overwrite; needs no
network beyond `mix deps.get`, no Rust, and no corpus. Run from the project root.

It is the one thing
[ADR-0004](../../docs/adr/0004-distribution-strategy.md) §10 adds to the release
gate, and it earns its place by being the only check that can see the binaries at
all: everything else here proves the *source tree* is correct and says nothing
about the eight artifacts built from it.

**Seven of the eight, labelled partial.** `x86_64-pc-windows-gnu` needs a
MinGW-built ERTS and has no practical runner, so it ships on the strength of the
other seven and a successful build — and is, by ADR-0004's own reckoning, the
artifact most likely to be wrong. That is a good sample rather than a hole,
because what this catches — bad build config, a missing symbol, a `cdylib` that
will not load, a name the runtime will never ask for — is overwhelmingly
target-*independent*.

### Why it takes four commands rather than one

The script is a driver for
[`artifact_smoke.exs`](artifact_smoke.exs), which runs in two halves around a
`mix compile`, because the artifact has to be in place before the compile that
consumes it:

1. `stage!/1` copies the artifact into `RUSTLER_PRECOMPILED_GLOBAL_CACHE_PATH`
   and writes a checksum file naming that artifact and its bytes.
2. `mix compile --force` re-runs the macro that resolves the NIF.
3. `verify!/1` asserts the artifact carries a name the runtime asks for, and that
   `crate_version/0` answers with the marker `build.rs` compiled into it.

Those two halves are what make the middle step a real test rather than a
formality. A cache **miss** falls through to a download, and a download of
anything else — a differently named asset, an older upload under the same name —
fails the integrity check against the file step 1 wrote. So `mix compile` can
only succeed if the artifact carries exactly the name and exactly the bytes the
runtime will ask for at a stranger's compile time. The name in particular is the
mapping ADR-0004 §6 refuses to reimplement, so `verify!/1` asks
`RustlerPrecompiled.available_nifs/1` for it rather than reconstructing it.

### The checksum file it writes is a throwaway

`stage!/1` overwrites `checksum-Elixir.ExTrafilatura.Native.exs` in the project
root, and says so on stderr. That is **not** ADR-0004 §7's committed file, which
is generated at release time by `mix rustler_precompiled.download` against the
attached assets. Restore yours with `git checkout --` after a local run.

### A source build would pass every assertion in it

Both `EX_TRAFILATURA_BUILD` and `RUSTLER_PRECOMPILED_FORCE_BUILD_ALL` are unset
by the script, because either one left over in a shell turns this into a green
run against a binary it never opened. `verify!/1` then asks
`ExTrafilatura.Native.Target.force_build?/2` — the same question the compile
itself asked — about **all four** sources `ExTrafilatura.Native` passes it, since
the other two are `config :rustler_precompiled` keys that no amount of unsetting
reaches. A pre-release version, which force-builds for everyone by ADR-0004 §2,
is rejected here for the same reason, and the message names whichever source
asked.

### It also looks at the eighth target's name

`verify!/1` checks every artifact sitting *beside* the one under test against the
names `RustlerPrecompiled.available_nifs/1` will ask for. In the release workflow
that directory holds all eight, so `x86_64-pc-windows-gnu` — which has no runner
and so no smoke leg — still gets the one check that matters for a target nobody
can execute: that its name is one a stranger's `mix deps.get` will resolve. Under
ADR-0004 §8 a misnamed asset cannot be renamed afterwards, so this is the last
moment it is catchable.

The check is one-directional. A name that was *not* built is not its question,
because a maintainer running this by hand has one artifact in the directory
rather than eight; the release workflow counts to eight separately, where all
eight are in one place.
