# ADR-0007: The package's public presentation

- **Status:** Accepted
- **Date:** 2026-07-27
- **Ticket:** [#22 Decide the package's public presentation](https://github.com/bravely/ex_trafilatura/issues/22)

## Context

Six ADRs each settled one question and each, in passing, handed the README an obligation.
Nobody had counted them together. Laid out, the README is carrying four mandated
disclosures before a word of pitch is written:

| Obligation | Source | Weight |
| --- | --- | --- |
| `## Resource safety` — dirty scheduler, uninterruptible, `Task.await/2` buys nothing, the 20.7 s figure, bound concurrency near `:dirty_cpu_schedulers`, the cap bounds memory not time | [ADR-0001](0001-resource-safety-posture.md) §6 | ~4 paragraphs, calibrated as *full disclosure* |
| Eight-target table, Elixir and OTP floors, "your target is not listed" → `EX_TRAFILATURA_BUILD=1` plus the Rust toolchain | [ADR-0004](0004-distribution-strategy.md) §11 | table + section |
| UTF-8-only contract, led by *why the caller is better placed than we are*, plus a worked transcode recipe naming `codepagex`/`iconv` with an explicit non-endorsement | [ADR-0005](0005-utf8-input-contract.md) §7 | ~3 paragraphs |
| One line that the bundled crate is patched, linking `VENDOR.md` | [ADR-0002](0002-vendor-the-patched-rust-crate.md) | 1 line |
| No XML, no JSON — the capability gap against Python trafilatura, named so its absence reads as deliberate | `CONTEXT.md` | 1–2 lines |
| The out-of-scope omissions: Markdown, URL fetching, structured images | map [#6](https://github.com/bravely/ex_trafilatura/issues/6) | 1 block |
| The instability notice — 0.x return shapes not promised stable | map [#6](https://github.com/bravely/ex_trafilatura/issues/6) | this ADR |

And the same file is the HexDocs landing page, via ADR-0001 §6's `extras:` mandate.

So the presentation question is not "what tone should the README take". It is: **can one
document carry four hazard disclosures and still function as a pitch**, and if it can, in
what order — because ADR-0001 §6's own consequence concedes that "a caller who does not
read the README gets no protection."

### Three mechanical facts, checked against Hex 2.4.1

The ticket asked for `description`, `licenses`, `links`, `maintainers` and `files:`. One of
those is a ghost.

- **`maintainers` no longer exists.** It appears nowhere in `Mix.Tasks.Hex.Build` in Hex
  2.4.1 — the live package-metadata keys are `description`, `licenses`, `links`, `files`,
  `exclude_patterns`, `build_tools` and `organization`. Hex.pm derives owners from the
  publishing account. Setting it is a no-op.
- **`files:` is an allowlist, and the only subtractive mechanism is `exclude_patterns`**
  (a list of regexes). There is no "everything except" form. Whatever we write, the
  characteristic failure of an allowlist applies.
- **`description` has a hard cap** — `Mix.Tasks.Hex.Build` rejects an over-long one
  ("Package description is too long"). 300 characters.

### What the allowlist actually risks

[ADR-0004](0004-distribution-strategy.md) §2 made the opt-in source build the *only*
recourse for a target we do not ship. That promotes `files:` from packaging trivia to a
load-bearing contract: omit the vendored crate, the `native/` source, `Cargo.lock` or the
checksum file and the recourse silently does not exist. The break is invisible to us —
every listed target keeps working — and surfaces months later, as a stranger's compile
error on a platform we chose not to precompile.

That is the shape of the problem: not "which paths", but **that no list shape detects its
own omission.**

## Decision

### 1. One README, ordered — no second document

Everything stays in `README.md`. The alternative considered was splitting the hazards into
a second `extras:` page and letting the README stay a pitch.

It was rejected on ADR-0001 §6's own reasoning. That section chose full disclosure *in the
README, as the HexDocs main page* precisely because the documentation **is** the
mitigation — nothing ships to protect callers. A second page is one more click between the
reader and the only protection they get, and it is a second document to drift. Splitting
would have amended ADR-0001 §6; keeping one document honours it literally.

### 2. A compressed callout above the fold, linking down

The cost of §1 is that four paragraphs of scheduler hazard above the first code sample make
the library look radioactive and bury what it does. The cost of the obvious fix — hazards
after usage — is that ADR-0001 §6's disclosure depends entirely on the reader scrolling.

Neither, then. Immediately after the one-paragraph pitch:

```markdown
> **Before you ship this**
> - A call runs on a dirty scheduler and is **uninterruptible** — `Task.await/2` will not
>   free the thread. See [Resource safety](#resource-safety).
> - Input must be **UTF-8**; anything else is refused. See [Input must be UTF-8](#input-must-be-utf-8).
> - **0.x**: return shapes may change. See [Stability](#stability).
```

Three lines, each a pointer rather than a copy. The full sections stay intact below at their
mandated calibration. This duplicates a *sentence* of each, not a section, so there is
nothing meaningful to drift — and it guarantees that no reader reaches the usage example
without knowing the disclosures exist.

The `Task.await/2` bullet leads, matching ADR-0001 §6's ordering and for its reason: it is
the one that surprises competent Elixir developers.

### 3. Stability: a stable spine, an unstable payload

The map's Notes required only that the README say 0.x return shapes are not promised stable.
A bare "this is 0.x, anything may change" is honest and useless — it tells a reader nothing
they can act on beyond pinning, which they were going to do anyway.

Instead, the notice commits to what will *not* move and enumerates what may:

> **What will not change in 0.x:** `extract/1` and `extract/2` exist, take HTML, and return
> `{:ok, %ExTrafilatura.Result{}}` or `{:error, reason}`.
>
> **What may change:** the fields on `Result` and `Metadata`, what an absent value looks
> like, the shape of any `reason` term, and the option keys.
>
> Breaking changes bump the minor version (0.1 → 0.2) and are listed in `CHANGELOG.md`.

The split mirrors [ADR-0006](0006-result-and-error-representation.md)'s own structure — that
ADR fixed a two-arm return contract and then made a series of revisable choices *inside* it.
Publishing the same seam gives a caller something safe to pattern-match on, which a blanket
disclaimer denies them.

**This creates `CHANGELOG.md`**, which did not previously exist as an obligation, and
commits to minor-bump-on-break as a versioning policy.

### 4. `files:` is coarse, and a packaged-tarball build check makes it safe

```elixir
files: [
  "lib", "native", "checksum-*.exs",
  "mix.exs", ".formatter.exs",
  "README.md", "CHANGELOG.md",
  "LICENSE", "THIRD-PARTY-NOTICES.md",
  "docs/adr"
],
exclude_patterns: [~r"native/.*/target/"]
```

Whole directories rather than enumerated paths, so a source file added later ships without
anyone remembering to edit a list. `exclude_patterns` kills the Cargo build directory, which
`"native"` would otherwise sweep in at gigabyte scale. `tools/verify/` is absent, satisfying
[ADR-0003](0003-verification-posture.md) §9.

But granularity is the smaller half. **The release checklist gains one step:**

```
mix hex.build → unpack the tarball to a temp dir → EX_TRAFILATURA_BUILD=1 mix compile
  → must succeed before mix hex.publish
```

This is the load-bearing part. It converts ADR-0004 §2's silent, user-facing, months-later
break into a loud pre-publish failure, and it does so for *any* omission — a path we forgot,
a new file, a bad `exclude_patterns` regex — rather than the specific ones we thought to
list. The coarse list then merely reduces how often the check has to save us.

**This narrowly amends [ADR-0004](0004-distribution-strategy.md) §11**, inserting the step
before `mix hex.publish` in the release sequence. Nothing else in §11 changes.

### 5. The ADRs ship, and every link stays relative

```elixir
extras: ["README.md", "CHANGELOG.md",
         "native/ex_trafilatura/vendor/trafilatura/VENDOR.md"] ++ Path.wildcard("docs/adr/*.md"),
main: "readme",
groups_for_extras: ["Design decisions": ~r"docs/adr/"]
```

The forcing constraint is mechanical: a relative link to a file that is not an `extras:`
entry 404s on HexDocs. ADR-0002 *mandates* a README line linking `VENDOR.md`, and the
resource-safety and encoding sections both want to cite the ADR that reasoned them out. So
either those targets become extras, or the README carries absolute `github.com` URLs pinned
to a release tag — hardcoded strings needing a bump every release, and wrong the first time
someone forgets.

Shipping them is also the honest pitch. For an experimental binding, the ADRs *are* the
evidence that the hard questions were answered deliberately rather than defaulted. The cost
is sidebar weight, which `groups_for_extras` contains.

### 6. Hex metadata

```elixir
description: "Extract the main article body and metadata from HTML, discarding " <>
             "navigation, sidebars, and boilerplate. Elixir NIF bindings for the " <>
             "Rust trafilatura crate, with precompiled binaries.",
licenses: ["Apache-2.0"],
links: %{"GitHub" => "https://github.com/bravely/ex_trafilatura",
         "Changelog" => "https://github.com/bravely/ex_trafilatura/blob/main/CHANGELOG.md"}
```

197 of 300 characters. It leads with the job in the searcher's own words — *article body*,
*boilerplate*, *HTML* — because the description is the only text in a Hex search result, and
"Elixir NIF bindings for the Rust trafilatura crate" assumes a reader who already knows what
that crate is. Most Elixir developers do not; the Rust port is obscure enough that
`CONTEXT.md` keeps a naming note to distinguish it from an unrelated crate.

**No experimental caveat in the description.** `0.1.0` already says it to an Elixir
developer, the callout in §2 is one click away, and the caveat would permanently cost search
relevance for a library with seven ADRs behind it. `licenses` is a single SPDX identifier —
Hex validates against SPDX and warns otherwise. **`maintainers` is not set**, per Context.

### 7. The lead usage example handles failure

[ADR-0006](0006-result-and-error-representation.md) §5 decided that "nothing extracted" stays
an **error** — the crate returns `Err` before building `ExtractResult`, so there is no result
to hand back. The conventional README opener therefore teaches a bug:

```elixir
{:ok, result} = ExTrafilatura.extract(html)   # MatchError on the first stub page
```

That is not a hypothetical. Any caller feeding this a crawl will hit a page with no article,
and the shape most likely to be copied out of a README is the one that raises. So the lead
example is case-shaped, and names the surprising arm inline:

```elixir
case ExTrafilatura.extract(html) do
  {:ok, result} ->
    result.metadata.title  # nil if absent
    result.content_text    # "" if absent

  {:error, :insufficient_content} ->
    # No article found. This is an error — not {:ok, %Result{content_text: ""}}.
    :skip

  {:error, reason} ->
    Logger.warning(inspect(reason))
end
```

It costs the "look how easy" first impression. It buys a reader who sees the whole contract
at once — including ADR-0006 §3's two absent-value rules, shown in passing rather than as a
table nobody reads.

### 8. The section spine

```
# ExTrafilatura + one-paragraph pitch
> Before you ship this                      (§2)

## Installation      deps · Elixir/OTP floors · 8-target table
                     · "your target isn't listed" → EX_TRAFILATURA_BUILD=1 + Rust
## Usage             the case example (§7)
## What you get      Result / Metadata fields
## Options           13 keys · extract/1 ≡ the crate's default call
## Resource safety   ADR-0001 §6, in full, Task.await leading
## Input must be UTF-8   ADR-0005 §7, reason first, then the recipe
## Stability         §3
## What it doesn't do    Markdown · URL fetching · structured images · no XML/JSON
## Upstream projects     4-layer table · naming note · where to file bugs
                         · the bundled crate is patched → VENDOR.md
## Development · Contributing · License
```

Two placements are deliberate. **The eight-target table lives inside Installation**, because
"will this install on my machine" is one reader question and ADR-0004 §11 splits its answer
across a table, two floors and an escape hatch; a separate `## Supported targets` section
would make the reader assemble it. **The patched-crate line joins the upstream section**,
where "what exactly am I running" is already the subject — the four-layer lineage table
answers the same question one layer up.

`## What it doesn't do` consolidates every omission in one place, which is the point: named
together they read as scope, named separately they read as gaps.

### 9. The OTP floor is 24

ADR-0004 §5 decided `elixir: "~> 1.15"` and observed that "Mix has no `otp:` requirement key,
so the OTP floor exists only in the README and the test matrix" — then never picked a number.
This ADR must, because §8 puts it in the README.

**OTP 24.** Elixir 1.15 hard-requires OTP 24+, so this is the widest claim consistent with
the already-decided Elixir floor, and it keeps ADR-0004 §5's principle exact: *the declared
floor is the oldest pair CI actually tests*. CI's floor job is therefore **Elixir 1.15 /
OTP 24**, and current/current remains the second pair. NIF 2.15 imposes nothing here — it
dates to OTP 22, well below.

The alternative was OTP 25, on the grounds that 24 is past its upstream support window. It
was rejected because nothing in this library is version-sensitive, the exclusion would be
enforced only by a README sentence, and a user on 24 would otherwise work fine.

**This completes [ADR-0004](0004-distribution-strategy.md) §5** rather than amending it.

## Consequences

- **[#13](https://github.com/bravely/ex_trafilatura/issues/13) is unblocked**, and this was
  its last blocker. The map is walked; the brief can be written.
- **`CHANGELOG.md` is a new artifact**, created by §3 and load-bearing — the stability
  notice promises breaking changes are listed there, so an empty or stale changelog makes
  the README lie.
- **The release checklist is now four documents deep in provenance.** ADR-0004 §11 created
  it and absorbed ADR-0002 §5 and ADR-0003 §6/§7; §4 here adds a fifth step. It is the one
  document a maintainer executes under time pressure, and it now has contributions from
  three ADRs — worth a `<!-- source -->` annotation per line when it is written.
- **The current README contains a false claim.** Its "What it does" paragraph states content
  is available as "plain text, cleaned HTML, or Markdown". Markdown is out of scope for
  v0.1.0. Rewriting to §8's spine must correct it, not just reorder around it.
- **`mix.exs` still carries `elixir: "~> 1.20"`**, the `mix new` stamp ADR-0004 §5 replaced
  with `~> 1.15`. It is uncorrected in the tree; §9's OTP floor is meaningless until it is.
- **A `docs:` block and a `package:` block are both new in `mix.exs`**, and §5's `extras:`
  list uses `Path.wildcard/1`, so a new ADR appears in HexDocs with no edit — which is the
  intent, and also means an ADR written badly ships publicly.
- **The README is long, and that is the accepted cost of §1.** Four full disclosures plus a
  pitch in one file is not a document anyone reads end to end. §2's callout is what makes
  that survivable; if the callout is ever trimmed for tidiness, ADR-0001 §6's mitigation is
  what gets trimmed with it.
- **`exclude_patterns` is a single regex protecting against a gigabyte-scale mistake.** If
  the vendor layout moves and the pattern stops matching, the first symptom is a very large
  tarball — visible, but only to someone reading `mix hex.build` output. §4's tarball check
  will not catch it, since an over-large package still builds.
- **Publishing the ADRs makes them user-facing.** They were written as internal reasoning
  and are candid about accepted liabilities — ADR-0002 calls the vendored state "a liability
  we accept". That candour is a feature on a 0.x binding, but the audience is no longer only
  us.
