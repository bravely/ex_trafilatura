# Spike: the NIF boundary

> **Throwaway.** This is not the beginning of the implementation. It exists to
> turn assumptions in [`CONTEXT.md`](../../CONTEXT.md) into observations, and it
> should be deleted once the decisions it feeds have landed as ADRs.
>
> Answers [Prove the NIF boundary end-to-end](https://github.com/bravely/ex_trafilatura/issues/7).

## The question

Can a Rustler NIF, scheduled on a dirty CPU scheduler and wrapped in
`catch_unwind`, call `trafilatura::extract` and hand a complete `ExtractResult`
plus `Metadata` back to Elixir — and what does that boundary actually cost and
surprise us with?

## Running it

```bash
cd spike/nif_boundary && mix deps.get && mix run spike.exs
```

`spike.exs` is the main run. Three follow-ups chase specific surprises:

| Script | What it settles |
|---|---|
| `spike.exs` | round trip, error shapes, UTF-8, panics, cost, dirty scheduler |
| `scheduler.exs` | **control** for the scheduler claim — idle baseline vs a concurrency sweep |
| `oddities.exs` | is there such a thing as "invalid HTML"? what is `language`? `""` vs `nil` |
| `language.exs` | decisive: is `metadata.language` read or detected? |

Measured on Elixir 1.20.2 / OTP 29, 10 normal + 10 dirty CPU schedulers,
`trafilatura` 0.3.0 + `rustler` 0.38.0.

## The answer

**Yes, and it was uneventful.** No source changes, no wrestling. The round trip
works, `ExtractResult` and `Metadata` come back whole, and the compile was clean
on the first attempt.

Five things worth carrying forward:

### 1. Encoding across the boundary is free

The question was whether building a large map per call is material. It is not —
**≤2% on top of extraction at every size tested**, and at the largest size it was
below measurement noise.

| Document | In | Out | Extraction | + encoding |
|---|---|---|---|---|
| 10 paras | 6 KB | 9 KB | 0.614 ms | +0.003 ms (0.5%) |
| 40 paras | 19 KB | 35 KB | 1.898 ms | +0.023 ms (1.2%) |
| 200 paras | 89 KB | 173 KB | 8.670 ms | +0.150 ms (1.7%) |
| 1000 paras | 439 KB | 864 KB | 42.6 ms | within noise |

A rich result shape costs essentially nothing. Do not shrink the API to save
encoding.

### 2. `catch_unwind` is not what keeps the VM alive — Rustler already does

`CONTEXT.md` says "`catch_unwind` is mandatory". Measured, that overstates it:
**Rustler 0.38 already wraps every `#[rustler::nif]` body in `catch_unwind`**
(`rustler_codegen/src/nif.rs:82` → `handle_nif_result`, which turns a panic into
`NifReturned::Raise(nif_panicked)`).

A deliberately panicking NIF with **no** `catch_unwind` of our own raised
`** (ErlangError) Erlang error: :nif_panicked` and the VM carried on.

So our own `catch_unwind` buys **the shape of the failure**, not survival:
`{:error, :panic}` as a return value versus an Erlang raise. That is a real
choice, but it is an API-design choice, not a safety one. The safety argument for
it is weaker than `CONTEXT.md` implies. (Unchanged: `catch_unwind` still cannot
save us from a stack overflow or abort — which is why the depth bound still
matters.)

### 3. The `s[..8]` panic is real, reachable, and attacker-controlled

`CONTEXT.md` flagged `src/metadata/mod.rs:1237` as a hypothetical. It is not
hypothetical. The guard is a **byte**-length check on a **byte** slice:

```rust
if s.len() >= 8 && s[..8].chars().all(|c| c.is_ascii_digit())
```

A page carrying `<meta property="article:published_time" content="1234567é9">`
panics:

```
end byte index 8 is not a char boundary; it is inside 'é' (bytes 7..9 of string)
```

That is **a meta tag value in an untrusted document**. Any deployment that
extracts pages it did not author can be made to hit it. This is a second panic to
carry a fix for, alongside the `ego-tree` one — see
[Decide how we carry the 0.3.0 panic fix](https://github.com/bravely/ex_trafilatura/issues/8).

### 4. Non-UTF-8 input never reaches the crate

The NIF signature is `html: &str`, so Rustler rejects an invalid-UTF-8 binary
with **`argument error`** before `extract` is called:

```elixir
SpikeNif.extract_full(<<0xFF, 0xFE, 0xFD>> <> "<html>...")
#=> ** (ArgumentError) argument error
```

Real-world HTML is routinely windows-1252, latin-1 or shift-jis. A binding that
badargs on those is not shippable without a deliberate decision, and there is no
decision on record. This graduated its own ticket.

### 5. There is no such thing as invalid HTML, and `language` is guessed

Two things that change what `{:ok, _}` means:

- **Everything parses.** Plain sentences, JSON, unclosed tags and raw control
  bytes all return `{:ok, _}` with the input echoed as content. Only the empty
  string errors, as `InsufficientContent`. `{:ok, _}` does **not** mean "this was
  a web page".
- **`metadata.language` ignores the declared `lang` attribute entirely.** Same
  English body, varying only `lang`: `nil`→`"en"`, `"fr"`→`"en"`, `"ja"`→`"en"`.
  It is statistical detection, and on thin or repetitive text it is unreliable —
  a French-tagged page of repeated words detected as `"nb"`, an English one as
  `"af"`. The `target_language` option raises `LanguageMismatch` on top of this
  detector.

## Also observed

- **Errors arrive with their payloads intact.** An empty document gives
  `{:error, {:insufficient_content, %{text_len: 0, comment_len: 0,
  min_output_size: 1, min_output_comment_size: 1}}}`.
- **`""`-means-absent behaves as documented.** On a rich page, `id`,
  `fingerprint` and `license` came back `""`; `categories` came back `[]`; `date`
  is the only genuine `Option` and came back `nil` when missing.
- **UTF-8 survives cleanly.** CJK, 4-byte emoji, combining marks and RTL all
  round-tripped as valid UTF-8 in both `content_text` and `content_html`.
- **`#[non_exhaustive]` is milder than feared.** It does *not* obstruct reading
  fields, so building the result map field-by-field is unaffected. It bites in
  exactly two places: the compiler **forces** the catch-all arm on
  `TrafilaturaError` (so the mapping cannot be non-total), and `Options` cannot
  be built with a struct literal — not even with `..Default::default()` — so
  every option must go through `Options::default()` plus assignment or builders.
- **The dirty pool saturates at its thread count.** 20 parallel extractions over
  10 dirty schedulers gave 5.3× speedup, and throughput plateaued: 579
  extractions at 10-way, 556 at 20-way, 577 at 40-way. Concurrency beyond the
  dirty scheduler count is pure queueing.
- **Normal schedulers stay responsive, but the first measurement was wrong.**
  `spike.exs` reported a 28 ms worst-case `Process.sleep(1)` under load, which
  looked alarming. With an idle control (`scheduler.exs`) it is mostly probe
  noise: idle is already p99 7.3 ms / max 10.8 ms. Under 20-way load it is p99
  13.3 ms / max 18.7 ms — roughly 1.8× at the tail, no starvation. The probe is
  coarse (`Process.sleep(1)` granularity is ~2 ms), so read this as "the VM stays
  responsive", not as a latency budget.
