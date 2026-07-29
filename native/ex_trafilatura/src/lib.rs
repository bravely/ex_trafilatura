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
//! `Reason` is the same thing for the failing half of the return value, and its
//! terms are ADR-0006 §4's.
//!
//! `Overrides` is the one decode-side struct, and its counterpart is
//! `ExTrafilatura.Options` rather than anything a caller sees. Values reaching
//! it have already been validated in Elixir, which is where a bad option can
//! still be attributed to the key that carried it.

use std::any::Any;
use std::panic::catch_unwind;

use chrono::{Datelike, NaiveDate};
use rustler::{Atom, Encoder, Env, NifStruct, NifTaggedEnum, NifUnitEnum, Term};
use trafilatura::{ExtractionFocus, Options, TrafilaturaError};
use url::Url;

mod atoms {
    rustler::atoms! {
        ok,
        error,
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

/// The three fields `has_essential_metadata` demands, in the crate's own
/// checking order.
///
/// An atom rather than the crate's `String`, because the set is closed at three
/// by construction: `MissingMetadata` is built at exactly three call sites, with
/// these three literals (ADR-0006 §4).
#[derive(NifUnitEnum, Debug, PartialEq)]
#[rustler(encode)]
enum MissingField {
    Title,
    Url,
    Date,
}

/// The reason half of `{:error, reason}` — ADR-0006 §4's term set, less the two
/// the Elixir side decides for itself before the NIF is ever reached.
///
/// `NifTaggedEnum` is what makes the shape structural rather than remembered: a
/// unit variant encodes as a bare atom and a newtype variant as a two-tuple, so
/// "no error term is a map, and every payload is a single value" holds by
/// construction rather than by five hand-written encode arms agreeing.
#[derive(NifTaggedEnum, Debug, PartialEq)]
#[rustler(encode)]
enum Reason {
    InsufficientContent,
    MissingMetadata(MissingField),
    LanguageMismatch(Option<String>),
    Panic(String),
    Unknown(String),
}

/// The one rule, applied: **carry exactly what the caller does not already
/// have.** Where the crate's payload is constants or an echo of the caller's own
/// input it is dropped; where it is information it is kept, as a single value.
///
/// `TrafilaturaError` is `#[non_exhaustive]`, so this match must be total —
/// which is what `Reason::Unknown` is for. It takes the crate's own `Display`
/// from one arm, so a variant added upstream arrives in the crate's own words
/// with no edit here. **That string is diagnostic, not contract** (ADR-0006 §6).
impl From<TrafilaturaError> for Reason {
    fn from(error: TrafilaturaError) -> Self {
        match error {
            // Four typed fields, and every one of them a constant: `config` is
            // not an exposed option, so both minimums are permanently 1 and both
            // lengths permanently 0. The day `config` ships, this grows a payload
            // by the same rule that denies it one now.
            TrafilaturaError::InsufficientContent { .. } => Reason::InsufficientContent,

            // `expected` is the caller's own `target_language` handed back. What
            // is left is the verdict, and `None` is "could not determine" —
            // which is the distinction worth carrying, and the whole reason this
            // reason is not a bare atom. It is *not* a marker for which of the
            // crate's two construction sites fired: the early one sets `got` to
            // the empty string unconditionally, and the late one does too
            // whenever the classifier cannot place the extracted text.
            TrafilaturaError::LanguageMismatch { got, .. } => {
                Reason::LanguageMismatch(nil_if_empty(got))
            }

            // The catch-all arm below would swallow a fourth field silently, so
            // this one is written to fall into it loudly instead: a re-vendor
            // that adds a `MissingMetadata("author")` reaches the caller as
            // `{:unknown, "missing required metadata: author"}` rather than as a
            // fourth atom nothing documents.
            TrafilaturaError::MissingMetadata(ref field) => match field.as_str() {
                "title" => Reason::MissingMetadata(MissingField::Title),
                "url" => Reason::MissingMetadata(MissingField::Url),
                "date" => Reason::MissingMetadata(MissingField::Date),
                _ => Reason::Unknown(error.to_string()),
            },

            // Four variants land here today, not hypothetically: `DuplicateContent`
            // and `TreeTooLarge` are unreachable because their arming options are
            // not exposed, and `ParseError` and `Io` are vestigial in 0.3.0.
            other => Reason::Unknown(other.to_string()),
        }
    }
}

/// The panic payload, as the message it started life as.
///
/// `catch_unwind` hands back a `Box<dyn Any>`, and `panic!` only ever puts two
/// things in it: a `&'static str` for a literal message and a `String` for a
/// formatted one. Anything else came from `panic_any` and has no message to
/// recover, so the term says so rather than pretending.
///
/// The box is taken **by value**, and that is the load-bearing part of this
/// signature rather than an ownership preference. `Box<dyn Any + Send>` is
/// itself `Any`, so a `&(dyn Any + Send)` parameter would silently accept a
/// `&Box<..>` describing the box rather than what is inside it, and every
/// downcast would miss. Taking it by value puts that mistake out of reach.
fn panic_message(payload: Box<dyn Any + Send>) -> String {
    if let Some(message) = payload.downcast_ref::<&'static str>() {
        (*message).to_string()
    } else if let Some(message) = payload.downcast_ref::<String>() {
        message.clone()
    } else {
        "panicked with a payload that was neither a &str nor a String".to_string()
    }
}

/// The crate's `ExtractionFocus`, decoded from the three atoms `extract/2`
/// accepts. A local mirror because the derive cannot be applied to a foreign
/// type; the consequence worth knowing is that the crate's enum is
/// `#[non_exhaustive]`, so a variant added upstream reaches callers only when
/// someone adds it here too.
#[derive(NifUnitEnum)]
enum Focus {
    Balanced,
    FavorPrecision,
    FavorRecall,
}

impl From<Focus> for ExtractionFocus {
    fn from(focus: Focus) -> Self {
        match focus {
            Focus::Balanced => ExtractionFocus::Balanced,
            Focus::FavorPrecision => ExtractionFocus::FavorPrecision,
            Focus::FavorRecall => ExtractionFocus::FavorRecall,
        }
    }
}

/// The twelve crate options `extract/2` exposes, in the crate's own names and
/// the crate's own senses — which are *mixed*, two negative and two positive,
/// because the crate mixes them and matching names is what lets a caller read
/// the crate's docs.
///
/// Every field is optional, and `None` means the caller did not name the key.
/// That is what keeps `extract/1` the crate's default call: an unnamed key
/// resolves to whatever `Options::default()` already holds, so an empty keyword
/// list cannot rebuild the crate's defaults out of values of ours that could
/// drift from them. `no_overrides_is_the_crates_default_call` below is the
/// proof.
///
/// A struct rather than a map, because the derived decoder reads every field
/// and a merely-absent key is a decode failure rather than a `None`. Elixir's
/// `%ExTrafilatura.Options{}` cannot be short a field, so that failure is
/// unreachable instead of merely untested.
#[derive(NifStruct)]
#[module = "ExTrafilatura.Options"]
struct Overrides {
    focus: Option<Focus>,
    exclude_comments: Option<bool>,
    exclude_tables: Option<bool>,
    include_links: Option<bool>,
    include_images: Option<bool>,
    enable_fallback: Option<bool>,
    target_language: Option<String>,
    has_essential_metadata: Option<bool>,
    original_url: Option<String>,
    prune_selector: Option<String>,
    excluded_authors: Option<Vec<String>>,
    // A `{year, month, day}` triple rather than the `%Date{}` the caller passes.
    // `ElixirDate` above is the encode side, and its `calendar` field only ever
    // takes the one value; sending the triple keeps the calendar question where
    // it can be answered, which is Elixir, and keeps this struct decodable
    // outside a running VM so the tests below can construct one.
    html_date_override: Option<(i32, u32, u32)>,
}

impl Overrides {
    /// Applies onto `Options::default()`.
    ///
    /// The two `Err` arms are unreachable through `ExTrafilatura.extract/2`,
    /// which validates in Elixir so that it can raise an `ArgumentError` naming
    /// the key. They are the backstop, in the same sense ADR-0005 §2 gives the
    /// UTF-8 gate: badarg is what is left when the gate in front has already
    /// made the case impossible.
    fn apply(self) -> Result<Options, rustler::Error> {
        let mut options = Options::default();

        // `unwrap_or`, so that an unnamed key writes the crate's own default
        // back over itself rather than a value of ours. The crate's field name
        // stays on the left of every line, which is the property worth keeping
        // greppable — a macro over the twelve would be shorter and would lose
        // it.
        options.focus = self.focus.map_or(options.focus, Focus::into);
        options.exclude_comments = self.exclude_comments.unwrap_or(options.exclude_comments);
        options.exclude_tables = self.exclude_tables.unwrap_or(options.exclude_tables);
        options.include_links = self.include_links.unwrap_or(options.include_links);
        options.include_images = self.include_images.unwrap_or(options.include_images);
        options.enable_fallback = self.enable_fallback.unwrap_or(options.enable_fallback);
        options.target_language = self.target_language.or(options.target_language);
        options.has_essential_metadata = self
            .has_essential_metadata
            .unwrap_or(options.has_essential_metadata);
        options.prune_selector = self.prune_selector.or(options.prune_selector);
        options.excluded_authors = self.excluded_authors.unwrap_or(options.excluded_authors);

        // The two that can fail, and so the two that cannot be an assignment.
        if let Some(url) = self.original_url {
            options.original_url = Some(Url::parse(&url).or(Err(rustler::Error::BadArg))?);
        }
        if let Some((year, month, day)) = self.html_date_override {
            let date = NaiveDate::from_ymd_opt(year, month, day).ok_or(rustler::Error::BadArg)?;
            options.html_date_override = Some(date);
        }

        Ok(options)
    }
}

/// Extraction, under the crate's default options as adjusted by whichever of
/// them the caller named.
///
/// Scheduled on a dirty CPU scheduler: extraction measured a 4.84 ms mean
/// against a ~1 ms normal-scheduler budget, and 915 of 925 real documents
/// exceeded it (ADR-0001). A yielding NIF is not implementable against this API
/// anyway — the crate is one straight-line call with no re-entry point.
#[rustler::nif(schedule = "DirtyCpu")]
fn extract<'a>(env: Env<'a>, html: &str, overrides: Overrides) -> Result<Term<'a>, rustler::Error> {
    let options = overrides.apply()?;

    // A second `catch_unwind`, inside the one Rustler already wraps this body
    // in. That one catches the unwind and *discards the payload*, leaving Elixir
    // a bare `:nif_panicked` with the message on OS stderr, where most
    // deployments never see it; this one recovers the message and returns it as
    // a term (ADR-0006 §7).
    //
    // Unwind safety is satisfied rather than asserted, which is why no
    // `AssertUnwindSafe` appears here: extraction is a pure function over a
    // `&str`, so there is no observable state an unwind could leave
    // inconsistent. The guard's limit is the one `catch_unwind` always has —
    // it does not catch a stack overflow or an abort. The crate's own
    // `MAX_TREE_DEPTH` bound is what covers that.
    //
    // It wraps the crate's call and nothing else on purpose. Encoding the
    // result is ours, is field moves and `nil_if_empty`, and has no panicking
    // path; widening the guard over it would put a `Term` inside a closure that
    // has to be unwind-safe for no gain. The untrusted document is what this
    // guards against, and it reaches only as far as the line below.
    let extraction = catch_unwind(|| trafilatura::extract(html, &options));

    Ok(match extraction {
        Ok(Ok(result)) => (atoms::ok(), EncodedResult::from(result)).encode(env),
        Ok(Err(error)) => (atoms::error(), Reason::from(error)).encode(env),
        Err(payload) => (atoms::error(), Reason::Panic(panic_message(payload))).encode(env),
    })
}

/// The vendored crate's version marker, read out of its `Cargo.toml` at compile
/// time by `build.rs` rather than copied here (ADR-0004 §1).
#[rustler::nif]
fn crate_version() -> &'static str {
    env!("TRAFILATURA_VERSION")
}

rustler::init!("Elixir.ExTrafilatura.Native");

#[cfg(test)]
mod tests {
    use super::*;

    /// What `ExTrafilatura.extract/1` sends: every key present, every one unset.
    fn no_overrides() -> Overrides {
        Overrides {
            focus: None,
            exclude_comments: None,
            exclude_tables: None,
            include_links: None,
            include_images: None,
            enable_fallback: None,
            target_language: None,
            has_essential_metadata: None,
            original_url: None,
            prune_selector: None,
            excluded_authors: None,
            html_date_override: None,
        }
    }

    /// The equivalence the whole verification posture is levered on:
    /// `extract/1` *is* `trafilatura::extract(html, &Options::default())`, so
    /// expectations may be borrowed from the crate's own tests and docs
    /// (ADR-0003 §1 and §3). Elixir can only pin it behaviourally, one document
    /// at a time; this pins it structurally, over the whole options struct at
    /// once — including the six fields we deliberately do not expose, which no
    /// Elixir test can reach.
    ///
    /// Compared through `Debug` because the crate's `Options` is
    /// `#[non_exhaustive]` and derives no `PartialEq`. That has a second
    /// benefit: a field added upstream joins the comparison without our
    /// touching this test.
    #[test]
    fn no_overrides_is_the_crates_default_call() {
        let applied = no_overrides().apply().expect("no override can fail");

        assert_eq!(format!("{applied:?}"), format!("{:?}", Options::default()));
    }

    /// The other half of the same claim: an override that *is* named lands on
    /// the field of the crate's own name, in the crate's own sense. Guards
    /// against a copy-paste in `apply`'s twelve near-identical arms — the exact
    /// mistake that surface is shaped to invite.
    #[test]
    fn a_named_override_lands_on_the_crates_own_field() {
        let overrides = Overrides {
            focus: Some(Focus::FavorPrecision),
            exclude_comments: Some(true),
            exclude_tables: Some(true),
            include_links: Some(true),
            include_images: Some(true),
            enable_fallback: Some(true),
            target_language: Some("de".into()),
            has_essential_metadata: Some(true),
            original_url: Some("https://example.com/an-article".into()),
            prune_selector: Some(".sidebar".into()),
            excluded_authors: Some(vec!["Ada Lovelace".into()]),
            html_date_override: Some((1999, 12, 31)),
        };

        let options = overrides.apply().expect("every value above is valid");

        assert_eq!(options.focus, ExtractionFocus::FavorPrecision);
        assert!(options.exclude_comments);
        assert!(options.exclude_tables);
        assert!(options.include_links);
        assert!(options.include_images);
        assert!(options.enable_fallback);
        assert_eq!(options.target_language.as_deref(), Some("de"));
        assert!(options.has_essential_metadata);
        assert_eq!(
            options.original_url.map(|url| url.to_string()),
            Some("https://example.com/an-article".to_string())
        );
        assert_eq!(options.prune_selector.as_deref(), Some(".sidebar"));
        assert_eq!(options.excluded_authors, vec!["Ada Lovelace".to_string()]);
        assert_eq!(
            options.html_date_override,
            NaiveDate::from_ymd_opt(1999, 12, 31)
        );
    }

    // The error mapping, tested one step short of the wire. `Reason` is the
    // decision and the derived `Encoder` is the transcription, and only the
    // decision can be tested here: an `Env` exists only inside a NIF call, so
    // there is no VM under `cargo test` to encode a term into. The shapes the
    // derive produces are pinned from Elixir instead, in `test/errors_test.exs`
    // — except for the two below, which no document can reach through
    // `extract/2` and which are therefore only ever tested here (ADR-0006
    // "Consequences").

    /// `{:unknown, message}`, over every variant that falls into it today.
    /// Synthetic values, because that is the only way to build four errors the
    /// crate will not construct: two whose arming option `extract/2` does not
    /// expose, and two that are vestigial in 0.3.0.
    #[test]
    fn the_catch_all_takes_the_crates_own_words() {
        assert_eq!(
            Reason::from(TrafilaturaError::TreeTooLarge(4231)),
            Reason::Unknown("output tree too large: 4231 elements".to_string())
        );
        assert_eq!(
            Reason::from(TrafilaturaError::DuplicateContent),
            Reason::Unknown("extracted body is a duplicate".to_string())
        );
        assert_eq!(
            Reason::from(TrafilaturaError::ParseError("unclosed tag".to_string())),
            Reason::Unknown("failed to parse HTML: unclosed tag".to_string())
        );
        assert_eq!(
            Reason::from(TrafilaturaError::Io(std::io::Error::other("broken pipe"))),
            Reason::Unknown("IO error: broken pipe".to_string())
        );
    }

    /// The arm that keeps the closed set of three closed. A fourth essential
    /// field would be a re-vendor's doing, not a caller's, and it must not
    /// quietly become a fourth atom nothing documents.
    #[test]
    fn a_fourth_essential_field_falls_to_the_catch_all() {
        assert_eq!(
            Reason::from(TrafilaturaError::MissingMetadata("author".to_string())),
            Reason::Unknown("missing required metadata: author".to_string())
        );
    }

    /// `{:panic, message}`, over a panic the vendored crate has been patched to
    /// prevent — so this raises one directly. Both payload types `panic!`
    /// produces are covered: a literal message is a `&'static str`, a formatted
    /// one a `String`.
    #[test]
    fn the_guard_recovers_the_message_rustler_discards() {
        let literal = catch_unwind(|| panic!("index out of bounds")).expect_err("it panicked");
        let formatted =
            catch_unwind(|| panic!("byte index {} is not a char boundary", 8)).expect_err("ditto");

        assert_eq!(panic_message(literal), "index out of bounds");
        assert_eq!(
            panic_message(formatted),
            "byte index 8 is not a char boundary"
        );
    }

    /// The three reachable reasons. Elixir pins these end to end against real
    /// documents; what this adds is the payload the caller *does not* receive,
    /// which no Elixir assertion can see the absence of — four constant fields
    /// dropped, and the caller's own `target_language` echoed back and dropped.
    #[test]
    fn a_payload_the_caller_already_holds_is_dropped() {
        assert_eq!(
            Reason::from(TrafilaturaError::InsufficientContent {
                text_len: 0,
                comment_len: 0,
                min_output_size: 1,
                min_output_comment_size: 1,
            }),
            Reason::InsufficientContent
        );

        assert_eq!(
            Reason::from(TrafilaturaError::LanguageMismatch {
                expected: "de".to_string(),
                got: "en".to_string(),
            }),
            Reason::LanguageMismatch(Some("en".to_string()))
        );

        // The crate's early construction site, which returns before any text is
        // classified and so sets `got` to the empty string unconditionally.
        assert_eq!(
            Reason::from(TrafilaturaError::LanguageMismatch {
                expected: "en".to_string(),
                got: String::new(),
            }),
            Reason::LanguageMismatch(None)
        );
    }
}
