# ADR-0005: UTF-8 input contract for v0.1.0

- **Status:** Accepted
- **Date:** 2026-07-27
- **Ticket:** [#14 Decide how non-UTF-8 input is handled](https://github.com/bravely/ex_trafilatura/issues/14)

## Context

The boundary spike ([#7](https://github.com/bravely/ex_trafilatura/issues/7)) found that
a NIF taking `html: &str` makes Rustler reject an invalid-UTF-8 binary with
`argument error` **before** `trafilatura::extract` is ever called. The rejection is
correct; the diagnostic is not. A caller gets a bare `ArgumentError` with no indication
of what was wrong or what to do.

That matters because the input this fires on is not exotic. Real-world HTML is routinely
windows-1252, latin-1 or shift-jis — often while declaring something else, or nothing —
and the motivating case is the obvious one: piping a raw HTTP response body straight from
an HTTP client into this library.

**Nothing in the lineage does encoding work for us.** `extract(html: &str, opts: &Options)`
takes a `&str` and has no opinion about bytes; Python trafilatura, the reference
implementation, owns a whole detection subsystem (`charset_normalizer`/`cchardet`) that
the Rust crate did not port. So "detect the encoding" is a capability this project would
be **inventing**, not exposing — the same test that put URL fetching out of scope.

Four mechanical facts constrain the shape of any answer:

- **`encoding_rs` is not already in the dependency tree.** `tendril` 0.5 carries it behind
  an optional `encoding_rs` feature which `markup5ever` 0.39 and `html5ever` 0.39 do not
  enable. Transcoding in Rust means a genuinely new dependency, not a free one.
- **Elixir cannot transcode this natively.** `:unicode.characters_to_binary/3` handles
  only `latin1`, `utf8`, `utf16` and `utf32`. It has no windows-1252 — which differs from
  latin-1 exactly in `0x80`–`0x9F`, where the smart quotes that actually break documents
  live — and no shift-jis. Transcoding in Elixir means a new Hex dependency, and since
  `codepagex` is single-byte tables, covering CJK would mean `:iconv`, i.e. **a second
  NIF**.
- **A UTF-8 BOM is already handled downstream.** `trafilatura` parses via
  `scraper::Html::parse_document` (`src/dom/mod.rs:26`), which uses html5ever defaults,
  and `TokenizerOpts::default()` sets `discard_bom: true` (`html5ever-0.39.0/src/tokenizer/mod.rs:100`).
  A leading U+FEFF is stripped by the parser. There is nothing for us to do.
- **BOM-less UTF-16 is invisible to a UTF-8 check.** UTF-16 interleaves NUL bytes, and
  U+0000 is valid UTF-8, so a BOM-less UTF-16 document *passes* validation and reaches the
  crate as NUL-riddled garbage. Only the BOM-marked form is refused.

Guard ordering is already fixed by [ADR-0001](0001-resource-safety-posture.md) §1: the
10 MB input-size cap is the cheapest possible gate (`byte_size/1`, no traversal), so it
runs first, and any encoding guard sits behind it. If the answer had involved transcoding,
the cap would have had to apply to the bytes **as received** — otherwise an encoding that
expands on conversion evades it.

### Measurements

Elixir 1.20.2 / OTP 29.0.3, 10 MB inputs, against a mean extraction cost of 4.84 ms per
document ([`docs/research/crate-comparison.md`](../research/crate-comparison.md)):

| candidate gate | 10 MB ASCII | 10 MB CJK | 120 KB page | reports offset |
|---|---|---|---|---|
| `String.valid?/1` | 26 ms | 40 ms | ~0.4 ms | no |
| `String.valid?(_, :fast_ascii)` | 2 ms | **53 ms** | — | no |
| `:unicode.characters_to_binary(b, :utf8, :utf8)` | **13 ms** | **12 ms** | **0.14 ms** | **yes** |

`characters_to_binary/3` is 2–3× faster than `String.valid?/1`, effectively
content-independent, and **allocation-free on success** — it returns the input binary
itself, confirmed with `:erts_debug.same/2` and by twenty calls on a 10 MB binary
retaining every result growing the binary heap by **0 MB**. On failure it returns
`{:error, accepted, rest}`, where `byte_size(accepted)` is the byte offset of the first
invalid sequence.

`:fast_ascii` is a trap for this workload: it is 26× worse on CJK, which is precisely the
input this ADR exists for. It is also **Elixir 1.16+**, and therefore below the `~> 1.15`
floor set by [ADR-0004](0004-distribution-strategy.md) §5.

## Decision

**Refuse non-UTF-8 input with a typed error, in Elixir, before the NIF call. Ship no
encoding detection and no transcoding, with no exceptions and no opt-out.**

### 1. The input contract is a UTF-8 binary

`ExTrafilatura` accepts a UTF-8 binary and nothing else. It performs no encoding
detection and no transcoding in v0.1.0.

The reasoning is the reasoning that put URL fetching out of scope: a fetch layer would
invent surface the bound library does not have, and so would a detection layer. Taking
the other branch would make v0.1.0's most complex, most heuristic, most
likely-to-be-wrong subsystem one the bound crate does not contain.

The failure modes are asymmetric in a way that decides it. **A wrong transcode is
silent** — it returns `{:ok, mojibake}`, which surfaces later as a suspected extraction
bug and gets reported as one. A refusal is loud, immediate, and attributable.

And the choice is cheap to revisit in the right direction: accepting a wider input set in
0.2.0 breaks nobody who was already passing UTF-8. Shipping detection and withdrawing it
breaks everyone. In a 0.x that already declares its shapes unstable, take the reversible
branch.

### 2. The gate is an Elixir pre-flight, via `:unicode.characters_to_binary/3`

```elixir
case :unicode.characters_to_binary(html, :utf8, :utf8) do
  bin when is_binary(bin) -> # proceed to the NIF
  {:error, accepted, rest} -> # refuse; offset is byte_size(accepted)
end
```

Placed **after** ADR-0001's size cap and **before** the NIF call, so one Elixir function
holds every input rejection in a fixed, readable order.

Two alternatives were live. **Rescuing Rustler's badarg** at the Elixir edge costs no
extra pass, but makes our public error contract a downstream reading of a Rustler
implementation detail — `ArgumentError` on a failed `&str` decode is observed behaviour,
not documented API, and if it changes shape no test we would naturally write catches it.
**Validating in Rust** behind a `Binary` argument costs one pass instead of two, but
splits the guard chain across the NIF boundary for no gain: Rustler's `Binary` and `&str`
are both zero-copy, so there is no memory difference.

The cost accepted is that the binary is scanned twice — once here, once by Rustler's
decode. That is ~0.14 ms on a realistic page against 4.84 ms of extraction, and ~16 ms at
the 10 MB ceiling.

The NIF keeps `html: &str`. With the gate in front, invalid UTF-8 is unrepresentable at
the boundary and Rustler's badarg becomes an unreachable backstop rather than the
mechanism.

### 3. The reason is `:invalid_utf8`

Not `:invalid_encoding`. We never determine what the input *is*, and windows-1252 is a
perfectly valid encoding — what failed is the assumption that the bytes were UTF-8.
`:invalid_utf8` names exactly the test that ran, and matches conventional phrasing in
both Erlang and Rust.

**The shape of the error term belongs to
[#10](https://github.com/bravely/ex_trafilatura/issues/10)**, which decides whether errors
are flat atoms or carry structured payloads. This ADR fixes the reason and records what
information is available so that #10 can choose knowing the cost:

- the **byte offset** of the first invalid sequence, free from the mechanism;
- the **offending bytes**, if wanted.

> **If the offending bytes are carried, they must be copied.** `rest` from
> `characters_to_binary/3` is a **sub-binary over the input**, and putting it in an error
> term retains the entire original binary against garbage collection — up to 10 MB held
> alive by a three-byte diagnostic. Use `:binary.copy(binary_part(rest, 0, n))`, never
> `rest` itself.

If #10 chooses flat atoms, the payload is dropped and nothing is lost.

### 4. No opt-out

There is no key to disable the check. Disabling it would not make invalid input work — it
would only downgrade `{:error, :invalid_utf8}` to a bare `ArgumentError` from Rustler.
Validity is a precondition, not a policy, which is what distinguishes it from ADR-0001's
`max_input_bytes`.

[#11](https://github.com/bravely/ex_trafilatura/issues/11) settled that `max_input_bytes`
is *the one* non-crate key in the options surface. A second one, bought for a 3% saving on
a guarantee, is not worth reopening that.

### 5. No BOM exception — one clean rule

UTF-16 is refused like everything else, BOM or not.

A BOM is genuinely different from the rest of encoding detection: it is a **marker**, not
a guess, and Erlang transcodes UTF-16 natively, so the exception would have cost no
dependency and about ten lines. It is rejected anyway, because the observed behaviour
argues against it rather than for it:

| input | gate |
|---|---|
| UTF-16 LE/BE **with** BOM | refused at offset 0 |
| UTF-16 LE/BE **without** BOM | **passes** → NUL-interleaved garbage reaches the crate |
| windows-1252 smart quotes | refused at offset 3 |
| UTF-8 BOM + document | passes; html5ever strips the BOM |

Handling the marked case would fix the rare detectable form while the undetectable form
keeps silently corrupting — and would advertise UTF-16 support that is false in the case
more likely to occur. It also costs the contract its best property: **"input must be a
UTF-8 binary"** is one sentence a caller reads once and retains. "UTF-8, or UTF-16 if it
has a BOM" is a sentence they have to look up, and its exception is the opening for
"well, why not windows-1252 when `<meta charset>` says so" — which is the swamp §1
declined to enter.

### 6. BOM-less UTF-16 is a named limitation, not a bug

`{:ok, garbage}` is reachable for BOM-less UTF-16 input. We know it, and v0.1.0 does not
fix it.

This is consistent with what the binding already does not promise: `{:ok, _}` has never
meant "this was a web page" — #7 established that nothing is invalid HTML to the crate.
It follows ADR-0001 §6's posture of documenting a hazard rather than half-mitigating it.

### 7. The documentation leads with the reason, not the workaround

The moduledoc and README explain the contract by explaining **why the caller is better
placed than we are**:

> An HTTP response carries `Content-Type: text/html; charset=windows-1252` — authoritative,
> and requiring no detection at all. That signal is discarded before the bytes reach this
> library. We refuse not because detection is hard, but because the caller is standing next
> to the answer and we are not.

Written that way the error reads as a handoff. Written the other way round it reads as an
apology for a missing feature.

Beneath it, a worked recipe: take the charset from the response header; fall back to the
`<meta charset>` in the first 1024 bytes when the header is silent; transcode with
[`codepagex`](https://hex.pm/packages/codepagex) (pure Elixir) or
[`iconv`](https://hex.pm/packages/iconv) (a NIF, faster). **Both named with an explicit
note that we do not test them and are not endorsing them**, so a package going stale does
not become this project's problem.

### 8. A tripwire: URL fetching reopens this

Following [ADR-0003](0003-verification-posture.md) §7's practice of naming the condition
rather than settling it on release day:

> **This decision reopens if URL fetching comes into scope.** A library that does its own
> fetching **holds the `Content-Type` header**, at which point transcoding is a lookup
> rather than a guess and §7's argument inverts completely.

URL fetching is currently out of scope for v0.1.0. This ADR is the reason to revisit that
pairing together rather than separately.

## Consequences

- **[#10](https://github.com/bravely/ex_trafilatura/issues/10) is unblocked**, and gains a
  fourth error reason to place alongside the crate's three reachable variants —
  `:invalid_utf8` is ours, raised before the crate is reached, and is one of the few
  genuine input rejections the library has.
- **The motivating caller pays a real papercut.** Someone piping a raw response body in
  gets `{:error, :invalid_utf8}` and must write a transcoding step, pulling a Hex
  dependency to do it. This is the accepted cost of §1, and §7 exists to keep it from
  reading as a defect.
- **The every-push suite gains fixtures** for the gate: valid UTF-8 passes, windows-1252
  bytes refuse with the right offset, BOM-marked UTF-16 refuses, and — asserting the
  limitation rather than the fix — **BOM-less UTF-16 passes the gate**. These are
  handwritten minimal HTML, so they sit inside ADR-0003 §3 without amending it, and run on
  both CI pairs per ADR-0004 §5.
- **The 10 MB cap and this gate compose without interaction.** Ordering is fixed, both are
  Elixir-side, and neither can mask the other's error.
- **One fact is deliberately unverified.** The allocation-free property of
  `:unicode.characters_to_binary/3` is measured on **OTP 29 only**; the floor pair implied
  by ADR-0004 §5 (Elixir 1.15, so OTP 24–26) was not available to test. Reading
  `stdlib/src/unicode.erl:346`, utf8→utf8 does not take the `no_conversion_needed`
  shortcut, so the identity return originates inside the BIF and cannot be confirmed
  version-stable by inspection. **No decision here depends on it** — it is a performance
  characteristic, and the worst case is a transient copy bounded by a cap ADR-0001 already
  imposes.
