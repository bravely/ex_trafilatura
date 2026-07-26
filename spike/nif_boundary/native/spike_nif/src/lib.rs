//! THROWAWAY SPIKE — see ../../README.md.
//!
//! Question: can a Rustler NIF on a dirty CPU scheduler, wrapped in
//! `catch_unwind`, call `trafilatura::extract` and hand a complete
//! `ExtractResult` + `Metadata` back to Elixir — and what does that cost?
//!
//! Nothing here is a proposal for the real binding. In particular the encoding
//! below deliberately does NOT map `""` to `nil`, because that is a separate
//! open decision; the spike's job is to show what the raw values look like.
//!
//! ---
//!
//! ## Reading this file from an Elixir background
//!
//! A NIF is a C function the BEAM dlopen's and calls **in-process**. There is no
//! message passing and no port — when Elixir calls `SpikeNif.extract_full/1`,
//! the calling Erlang process runs this Rust code on a real OS thread and blocks
//! until it returns. Rustler's job is to generate the C shim so we can write
//! ordinary Rust instead of raw `erl_nif.h` calls.
//!
//! Four ideas carry most of the weight here:
//!
//! - **`Env`** is the NIF environment: the arena that Erlang terms are allocated
//!   into for the duration of one call. Every term you build needs one.
//! - **`Term`** is an opaque handle to an Erlang value — the Rust-side
//!   equivalent of "some term". It is not typed as map/tuple/binary; it is just
//!   "a thing the BEAM understands".
//! - **The `'a` lifetime** you see written as `Term<'a>` and `Env<'a>` is Rust's
//!   compile-time proof that a term never outlives the environment it was
//!   allocated in. It is bookkeeping for the borrow checker, not a runtime cost.
//!   Read `Term<'a>` as simply "a term belonging to this call".
//! - **The `Encoder` trait** provides `.encode(env)`, which turns a Rust value
//!   into a `Term`. Rust `String`/`&str` become Erlang **binaries**, `usize`
//!   becomes an integer, `Vec<T>` becomes a list, and a tuple `(a, b)` becomes
//!   an Erlang 2-tuple. That last one is how `{:ok, result}` gets built.

// `use` is Rust's `alias`/`import`: it pulls names into scope so we can write
// `Term` rather than `rustler::Term`. Nothing is loaded at runtime by this.
use rustler::{Encoder, Env, Term};
use std::panic::{catch_unwind, AssertUnwindSafe};
use trafilatura::{extract, ExtractResult, Options, TrafilaturaError};

/// Erlang atoms have to be interned with the VM before they can be used, so
/// Rustler makes you declare them up front. This macro generates one zero-arg
/// function per name — `atoms::ok()` returns the atom `:ok`.
///
/// This is why the list is tediously long: every atom appearing anywhere in a
/// returned term, including every map key, has to be declared here first. The
/// real binding would likely generate these rather than hand-list them.
mod atoms {
    rustler::atoms! {
        ok,
        error,
        nil,
        panic,
        // error variants
        insufficient_content,
        missing_metadata,
        language_mismatch,
        duplicate_content,
        tree_too_large,
        unknown,
        // ExtractResult fields
        content_text,
        comments_text,
        content_html,
        comments_html,
        metadata,
        // Metadata fields
        title,
        author,
        url,
        hostname,
        description,
        sitename,
        date,
        categories,
        tags,
        id,
        fingerprint,
        license,
        language,
        image,
        page_type,
        // error payload fields
        text_len,
        comment_len,
        min_output_size,
        min_output_comment_size,
        expected,
        got,
    }
}

// ---------------------------------------------------------------------------
// Encoding: Rust values -> Erlang terms
// ---------------------------------------------------------------------------

/// Build the result map field-by-field.
///
/// `ExtractResult` and `Metadata` are `#[non_exhaustive]`, so we cannot
/// destructure them exhaustively — but reading named fields is unaffected, and
/// that is all this does. If upstream adds a field in a minor release, this
/// keeps compiling and silently ignores it.
///
/// Signature note: `env: Env<'a>` in, `Term<'a>` out. The shared `'a` is the
/// compiler enforcing that the term we return belongs to the environment we
/// were handed — you cannot accidentally stash it somewhere it would outlive.
fn encode_result<'a>(env: Env<'a>, r: &ExtractResult) -> Term<'a> {
    // `r` is a *borrow* (`&ExtractResult`) — we do not own it, so we cannot move
    // fields out of it. `.clone()` makes an owned copy of the metadata so the
    // field reads below are straightforward. A real binding would borrow each
    // field instead and skip this copy; in a spike the clone is not worth
    // optimising away, and section 5 of the README shows encoding is ~1% anyway.
    let m = r.metadata.clone();

    // `date` is the one genuinely optional field in `Metadata` — a Rust
    // `Option<NaiveDate>`, which is `Some(date)` or `None`. Everything else uses
    // `""` to mean absent. `match` here is exactly Elixir's `case`.
    let date_term = match m.date {
        // ISO-8601 string, e.g. "2026-03-14". Becomes an Erlang binary.
        Some(d) => d.to_string().encode(env),
        // Explicitly the atom `nil`, so Elixir sees `nil` rather than a missing key.
        None => atoms::nil().encode(env),
    };

    // Build the metadata map in one shot. `map_from_pairs` takes a slice of
    // (key, value) tuples — the `&[...]` syntax is a borrowed array literal.
    // Both key and value must already be `Term`s, which is why every entry ends
    // in `.encode(env)`.
    let meta = Term::map_from_pairs(
        env,
        &[
            (atoms::title().encode(env), m.title.encode(env)),
            (atoms::author().encode(env), m.author.encode(env)),
            (atoms::url().encode(env), m.url.encode(env)),
            (atoms::hostname().encode(env), m.hostname.encode(env)),
            (atoms::description().encode(env), m.description.encode(env)),
            (atoms::sitename().encode(env), m.sitename.encode(env)),
            (atoms::date().encode(env), date_term),
            // `Vec<String>` encodes as an Erlang list of binaries.
            (atoms::categories().encode(env), m.categories.encode(env)),
            (atoms::tags().encode(env), m.tags.encode(env)),
            (atoms::id().encode(env), m.id.encode(env)),
            (atoms::fingerprint().encode(env), m.fingerprint.encode(env)),
            (atoms::license().encode(env), m.license.encode(env)),
            (atoms::language().encode(env), m.language.encode(env)),
            (atoms::image().encode(env), m.image.encode(env)),
            (atoms::page_type().encode(env), m.page_type.encode(env)),
        ],
    )
    // `map_from_pairs` returns a `Result` because duplicate keys would be an
    // error. `.expect(msg)` unwraps it and panics with `msg` if it failed —
    // acceptable in a spike, and unreachable here since the keys are literals.
    .expect("metadata map");

    // The outer result map, with the metadata map nested under `:metadata`.
    // This is the term Elixir finally sees as the second element of `{:ok, _}`.
    //
    // Why this is four one-liners plus all the ceremony above: the four
    // text/html fields are plain `String`s, and Rustler knows how to turn a
    // `String` into an Erlang binary, so `.encode(env)` is the whole job. The
    // fifth field is a 15-field `Metadata` struct with no such conversion
    // available, which is why it had to be hand-built into a nested map first.
    //
    // The rule underneath both: every entry here must already be a `Term`. That
    // is also why `meta` below is inserted *without* `.encode(env)` — it came
    // back from `map_from_pairs` as a `Term` already, whereas everything else
    // needs encoding to become one.
    //
    // Note we cannot shortcut this with `#[derive(NifStruct)]` or
    // `impl Encoder for Metadata`: Rust's orphan rule needs us to own either the
    // trait or the type, and `Encoder` is Rustler's while `Metadata` is
    // trafilatura's. A newtype wrapper would be the way out in the real binding.
    Term::map_from_pairs(
        env,
        &[
            (atoms::content_text().encode(env), r.content_text.encode(env)),
            (
                atoms::comments_text().encode(env),
                r.comments_text.encode(env),
            ),
            (atoms::content_html().encode(env), r.content_html.encode(env)),
            (
                atoms::comments_html().encode(env),
                r.comments_html.encode(env),
            ),
            (atoms::metadata().encode(env), meta),
        ],
    )
    .expect("result map")
}

/// Map a `TrafilaturaError` to an Elixir-shaped term.
///
/// Total by construction: `TrafilaturaError` is `#[non_exhaustive]`, so the
/// compiler *requires* the catch-all arm — we could not write a non-total
/// mapping here even if we wanted to.
///
/// The shapes produced here are the spike's guess, not a proposal; deciding the
/// real error surface is a separate ticket.
fn encode_error<'a>(env: Env<'a>, e: &TrafilaturaError) -> Term<'a> {
    match e {
        // Rust enum variants can carry named fields, like a tagged struct. This
        // arm destructures all four of them into local variables at once —
        // closest Elixir analogue is matching `%{text_len: text_len, ...}`.
        TrafilaturaError::InsufficientContent {
            text_len,
            comment_len,
            min_output_size,
            min_output_comment_size,
        } => {
            // Keep the structured payload rather than flattening to a bare atom,
            // so the spike can show what information is actually available.
            let payload = Term::map_from_pairs(
                env,
                &[
                    (atoms::text_len().encode(env), text_len.encode(env)),
                    (atoms::comment_len().encode(env), comment_len.encode(env)),
                    (
                        atoms::min_output_size().encode(env),
                        min_output_size.encode(env),
                    ),
                    (
                        atoms::min_output_comment_size().encode(env),
                        min_output_comment_size.encode(env),
                    ),
                ],
            )
            .expect("insufficient_content payload");

            // A Rust 2-tuple encodes as an Erlang 2-tuple, so this is
            // `{:insufficient_content, %{...}}`.
            (atoms::insufficient_content(), payload).encode(env)
        }

        // A single-field variant: `MissingMetadata(String)`. `field` is bound to
        // the inner string; `.as_str()` borrows it as a `&str` to encode.
        TrafilaturaError::MissingMetadata(field) => {
            (atoms::missing_metadata(), field.as_str()).encode(env)
        }

        TrafilaturaError::LanguageMismatch { expected, got } => {
            let payload = Term::map_from_pairs(
                env,
                &[
                    (atoms::expected().encode(env), expected.as_str().encode(env)),
                    (atoms::got().encode(env), got.as_str().encode(env)),
                ],
            )
            .expect("language_mismatch payload");
            (atoms::language_mismatch(), payload).encode(env)
        }

        // No payload at all, so it becomes a bare atom rather than a tuple.
        TrafilaturaError::DuplicateContent => atoms::duplicate_content().encode(env),

        TrafilaturaError::TreeTooLarge(n) => (atoms::tree_too_large(), n.encode(env)).encode(env),

        // Required by `#[non_exhaustive]`: because upstream can add variants in a
        // minor release, the compiler refuses to believe the arms above are
        // exhaustive and forces this fallback. `other` binds whatever is left.
        // `format!("{other}")` renders it via its Display impl (the `#[error(...)]`
        // strings on the enum) so we at least surface something readable.
        //
        // This also covers `ParseError` and `Io`, which exist on the enum but are
        // unreachable in 0.3.0.
        other => (atoms::unknown(), format!("{other}")).encode(env),
    }
}

/// `Options` is `#[non_exhaustive]` too, so it cannot be built with a struct
/// literal from outside the crate — even with `..Default::default()`. Every
/// option has to go through `default()` plus field assignment or a builder.
///
/// The spike deliberately uses stock defaults and exposes no options at all;
/// choosing the real options surface is a separate ticket this must not
/// pre-empt.
fn spike_options() -> Options {
    Options::default()
}

// ---------------------------------------------------------------------------
// The NIFs
// ---------------------------------------------------------------------------
//
// `#[rustler::nif]` is a procedural macro: it reads the function below it and
// generates the C-ABI shim the BEAM actually calls, including decoding the
// arguments and encoding the return value.
//
// `schedule = "DirtyCpu"` moves the call onto a **dirty CPU scheduler** — a
// separate, bounded pool of OS threads (default: one per core) reserved for work
// too long for a normal scheduler's ~1 ms budget. Extraction averages ~4.8 ms, so
// it must not run on a normal scheduler; doing so would stall unrelated Erlang
// processes sharing that scheduler.
//
// Note the `html: &str` parameter on each of these. Rustler decodes the incoming
// Erlang binary into a Rust string slice, which **requires valid UTF-8** — an
// invalid binary raises `argument error` before the body ever runs. That is
// finding #4 in the README, and the reason ticket #14 exists.

/// Baseline: pay the binary-in cost and nothing else.
///
/// Exists purely so the benchmark can subtract argument marshalling from the
/// other two timings. Returning `html.len()` is just to stop the optimiser
/// deciding the argument was never used.
#[rustler::nif(schedule = "DirtyCpu")]
fn noop(html: &str) -> usize {
    html.len()
}

/// Extract, then throw the result away. Difference against `extract_full`
/// isolates the cost of encoding across the boundary.
///
/// This is the control in the cost measurement: it does all the same extraction
/// work but builds no Erlang terms, so `extract_full - extract_discard` is the
/// encoding cost.
#[rustler::nif(schedule = "DirtyCpu")]
fn extract_discard(html: &str) -> usize {
    let opts = spike_options();

    // `catch_unwind` runs a closure and converts a Rust panic into an `Err`
    // instead of letting it unwind past this point. `AssertUnwindSafe` is us
    // telling the compiler "yes, I know a panic could leave the captured data
    // half-updated, and I accept that" — without it, the borrow checker refuses
    // closures that capture references.
    //
    // The result is doubly nested: the outer `Result` is panic-or-not, the inner
    // one is trafilatura's own `Result`.
    match catch_unwind(AssertUnwindSafe(|| extract(html, &opts))) {
        Ok(Ok(r)) => r.content_text.len(), // extracted fine
        Ok(Err(_)) => 0,                   // a normal typed error
        Err(_) => usize::MAX,              // panicked; sentinel so it is visible
    }
}

/// The real round trip: extract and hand back a complete result map.
///
/// This is the function the whole ticket is about. Note the extra `env: Env<'a>`
/// first parameter — Rustler recognises it and supplies it automatically, so
/// Elixir still calls this with arity 1 (`SpikeNif.extract_full(html)`). We need
/// it because we build terms by hand rather than returning a plain Rust value.
#[rustler::nif(schedule = "DirtyCpu")]
fn extract_full<'a>(env: Env<'a>, html: &str) -> Term<'a> {
    let opts = spike_options();
    match catch_unwind(AssertUnwindSafe(|| extract(html, &opts))) {
        // Success: `{:ok, %{...}}`
        Ok(Ok(r)) => (atoms::ok(), encode_result(env, &r)).encode(env),
        // Typed failure from the crate: `{:error, <mapped variant>}`
        Ok(Err(e)) => (atoms::error(), encode_error(env, &e)).encode(env),
        // A panic we swallowed: `{:error, :panic}`. Compare `extract_unguarded`
        // below — this arm is what our own `catch_unwind` actually buys us.
        Err(_) => (atoms::error(), atoms::panic()).encode(env),
    }
}

/// Same call with NO `catch_unwind`, so we can observe what Rustler does on its
/// own when the crate panics.
///
/// This is the experiment behind README finding #2. Rustler's generated shim
/// already wraps the body in `catch_unwind` and converts a panic into an Erlang
/// raise of `:nif_panicked`, so the VM survives this too — which means our own
/// guard above controls the *shape* of the failure, not whether the node lives.
#[rustler::nif(schedule = "DirtyCpu")]
fn extract_unguarded<'a>(env: Env<'a>, html: &str) -> Term<'a> {
    let opts = spike_options();
    match extract(html, &opts) {
        Ok(r) => (atoms::ok(), encode_result(env, &r)).encode(env),
        Err(e) => (atoms::error(), encode_error(env, &e)).encode(env),
    }
}

/// Panic on demand, guarded — proves the wrapper catches.
///
/// A control for the two `extract_*` variants: it panics unconditionally, so if
/// this returns `:panic` rather than raising, we know the guard works and the
/// straddling-date result was not a fluke.
///
/// The `-> u8` annotation on the closure is only there because `panic!()` never
/// returns, leaving Rust unable to infer what type the closure would have
/// produced; any type would do.
#[rustler::nif(schedule = "DirtyCpu")]
fn panic_guarded() -> rustler::Atom {
    match catch_unwind(AssertUnwindSafe(|| -> u8 {
        panic!("spike: deliberate panic inside catch_unwind");
    })) {
        Ok(_) => atoms::ok(),
        Err(_) => atoms::panic(),
    }
}

/// Panic on demand, unguarded — shows Rustler's own behaviour.
///
/// Run only from `unguarded.exs`, in a child VM, on the assumption this might
/// take the node down. It does not — that is the finding.
#[rustler::nif(schedule = "DirtyCpu")]
fn panic_unguarded() -> rustler::Atom {
    panic!("spike: deliberate panic with no catch_unwind");
}

// Registers every `#[rustler::nif]` in this crate against the named Elixir
// module, and generates the `load` entry point the BEAM calls on `dlopen`.
//
// The string must match the Elixir module exactly — `Elixir.` prefix included,
// since that is the real underlying atom for the module `SpikeNif`. The
// function list is collected automatically by the macro, which is why adding a
// NIF above needs no change here.
//
// (Plain `//` rather than `///` deliberately: a doc comment on a macro
// invocation is discarded during expansion, and rustc warns about it.)
rustler::init!("Elixir.SpikeNif");
