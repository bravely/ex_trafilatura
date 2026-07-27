# ADR-0001: Resource-safety posture for v0.1.0

- **Status:** Accepted
- **Date:** 2026-07-27
- **Ticket:** [#9 Decide the resource-safety posture](https://github.com/bravely/ex_trafilatura/issues/9)

## Context

Extraction runs on a **dirty CPU scheduler**, and that is not a preference — 915 of
925 real documents exceed the ~1 ms NIF budget (mean 4.84 ms, p50 3.93, p99 19.5),
and the crate's API is one straight-line call with no re-entry points, so a yielding
NIF is not implementable against it.

Three properties follow, and together they are the whole problem:

- The dirty CPU pool is **bounded and VM-wide** (default: core count).
- A NIF call is **uninterruptible**. A caller who stops waiting does not free the
  thread; `Task.await/2` with a timeout abandons the *caller*, not the work.
- Per-call cost is **unbounded**, and cannot be capped from inside the crate.
  `Options.max_tree_size` looks like a safety valve but counts children of the
  *already-extracted* body and fires after the work is done.

The measurements say the ordinary case is comfortable and the adversarial case is
not. Against the 925-page corpus the slowest real document took 60.8 ms. But
nesting is a tarpit: ~120 KB at depth 20,000 took **871 ms**, and ~600 KB at depth
100,000 took **20.7 s**, all on one thread. So **bytes are a weak proxy for time** —
no input-size threshold anyone would ship separates those documents from real ones.

Two further findings bound what a fix could even be worth. The dirty pool
**saturates at its thread count**: 20-way parallel extraction over 10 dirty
schedulers gave 5.3x, and 40-way was no faster than 10-way. Concurrency beyond the
pool size is pure queueing, not compounding harm. And normal schedulers **stay
responsive** under that load — roughly 1.8x at the tail, no starvation.

## Decision

**v0.1.0 bounds memory and accidents. It does not bound time, and says so plainly.**

### 1. An input-size cap, on by default, at 10 MB

`extract/2` refuses documents over 10 MB in Elixir, before the NIF call. The cap's
job is to bound memory and catch the accident — a video file, a database dump, an
unbounded concatenation — not to bound time. 10 MB is roughly 3x the heaviest
realistic page, so it should never fire on legitimate work.

A cap that fires on real input is worse than no cap, because it teaches callers to
raise it blindly.

### 2. The cap is a per-call option, `:infinity` to disable

`max_input_bytes` is the **one non-crate key** in the extraction API. It is our
invention; no such option exists upstream. It is per-call rather than application
config so a caller with one known-huge document can raise it in place without
changing global policy, and `:infinity` exists so a wrong default is survivable.

This does not contradict the v0.1.0 goal of exposing *the crate's own option
surface*. That constraint forbids inventing **extraction** knobs — second-guessing
precision vs recall, adding our own heuristics. `max_input_bytes` is a safety guard
that physically cannot exist downstream of the NIF call.

### 3. Exceeding the cap is an error, never a truncation

Truncation is the actively dangerous option: an HTML document cut at an arbitrary
byte lands mid-tag, and the crate treats *nothing* as invalid HTML — it returns
`{:ok, _}` with content extracted from the wreckage. The caller gets a plausible
result silently derived from a document that never existed.

Raising is also wrong: oversized input arrives from the network at runtime, so it is
a condition, not a caller bug, and belongs with the other failure modes.

The **exact error term** is deliberately left to
[#10](https://github.com/bravely/ex_trafilatura/issues/10), which settles one pattern
across all five reachable `TrafilaturaError` variants. This ADR only fixes that
there is a sixth, Elixir-originated error, and that it has two natural payload
fields (actual size, permitted size).

### 4. No concurrency limiter — no module, no application, no supervision tree

Not even an opt-in one. An optional limiter is still a second API path: an
application, a child spec, a "what if it isn't started" branch on every call, and
its own tests — heavy for a release whose point is a thin, faithful binding. And
saturation undercuts the value: past the pool size, extra concurrency queues rather
than compounding damage, so a limiter would mostly move the queue out of the VM and
into our process, where it is managed worse.

What callers actually need is the number — bound concurrency near
`:erlang.system_info(:dirty_cpu_schedulers)` — and that is prose, not a module.

### 5. No structural or depth pre-flight check

The tarpit is the one genuinely dangerous case, and a structural check is the only
lever that could bound it. Both available forms are rejected:

- **Parse-then-measure** (Floki, then check depth) parses every document twice and
  adds a heavyweight dependency to a library whose pitch is "one NIF, no extra
  runtime" — and parsing is a large share of the cost being avoided.
- **A cheap heuristic** (tag count, tag density per byte) is an invented proxy with
  no ground truth behind it, and the first markup-dense real page it rejects is a
  bug we cannot defend.

Both also cross the project's stated line: the crate's behaviour is the source of
truth, and this library exposes it rather than second-guessing it.

### 6. The hazard is documented in full

Since nothing is shipped to protect callers, the documentation *is* the mitigation,
so it is calibrated as full disclosure rather than a neutral operational note. A
`## Resource safety` section in `README.md`, surfaced as the HexDocs main page via
`extras:`, states: the dirty CPU scheduler and the bounded VM-wide pool; that a call
is uninterruptible and **a `Task.await/2` timeout does not free the thread**; that
per-call cost is unbounded, with the measured 20.7 s adversarial figure; the
recommendation to bound concurrency near `:erlang.system_info(:dirty_cpu_schedulers)`;
and that the 10 MB cap bounds memory, not time.

The `ExTrafilatura` moduledoc carries a three-line summary and a link rather than a
second copy that drifts.

The `Task.await/2` point leads, because it is the one that surprises competent
Elixir developers — the reflex is to wrap the call in a task with a timeout, which
here buys nothing while looking like it worked.

## Consequences

- **A hostile ~600 KB document pins one dirty scheduler thread for ~20 s, and
  v0.1.0 does not prevent it.** A handful of them exhausts the pool node-wide. This
  is accepted and documented, not mitigated. It is the strongest candidate for
  reopening after 0.1.0.
- **A caller who does not read the README gets no protection**, and their first
  symptom is a node-wide stall with no obvious cause. That risk is what the
  full-disclosure calibration is buying back.
- **The 10 MB default will be wrong for someone.** `:infinity` and the per-call
  override are the escape hatch; if the default proves wrong often, that is evidence
  to revisit, not a reason to widen it pre-emptively.
- **Guard ordering is fixed for [#14](https://github.com/bravely/ex_trafilatura/issues/14):**
  the size check is the cheapest gate, so it runs first; any encoding guard sits
  behind it.
- **[#11](https://github.com/bravely/ex_trafilatura/issues/11) inherits exactly one
  non-crate key** to place in the options surface.
- **Nothing here needs an application or supervision tree**, so `ExTrafilatura`
  stays a library of plain functions.
