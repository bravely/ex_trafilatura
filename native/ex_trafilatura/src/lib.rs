//! The ExTrafilatura NIF crate.
//!
//! This crate also pins the vendored, patched `trafilatura` through
//! `[patch.crates-io]`. See `vendor/trafilatura/VENDOR.md` for what is vendored
//! and why.
//!
//! The `Encoded*` structs below are the encode-side mirrors of the Elixir
//! structs named in their `#[module]` attributes. Their field lists and their
//! absence rules are decided in ADR-0006 §§1-3, which the Elixir moduledocs
//! state in full; the comments here say only what a reader of *this* file needs.

use chrono::{Datelike, NaiveDate};
use rustler::{Atom, Encoder, Env, NifStruct, Term};
use trafilatura::Options;

mod atoms {
    rustler::atoms! {
        ok,
        error,
        unknown,
        calendar_iso = "Elixir.Calendar.ISO",
    }
}

/// Mirrors the crate's `ExtractResult`. The four streams stay `String`: absence
/// is `""` here, and `nil` only on metadata (ADR-0006 §3).
#[derive(NifStruct)]
#[module = "ExTrafilatura.Result"]
struct EncodedResult {
    content_text: String,
    comments_text: String,
    content_html: String,
    comments_html: String,
    metadata: EncodedMetadata,
}

/// Thirteen of the crate's fifteen metadata fields, in the crate's own
/// spellings. `id` and `fingerprint` are omitted because the crate declares them
/// and never assigns them (ADR-0006 §2).
#[derive(NifStruct)]
#[module = "ExTrafilatura.Metadata"]
struct EncodedMetadata {
    title: Option<String>,
    author: Option<String>,
    url: Option<String>,
    hostname: Option<String>,
    description: Option<String>,
    sitename: Option<String>,
    date: Option<ElixirDate>,
    categories: Vec<String>,
    tags: Vec<String>,
    license: Option<String>,
    language: Option<String>,
    image: Option<String>,
    page_type: Option<String>,
}

/// Elixir's own `%Date{}`, built here so the caller receives a `Date` rather
/// than a string to parse.
#[derive(NifStruct)]
#[module = "Date"]
struct ElixirDate {
    calendar: Atom,
    year: i32,
    month: u32,
    day: u32,
}

impl From<NaiveDate> for ElixirDate {
    fn from(date: NaiveDate) -> Self {
        ElixirDate {
            calendar: atoms::calendar_iso(),
            year: date.year(),
            month: date.month(),
            day: date.day(),
        }
    }
}

/// The `"" -> nil` mapping, applied at encode time rather than as an Elixir
/// post-pass (ADR-0006 §8). It destroys no information: the crate cannot
/// distinguish an empty field from an absent one.
fn nil_if_empty(value: String) -> Option<String> {
    if value.is_empty() {
        None
    } else {
        Some(value)
    }
}

impl From<trafilatura::Metadata> for EncodedMetadata {
    fn from(meta: trafilatura::Metadata) -> Self {
        EncodedMetadata {
            title: nil_if_empty(meta.title),
            author: nil_if_empty(meta.author),
            url: nil_if_empty(meta.url),
            hostname: nil_if_empty(meta.hostname),
            description: nil_if_empty(meta.description),
            sitename: nil_if_empty(meta.sitename),
            date: meta.date.map(ElixirDate::from),
            categories: meta.categories,
            tags: meta.tags,
            license: nil_if_empty(meta.license),
            language: nil_if_empty(meta.language),
            image: nil_if_empty(meta.image),
            page_type: nil_if_empty(meta.page_type),
        }
    }
}

impl From<trafilatura::ExtractResult> for EncodedResult {
    fn from(result: trafilatura::ExtractResult) -> Self {
        EncodedResult {
            content_text: result.content_text,
            comments_text: result.comments_text,
            content_html: result.content_html,
            comments_html: result.comments_html,
            metadata: result.metadata.into(),
        }
    }
}

/// Extraction with the crate's default options.
///
/// Scheduled on a dirty CPU scheduler: extraction measured a 4.84 ms mean
/// against a ~1 ms normal-scheduler budget, and 915 of 925 real documents
/// exceeded it (ADR-0001). A yielding NIF is not implementable against this API
/// anyway — the crate is one straight-line call with no re-entry point.
#[rustler::nif(schedule = "DirtyCpu")]
fn extract<'a>(env: Env<'a>, html: &str) -> Term<'a> {
    match trafilatura::extract(html, &Options::default()) {
        Ok(result) => (atoms::ok(), EncodedResult::from(result)).encode(env),
        // Every crate error lands in ADR-0006 §6's catch-all for now, including
        // `InsufficientContent`, which is the one a caller actually hits under
        // default options. Carving the three reachable reasons out of it is
        // #32's work, and two of them are only armed by options #30 adds.
        Err(error) => (atoms::error(), (atoms::unknown(), error.to_string())).encode(env),
    }
}

/// The vendored crate's version marker, read out of its `Cargo.toml` at compile
/// time by `build.rs` rather than copied here (ADR-0004 §1).
#[rustler::nif]
fn crate_version() -> &'static str {
    env!("TRAFILATURA_VERSION")
}

rustler::init!("Elixir.ExTrafilatura.Native");
