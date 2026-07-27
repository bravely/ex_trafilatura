# ADR-0003: Verification posture for v0.1.0

- **Status:** Accepted
- **Date:** 2026-07-27
- **Ticket:** [#18 Decide how we verify the binding is correct](https://github.com/bravely/ex_trafilatura/issues/18)

## Context

The repository is scaffolding. There is no CI, no NIF, no fixtures — `lib/ex_trafilatura.ex`
is still `hello/0`. Nothing decided here is added to an existing suite; every tier is
built from zero.

**What "correct" means for a binding is narrower than it sounds.** The crate's
behaviour is the source of truth ([`CONTEXT.md`](../../CONTEXT.md), and
[ADR-0001](0001-resource-safety-posture.md) §5 leans on it), so this is not about
extraction quality. It is two things: proving the *binding* faithfully exposes the
crate, and not silently regressing the crate underneath us.

Three strands were open, and the ticket framed them as one question because all three
appeared to need the same absent resource — the 925-page ground-truth corpus, which
belongs to `go-trafilatura` by way of `nchapman/trafilatura-rs` and ships with that
*repository*, not the crates.io tarball. **That framing is one strand too wide.** The
resource-safety figures were measured against *generated* nesting HTML, not real
pages, so strand 3 is self-contained and needs no corpus at all.

- **Extraction drift.** [ADR-0002](0002-vendor-the-patched-rust-crate.md) carries
  upstream PR #2, swapping `ego-tree` 0.10→0.11, `html5ever` 0.36→0.39, `scraper`
  0.25→0.26 and `tendril` 0.4→0.5 — the HTML parser under an extraction library
  measured at **F-score 0.913** against stock 0.3.0. ADR-0002 accepts the bump while
  explicitly noting the drift is unmeasured.
- **Resource-safety drift.** The same bump moves the same DOM layer ADR-0001 is
  calibrated on: **871 ms at depth 20,000, 20.7 s at depth 100,000**. ADR-0001 §6
  specifies publishing the 20.7 s figure in the README, so if it moves, published
  documentation moves with it. Upstream issue #1 is itself an `ego-tree` panic in
  `dom::tree::remove` — the same path deep nesting stresses.
- **The corpus.** Upstream's `exclude` drops `test-files/` from the tarball while
  shipping `comparison-data/` (3.4 MB of expected results), so the tarball carries
  answers whose inputs are missing and upstream's suite is not runnable from it.
  ADR-0002 vendors `Cargo.toml` + `src/` + `LICENSE` only, so the vendored crate
  carries no tests and no fixtures.

Two mechanical facts constrain the shape of any answer:

- **Stock and patched `trafilatura` cannot coexist in one cargo build.**
  `[patch.crates-io]` rewrites every path to that crate, including a renamed
  `package = "trafilatura"` dependency. A differential comparison is therefore one
  harness compiled twice — once against the registry, once against the vendored path —
  with the two dumps diffed afterwards.
- **Upstream's repository carries its own scorer.** `tests/comparison_test.rs` sits
  alongside `test-files/` and `comparison-data/`. Anything that clones the repo for the
  corpus gets the scoring code for free, so scoring needs no reimplementation of ours —
  which matters, because the reimplementation used for
  [`crate-comparison.md`](../research/crate-comparison.md) lived in a session
  scratchpad.

## Decision

**Verification is three tiers, separated by what each can fail on and how often it
runs.** Cheap, deterministic checks run on every push; expensive checks that need
network and wall-clock run at release and re-vendor; scoring runs only when something
else has already found a difference.

### 1. Drift is detected differentially, not by scoring

The pre-release check on patch `0001` asks **"did the output change?"**, not "did the
accuracy change?". A harness runs stock 0.3.0 and the patched build over the same
pages and diffs the full `ExtractResult` and `Metadata` — `content_text`,
`comments_text`, `content_html`, `comments_html`, and every metadata field — byte for
byte.

Byte-equality is a far stronger claim than "F-score within noise", and it is the more
sensitive instrument: an F-score averages away compensating changes that a diff
surfaces. It also needs input HTML only — no ground truth, no scoring code. If a pure
dependency bump turns out to be output-neutral across 925 pages, the entire
accuracy-drift concern closes in one run and no scoring infrastructure is ever built.

Both sides run `Options::default()`, which
[#11](https://github.com/bravely/ex_trafilatura/issues/11) §6 defines `extract/1` to
equal — so the diff measures precisely the call path our callers take, not a
neighbouring configuration.

The asymmetry is understood and accepted: a diff says *whether* output moved, not
whether the move is an improvement. Judging that is what escalation is for (§7).

### 2. The corpus is cloned on demand, never vendored

A script shallow-clones `nchapman/trafilatura-rs` into a gitignored path, runs the
harness, and reports. The corpus never enters this repository and never enters the Hex
package.

ADR-0002 already ruled that the corpus is upstream's and "anyone who needs it can clone
`nchapman/trafilatura-rs` directly"; vendoring a subset would quietly reverse that.
Vendoring a subset also weakens the instrument exactly where it matters — drift
detection wants *breadth* of real-world markup pathology, and 925 pages cost
essentially the same wall-clock as 50. The run is rare, so a network dependency at the
moment it runs costs nothing.

The cost is real and is paid by recording provenance: **the upstream commit SHA the
corpus came from is written down with every result** (§9), the same way `VENDOR.md`
records the tarball's sha256. Without that, the run is not reproducible if upstream
moves or disappears.

### 3. The every-push suite is handwritten fixtures only

No real pages, no golden snapshots of extraction output. Each fixture is minimal
HTML pinning a boundary **this library owns**:

| What it pins | Source |
|---|---|
| The three reachable `TrafilaturaError` variants — `InsufficientContent`, `MissingMetadata`, `LanguageMismatch` — map as decided, plus ADR-0001's Elixir-originated oversized-input error | [#10](https://github.com/bravely/ex_trafilatura/issues/10) |
| `""` → `nil` (or not) applied uniformly | [#10](https://github.com/bravely/ex_trafilatura/issues/10) |
| Each of the 13 exposed option keys reaches the crate and has an observable effect; unknown keys are ignored and invalid values raise `ArgumentError` | [#11](https://github.com/bravely/ex_trafilatura/issues/11) |
| `extract/1` equals `trafilatura::extract(html, &Options::default())` | [#11](https://github.com/bravely/ex_trafilatura/issues/11) §6 |
| `max_input_bytes` fires before the NIF call, and errors rather than truncates | [ADR-0001](0001-resource-safety-posture.md) §1–3 |
| Non-UTF-8 input behaves as decided | [#14](https://github.com/bravely/ex_trafilatura/issues/14) |
| Patch `0002` regression — `<meta property="article:published_time" content="1234567é9">` no longer panics | [ADR-0002](0002-vendor-the-patched-rust-crate.md) §1 |

Three reasons real pages stay out:

- **A golden snapshot asserts on someone else's contract.** It turns every legitimate
  upstream improvement into a red build that gets "fixed" by blessing the new output —
  a ritual, not a signal.
- **The differential harness already answers "did the crate move under us"**, across
  925 pages rather than three, and at the moment it matters (re-vendor) rather than on
  every push.
- **Committing real web pages is a licensing wrinkle with no upside.** Upstream's
  `test-files/` sitting in an Apache-2.0 repository does not license the scraped
  articles themselves. Cloning them for a local run is one thing; redistributing them
  inside a package we publish to Hex is another.

**Expectations may be borrowed from upstream's unit tests, and this is not a
contradiction.** [#11](https://github.com/bravely/ex_trafilatura/issues/11) §6 defines
`extract/1` to equal `trafilatura::extract(html, &Options::default())` exactly, so any
expectation drawn from the crate's own tests transfers unchanged. Upstream's
`metadata_unit_test.rs`, `elements_test.rs` and `html_processing_test.rs` are inline
synthetic HTML against `Options::default()` — the fixture style this section admits,
unlike `comparison_test.rs` and `realworld_test.rs`, which are the real-page suites it
excludes. **This is a source for fixtures, not a porting project:** where a handwritten
fixture needs an expectation, take upstream's rather than inventing one. Translating
their suite wholesale would test the crate rather than the binding.

The accepted cost: nothing on every push proves the binding works end-to-end on
realistic input. The boundary spike
([#7](https://github.com/bravely/ex_trafilatura/issues/7)) already proved that on real
documents, and the pre-release corpus run re-proves it on 925 — a two-page smoke test
adds confidence only for someone who has neither.

### 4. CI is one boring job

One workflow, one job, Ubuntu, one Elixir/OTP pair, one Rust toolchain. **No matrix.**

- `mix format --check-formatted`
- `mix test` — which compiles the vendored crate from source, so this doubles as the
  "does the vendor directory actually build" check
- `cargo clippy -- -D warnings`, **scoped to our NIF crate only**. Upstream already
  gates itself on `clippy -D warnings`; re-litigating someone else's lints on code we
  have patched produces noise we would end up allow-listing around.
- The vendor-integrity check (§5)

Dialyzer and Credo are both out. A library this small with a NIF at the bottom gets
little from Dialyzer and pays in CI minutes and false starts, and no style disagreement
exists yet for Credo to arbitrate.

**The release build matrix is not this ADR's business** — it belongs to
[#12](https://github.com/bravely/ex_trafilatura/issues/12), shaped by whatever that
ticket decides about precompiled targets.

### 5. Vendor integrity is checked on every push

A script fetches the crates.io tarball, verifies it against the sha256 in `VENDOR.md`,
extracts it, applies `vendor/patches/*.patch` in order, and diffs the result against
`vendor/trafilatura/`. Empty diff or fail.

ADR-0002 §4 makes three provenance claims — patches kept as files and "individually
named and re-appliable to a future upstream release", a recorded sha256, and a git
history shaped to be the record. Nothing enforced any of them. The failure mode is
quiet and specific: someone fixes something by editing `vendor/trafilatura/src/`
directly without updating the `.patch` file. Everything builds, tests pass, `VENDOR.md`
still looks right, and the rot surfaces months later at the exact moment ADR-0002 §5
says to re-vendor onto a new upstream release — where the patch files *are* the
mechanism.

It runs on every push rather than behind a `vendor/**` path filter: it takes seconds,
and a path filter is wrong the first time someone moves a directory. A provenance check
you have to remember to run is a provenance claim, not a check.

The accepted cost: this is the only CI step that fetches a specific pinned artifact, so
a yanked or relocated tarball breaks the build for a non-reason. It is the same registry
`cargo` is already hitting, and a yanked `trafilatura` 0.3.0 is news we would want.

### 6. The adversarial benchmark is standing in-repo infrastructure

A generator plus a timing loop, self-contained and reproducible from a clean checkout,
run pre-release and at each re-vendor. **Not in CI** — wall-clock on shared runners is
noise, and a benchmark that fails spuriously gets muted within a month.

It is kept rather than run once and discarded because **its output is a shipped
artifact**: ADR-0001 §6 puts 20.7 s in the README as a concrete figure, and ADR-0002
§5's re-vendor cadence moves the ground under it again every time. A published number
with no reproducible way to regenerate it decays into folklore, and the person who has
to update it after the next re-vendor is a stranger reading `VENDOR.md`.

**If the figure moves, ADR-0001 §6 and the README are corrected and we ship.** ADR-0001
is not superseded — its posture explicitly survives the numbers moving either way, so
only the figure changes. It would become a decision point only if the bump made the
tarpit dramatically worse in a way that reopens ADR-0001 §4 or §5.

### 7. The release gate, and a tripwire at 0.01

Four things must be true before v0.1.0 ships. Only one of them is interesting.

| Check | When | Gates the release? |
|---|---|---|
| Every-push suite (§3, §4) | every push | yes |
| Vendor integrity (§5) | every push | yes |
| Adversarial re-measurement (§6) | pre-release, re-vendor | no — it *produces* the README figure rather than passing or failing |
| Differential run (§1, §2) | pre-release, re-vendor | **yes, with an escalation** |

- **Empty diff** → ship. Patch `0001` is output-neutral and the concern closes
  permanently.
- **Non-empty diff, F-score ≥ 0.903** → ship, with the delta and the affected page count
  recorded.
- **F-score < 0.903** → **this reopens [ADR-0002](0002-vendor-the-patched-rust-crate.md)
  §1**, where taking patch `0001` at all was decided.

Escalation runs **upstream's own** `tests/comparison_test.rs` against a clone with our
patches applied — no scorer of ours, no reimplementation to maintain.

The tripwire is a stated number rather than a judgment call because the alternative is
indistinguishable in practice from not checking: the decision otherwise gets made on
release day, by someone who wants to ship, looking at a figure they can rationalise
either way. Below the line, the alternatives — drop the bump and carry the `ego-tree`
panic, or patch `dom::tree::remove` directly instead of bumping — are ADR-scale, and
writing the number down now means the person facing it later argues with a prior
decision rather than with their own deadline.

**0.01 is a tight band, and defensibly so.** This measurement has no run-to-run noise:
same corpus, same deterministic scoring code, same inputs — unlike the latency figures,
which `crate-comparison.md` explicitly warns not to quote as a spec. Any F-score
movement is a real behavioural change. 0.01 is roughly ten of the 960 ground-truth
entries — not a noise band, but a "small enough that we would accept it knowingly" band.

### 8. No fuzz pass in v0.1.0

Named as a non-goal rather than left unmentioned, because ADR-0002 §1 is explicit that
patching two panics "is **not** a claim the crate is panic-free" and the thing being
wrapped is a parser fed untrusted documents.

The objection is not cost — `cargo-fuzz` over `extract` is about an hour — it is what a
finding would obligate. A fuzzer over a parser and metadata-heuristic stack this size
will find panics; that is the expected outcome, not a risk. At that point we are
triaging and patching crash bugs in a dormant upstream's crate one at a time, with no
natural stopping point, on the critical path of a first release. ADR-0002 §5 permits it
("bug fixes land freely"), which is precisely the problem: nothing says when we are
done.

Deferring is defensible rather than negligent because the blast radius is already
bounded and about to improve. Rustler's `catch_unwind` means a panic costs one failed
extraction, not the node (proven in #7), and #10 turns `:nif_panicked` into a legible
error term. An unfound panic degrades to a typed failure on one call — the same thing
`InsufficientContent` already does.

The two panics we *do* patch are not inconsistent with this. Both were found by targeted
reading and reproduced, both are roughly one line, and one is attacker-reachable from a
meta tag. That is the rule both prior ADRs already follow: fix what is cheap and
certain, document what is expensive and unbounded.

**What reopens it:** panics turning out to be frequent rather than theoretical, in the
error-representation work or in real usage.

### 9. Where the tooling and the results live

- **`tools/verify/`** — the differential harness, the adversarial benchmark, the
  on-demand corpus clone script, the vendor-integrity script, and a `README.md` stating
  what each is and exactly when it runs. **Excluded from the Hex package's `:files`.**
- **Drift results → `VENDOR.md`**, in a `## Verification` section recording, per
  re-vendor: the date, the upstream commit SHA the corpus came from, pages compared,
  the diff result, and the F-score if escalation triggered. That is the right home
  because the drift result is a property of *the vendored state*, and `VENDOR.md` is
  already the document you read to learn what we are carrying and why.
- **Resource figures → ADR-0001 §6 and the README's `## Resource safety` section**,
  amended in place.
- **The procedure → `tools/verify/README.md`**, referenced from ADR-0002 §5's release
  checklist line.

## Consequences

- **The pre-release tooling cannot be built or run until ADR-0002 is implemented.** The
  differential harness needs a vendored patched build to compare against. This ADR
  decides the posture; building the harnesses and running them are implementation
  obligations for the brief ([#13](https://github.com/bravely/ex_trafilatura/issues/13)),
  along with the CI workflow, the `tools/verify/README.md`, and the every-push fixtures.
- **[#12](https://github.com/bravely/ex_trafilatura/issues/12) inherits a constraint:**
  once precompiled binaries exist, CI's `mix test` must be forced to build from source,
  or the test job silently validates a downloaded artifact instead of the tree it is
  testing.
- **[#10](https://github.com/bravely/ex_trafilatura/issues/10) and
  [#14](https://github.com/bravely/ex_trafilatura/issues/14) each acquire a test
  obligation** rather than only an API decision: whatever they settle has to be
  expressible as a handwritten fixture, since §3 admits no other kind.
  [#11](https://github.com/bravely/ex_trafilatura/issues/11) resolved during this
  ticket and already meets it — its 13 keys, its unknown-key and invalid-value rules,
  and its `extract/1` equivalence are all fixture-expressible, and the equivalence is
  what lets §1 and §3 borrow from the crate's own expectations.
- **ADR-0002's unmeasured-drift consequence is now carried, not closed.** It stays open
  until the differential run happens; what changes is that the instrument, the threshold,
  and the escalation path are fixed in advance rather than improvised at release.
- **A verification run depends on a network clone of a third-party repository**, and
  ADR-0002 §2 declined to vendor that corpus. If upstream disappears, drift detection
  degrades to whatever clone someone still has — mitigated by recording the commit SHA,
  not eliminated.
- **Nothing here protects against a panic we have not found**, by §8. Combined with
  ADR-0001's accepted tarpit, v0.1.0's stance is consistent: bound what is cheap to
  bound, document the rest, ship an experimental 0.x.
