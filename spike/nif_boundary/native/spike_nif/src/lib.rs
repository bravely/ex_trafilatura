//! THROWAWAY SPIKE — see ../../README.md.
//!
//! Question: can a Rustler NIF on a dirty CPU scheduler, wrapped in
//! `catch_unwind`, call `trafilatura::extract` and hand a complete
//! `ExtractResult` + `Metadata` back to Elixir — and what does that cost?
//!
//! Nothing here is a proposal for the real binding. In particular the encoding
//! below deliberately does NOT map `""` to `nil`, because that is a separate
//! open decision; the spike's job is to show what the raw values look like.

use rustler::{Encoder, Env, Term};
use std::panic::{catch_unwind, AssertUnwindSafe};
use trafilatura::{extract, ExtractResult, Options, TrafilaturaError};

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

/// Build the result map field-by-field.
///
/// `ExtractResult` and `Metadata` are `#[non_exhaustive]`, so we cannot
/// destructure them exhaustively — but reading named fields is unaffected, and
/// that is all this does. If upstream adds a field in a minor release, this
/// keeps compiling and silently ignores it.
fn encode_result<'a>(env: Env<'a>, r: &ExtractResult) -> Term<'a> {
    let m = r.metadata.clone();

    let date_term = match m.date {
        Some(d) => d.to_string().encode(env),
        None => atoms::nil().encode(env),
    };

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
    .expect("metadata map");

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

/// Total by construction: `TrafilaturaError` is `#[non_exhaustive]`, so the
/// compiler *requires* the catch-all arm — we could not write a non-total
/// mapping here even if we wanted to.
fn encode_error<'a>(env: Env<'a>, e: &TrafilaturaError) -> Term<'a> {
    match e {
        TrafilaturaError::InsufficientContent {
            text_len,
            comment_len,
            min_output_size,
            min_output_comment_size,
        } => {
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
            (atoms::insufficient_content(), payload).encode(env)
        }
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
        TrafilaturaError::DuplicateContent => atoms::duplicate_content().encode(env),
        TrafilaturaError::TreeTooLarge(n) => (atoms::tree_too_large(), n.encode(env)).encode(env),
        // Required by `#[non_exhaustive]`. Also covers the two variants that
        // are unreachable in 0.3.0 (`ParseError`, `Io`).
        other => (atoms::unknown(), format!("{other}")).encode(env),
    }
}

/// `Options` is `#[non_exhaustive]` too, so it cannot be built with a struct
/// literal from outside the crate — even with `..Default::default()`. Every
/// option has to go through `default()` plus field assignment or a builder.
fn spike_options() -> Options {
    Options::default()
}

// ---------------------------------------------------------------------------
// The NIFs
// ---------------------------------------------------------------------------

/// Baseline: pay the binary-in cost and nothing else.
#[rustler::nif(schedule = "DirtyCpu")]
fn noop(html: &str) -> usize {
    html.len()
}

/// Extract, then throw the result away. Difference against `extract_full`
/// isolates the cost of encoding across the boundary.
#[rustler::nif(schedule = "DirtyCpu")]
fn extract_discard(html: &str) -> usize {
    let opts = spike_options();
    match catch_unwind(AssertUnwindSafe(|| extract(html, &opts))) {
        Ok(Ok(r)) => r.content_text.len(),
        Ok(Err(_)) => 0,
        Err(_) => usize::MAX,
    }
}

/// The real round trip: extract and hand back a complete result map.
#[rustler::nif(schedule = "DirtyCpu")]
fn extract_full<'a>(env: Env<'a>, html: &str) -> Term<'a> {
    let opts = spike_options();
    match catch_unwind(AssertUnwindSafe(|| extract(html, &opts))) {
        Ok(Ok(r)) => (atoms::ok(), encode_result(env, &r)).encode(env),
        Ok(Err(e)) => (atoms::error(), encode_error(env, &e)).encode(env),
        Err(_) => (atoms::error(), atoms::panic()).encode(env),
    }
}

/// Same call with NO `catch_unwind`, so we can observe what Rustler does on its
/// own when the crate panics.
#[rustler::nif(schedule = "DirtyCpu")]
fn extract_unguarded<'a>(env: Env<'a>, html: &str) -> Term<'a> {
    let opts = spike_options();
    match extract(html, &opts) {
        Ok(r) => (atoms::ok(), encode_result(env, &r)).encode(env),
        Err(e) => (atoms::error(), encode_error(env, &e)).encode(env),
    }
}

/// Panic on demand, guarded — proves the wrapper catches.
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
#[rustler::nif(schedule = "DirtyCpu")]
fn panic_unguarded() -> rustler::Atom {
    panic!("spike: deliberate panic with no catch_unwind");
}

rustler::init!("Elixir.SpikeNif");
