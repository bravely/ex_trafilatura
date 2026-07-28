//! Dumps `trafilatura::extract`'s full output for every page in a corpus, in a
//! form two builds can be diffed byte for byte.
//!
//! This one file is the whole harness, and it is compiled twice — `stock/` links
//! the published 0.3.0 from crates.io, `patched/` links the vendored copy. The
//! two cannot coexist in one build, because `[patch.crates-io]` rewrites every
//! path to that crate (ADR-0003 §1). Two thin manifests over one source file is
//! what "one harness compiled twice" means mechanically.
//!
//! ```text
//! drift-dump <corpus-dir> <out-dir>
//! ```
//!
//! `tools/verify/drift.sh` drives it. `tools/verify/README.md` says when it runs
//! and what a non-empty diff obliges.

use std::any::Any;
use std::ffi::OsStr;
use std::fs;
use std::panic;
use std::path::{Path, PathBuf};
use std::process::ExitCode;
use std::sync::Mutex;

use trafilatura::{ExtractResult, Options};

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let [corpus, out_dir] = args.as_slice() else {
        eprintln!("usage: drift-dump <corpus-dir> <out-dir>");
        return ExitCode::FAILURE;
    };

    match run(Path::new(corpus), Path::new(out_dir)) {
        Ok(tally) => {
            println!("{tally}");
            ExitCode::SUCCESS
        }
        Err(error) => {
            eprintln!("drift-dump: {error}");
            ExitCode::FAILURE
        }
    }
}

fn run(corpus: &Path, out_dir: &Path) -> Result<Tally, String> {
    let pages = collect_pages(corpus)?;
    if pages.is_empty() {
        return Err(format!("no .html files under {}", corpus.display()));
    }

    // The crate panicking is an outcome we record rather than a crash: patch
    // `0002` fixes a panic reachable from a meta tag, so the stock side is
    // expected to hit it if any corpus page carries one. Without this the run
    // dies on the first such page and reports nothing.
    install_panic_hook();

    let mut tally = Tally::default();
    fs::create_dir_all(out_dir).map_err(|e| format!("cannot create {}: {e}", out_dir.display()))?;

    for page in &pages {
        let relative = page
            .strip_prefix(corpus)
            .expect("collect_pages only yields paths under corpus");
        let bytes = fs::read(page).map_err(|e| format!("cannot read {}: {e}", page.display()))?;

        // Both sides are handed the identical string, so how we decode cannot
        // hide drift — it only decides what the corpus means. Lossy keeps every
        // page in the run; upstream's own loader sniffs windows-1252, but that
        // is its scoring loader, not anything on `extract/1`'s path (ADR-0005).
        let html = match String::from_utf8(bytes) {
            Ok(utf8) => utf8,
            Err(invalid) => {
                tally.lossy += 1;
                String::from_utf8_lossy(invalid.as_bytes()).into_owned()
            }
        };

        let outcome = extract_catching_panics(&html);
        tally.count(&outcome);

        let target = out_dir.join(relative).with_extension("html.dump");
        if let Some(parent) = target.parent() {
            fs::create_dir_all(parent)
                .map_err(|e| format!("cannot create {}: {e}", parent.display()))?;
        }
        fs::write(&target, outcome.render())
            .map_err(|e| format!("cannot write {}: {e}", target.display()))?;
    }

    Ok(tally)
}

/// Every `.html` file under `root`, sorted, so the two sides walk the corpus in
/// the same order and a dump is addressable by the page it came from.
fn collect_pages(root: &Path) -> Result<Vec<PathBuf>, String> {
    let mut pages = Vec::new();
    let mut queue = vec![root.to_path_buf()];

    while let Some(dir) = queue.pop() {
        let entries =
            fs::read_dir(&dir).map_err(|e| format!("cannot read {}: {e}", dir.display()))?;
        for entry in entries {
            let entry = entry.map_err(|e| format!("cannot read {}: {e}", dir.display()))?;
            let path = entry.path();
            let file_type = entry
                .file_type()
                .map_err(|e| format!("cannot stat {}: {e}", path.display()))?;

            if file_type.is_dir() {
                queue.push(path);
            } else if path.extension().and_then(OsStr::to_str) == Some("html") {
                pages.push(path);
            }
        }
    }

    pages.sort();
    Ok(pages)
}

/// What one page produced. An error and a panic are output too: an error that
/// becomes a success, or a panic that stops happening, is drift.
enum Outcome {
    Extracted(Box<Page>),
    Failed(String),
    Panicked(String),
}

fn extract_catching_panics(html: &str) -> Outcome {
    let attempt = panic::catch_unwind(panic::AssertUnwindSafe(|| {
        trafilatura::extract(html, &Options::default())
    }));

    match attempt {
        Ok(Ok(result)) => Outcome::Extracted(Box::new(Page::from(&result))),
        Ok(Err(error)) => Outcome::Failed(error.to_string()),
        Err(payload) => Outcome::Panicked(describe_panic(payload.as_ref())),
    }
}

/// The crate's output flattened into fields this file owns.
///
/// It exists so the renderer below is testable: `ExtractResult` and `Metadata`
/// are `#[non_exhaustive]`, so no code outside the crate can construct one, not
/// even with `..Default::default()`.
#[derive(Default)]
struct Page {
    content_text: String,
    comments_text: String,
    content_html: String,
    comments_html: String,
    title: String,
    author: String,
    url: String,
    hostname: String,
    description: String,
    sitename: String,
    date: Option<String>,
    categories: Vec<String>,
    tags: Vec<String>,
    id: String,
    fingerprint: String,
    license: String,
    language: String,
    image: String,
    page_type: String,
}

impl From<&ExtractResult> for Page {
    /// Every field of `ExtractResult` and every field of `Metadata`, including
    /// the two `id` and `fingerprint` that ADR-0006 §2 keeps off the Elixir
    /// struct. The instrument watches the crate, not our projection of it — if a
    /// dependency bump starts populating `id`, that is drift worth seeing.
    fn from(result: &ExtractResult) -> Self {
        let meta = &result.metadata;
        Page {
            content_text: result.content_text.clone(),
            comments_text: result.comments_text.clone(),
            content_html: result.content_html.clone(),
            comments_html: result.comments_html.clone(),
            title: meta.title.clone(),
            author: meta.author.clone(),
            url: meta.url.clone(),
            hostname: meta.hostname.clone(),
            description: meta.description.clone(),
            sitename: meta.sitename.clone(),
            // `NaiveDate`'s `Display` is ISO 8601 `%Y-%m-%d`. Both sides link one
            // chrono, resolved from the same requirement, so even if that ever
            // changed it would change on both sides at once.
            date: meta.date.map(|date| date.to_string()),
            categories: meta.categories.clone(),
            tags: meta.tags.clone(),
            id: meta.id.clone(),
            fingerprint: meta.fingerprint.clone(),
            license: meta.license.clone(),
            language: meta.language.clone(),
            image: meta.image.clone(),
            page_type: meta.page_type.clone(),
        }
    }
}

impl Outcome {
    /// One page's dump.
    ///
    /// Every field is a header line naming it and sizing it, then its bytes,
    /// then a newline — emitted even when the field is empty, so the two sides
    /// stay line-aligned and a diff points at the field that moved.
    ///
    /// The sizes are what make the format unambiguous: content can contain any
    /// bytes at all, including lines that look exactly like a header, and a list
    /// carries both its item count and its total length so one item holding a
    /// newline is distinguishable from two items.
    fn render(&self) -> String {
        let mut out = String::new();

        match self {
            Outcome::Failed(error) => {
                out.push_str("outcome error\n");
                push_text(&mut out, "error", error);
            }
            Outcome::Panicked(panic) => {
                out.push_str("outcome panic\n");
                push_text(&mut out, "panic", panic);
            }
            Outcome::Extracted(page) => {
                out.push_str("outcome ok\n");
                push_text(&mut out, "content_text", &page.content_text);
                push_text(&mut out, "comments_text", &page.comments_text);
                push_text(&mut out, "content_html", &page.content_html);
                push_text(&mut out, "comments_html", &page.comments_html);
                push_text(&mut out, "metadata.title", &page.title);
                push_text(&mut out, "metadata.author", &page.author);
                push_text(&mut out, "metadata.url", &page.url);
                push_text(&mut out, "metadata.hostname", &page.hostname);
                push_text(&mut out, "metadata.description", &page.description);
                push_text(&mut out, "metadata.sitename", &page.sitename);
                push_date(&mut out, "metadata.date", page.date.as_deref());
                push_list(&mut out, "metadata.categories", &page.categories);
                push_list(&mut out, "metadata.tags", &page.tags);
                push_text(&mut out, "metadata.id", &page.id);
                push_text(&mut out, "metadata.fingerprint", &page.fingerprint);
                push_text(&mut out, "metadata.license", &page.license);
                push_text(&mut out, "metadata.language", &page.language);
                push_text(&mut out, "metadata.image", &page.image);
                push_text(&mut out, "metadata.page_type", &page.page_type);
            }
        }

        out
    }
}

fn push_text(out: &mut String, field: &str, value: &str) {
    out.push_str(&format!("{field} {} bytes\n", value.len()));
    out.push_str(value);
    out.push('\n');
}

fn push_date(out: &mut String, field: &str, value: Option<&str>) {
    match value {
        None => out.push_str(&format!("{field} absent\n")),
        Some(date) => push_text(out, field, date),
    }
}

fn push_list(out: &mut String, field: &str, items: &[String]) {
    let joined = items.join("\n");
    out.push_str(&format!(
        "{field} {} items, {} bytes\n",
        items.len(),
        joined.len()
    ));
    out.push_str(&joined);
    out.push('\n');
}

/// Where the last panic came from, filled by the hook because `catch_unwind`
/// hands back the payload and drops the location.
static PANIC_LOCATION: Mutex<Option<String>> = Mutex::new(None);

fn install_panic_hook() {
    panic::set_hook(Box::new(|info| {
        let location = info
            .location()
            .map_or_else(|| "unknown location".to_string(), |at| at.to_string());
        *PANIC_LOCATION
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner()) = Some(location);
    }));
}

/// A panic as one line: where it fired and what it said. Replacing the default
/// hook also silences it, which matters when a whole corpus trips the same bug.
fn describe_panic(payload: &(dyn Any + Send)) -> String {
    let message = payload
        .downcast_ref::<&str>()
        .map(|s| (*s).to_string())
        .or_else(|| payload.downcast_ref::<String>().cloned())
        .unwrap_or_else(|| "non-string panic payload".to_string());

    let location = PANIC_LOCATION
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
        .take()
        .unwrap_or_else(|| "unknown location".to_string());

    format!("{location}: {message}")
}

/// What the run saw, printed for the record that goes into `VENDOR.md`.
#[derive(Default)]
struct Tally {
    extracted: usize,
    failed: usize,
    panicked: usize,
    lossy: usize,
}

impl Tally {
    fn count(&mut self, outcome: &Outcome) {
        match outcome {
            Outcome::Extracted(_) => self.extracted += 1,
            Outcome::Failed(_) => self.failed += 1,
            Outcome::Panicked(_) => self.panicked += 1,
        }
    }
}

impl std::fmt::Display for Tally {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(
            f,
            "{} pages: {} extracted, {} errored, {} panicked ({} decoded lossily)",
            self.extracted + self.failed + self.panicked,
            self.extracted,
            self.failed,
            self.panicked,
            self.lossy
        )
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn page() -> Page {
        Page {
            content_text: "Hello".to_string(),
            title: "A title".to_string(),
            date: Some("2024-01-02".to_string()),
            categories: vec!["News".to_string(), "Sport".to_string()],
            ..Page::default()
        }
    }

    /// The field names `Debug` reports at the top level of a pretty-printed
    /// value. Derived `Debug` puts one field per line at four spaces; anything
    /// deeper belongs to a nested value.
    fn debug_field_names(pretty: &str) -> Vec<&str> {
        pretty
            .lines()
            .filter_map(|line| {
                let field = line.strip_prefix("    ")?;
                if field.starts_with(' ') {
                    return None;
                }
                field.split_once(": ").map(|(name, _)| name)
            })
            .collect()
    }

    /// The one failure this harness cannot survive quietly: upstream adds a
    /// field, `Page` does not mirror it, and the instrument reports "no drift"
    /// about a field it never looked at.
    ///
    /// Nothing else catches it. Both crate structs are `#[non_exhaustive]`, so
    /// an exhaustive match is not allowed from out here and there is no compile
    /// error to lean on — the `From` impl above just keeps copying the fields it
    /// already knew about. So this asserts the crate's field list instead, and
    /// fails the moment it grows.
    #[test]
    fn the_dump_mirrors_every_field_the_crate_declares() {
        let metadata = format!("{:#?}", trafilatura::Metadata::default());
        assert_eq!(
            debug_field_names(&metadata),
            vec![
                "title",
                "author",
                "url",
                "hostname",
                "description",
                "sitename",
                "date",
                "categories",
                "tags",
                "id",
                "fingerprint",
                "license",
                "language",
                "image",
                "page_type",
            ],
            "trafilatura::Metadata's fields have changed. Mirror the new one in \
             Page, in the From impl and in render(), or the dump silently stops \
             covering it."
        );

        let result = format!("{:#?}", ExtractResult::default());
        assert_eq!(
            debug_field_names(&result),
            vec![
                "content_text",
                "comments_text",
                "content_html",
                "comments_html",
                "metadata",
            ],
            "trafilatura::ExtractResult's fields have changed. Mirror the new \
             one in Page, in the From impl and in render()."
        );
    }

    #[test]
    fn renders_every_field_even_when_empty() {
        let dump = Outcome::Extracted(Box::default()).render();
        let headers: Vec<&str> = dump
            .lines()
            .filter(|line| {
                line.starts_with("content")
                    || line.starts_with("comments")
                    || line.starts_with("metadata")
            })
            .map(|line| line.split(' ').next().unwrap_or_default())
            .collect();

        assert_eq!(
            headers,
            vec![
                "content_text",
                "comments_text",
                "content_html",
                "comments_html",
                "metadata.title",
                "metadata.author",
                "metadata.url",
                "metadata.hostname",
                "metadata.description",
                "metadata.sitename",
                "metadata.date",
                "metadata.categories",
                "metadata.tags",
                "metadata.id",
                "metadata.fingerprint",
                "metadata.license",
                "metadata.language",
                "metadata.image",
                "metadata.page_type",
            ]
        );
    }

    #[test]
    fn renders_a_populated_page() {
        let dump = Outcome::Extracted(Box::new(page())).render();

        assert!(dump.starts_with("outcome ok\ncontent_text 5 bytes\nHello\n"));
        assert!(dump.contains("metadata.title 7 bytes\nA title\n"));
        assert!(dump.contains("metadata.date 10 bytes\n2024-01-02\n"));
        assert!(dump.contains("metadata.categories 2 items, 10 bytes\nNews\nSport\n"));
    }

    #[test]
    fn absent_date_is_not_an_empty_date() {
        let dump = Outcome::Extracted(Box::default()).render();
        assert!(dump.contains("metadata.date absent\n"));
        assert!(!dump.contains("metadata.date 0 bytes"));
    }

    #[test]
    fn sizes_are_bytes_not_characters() {
        let dump = Outcome::Extracted(Box::new(Page {
            content_text: "héllo".to_string(),
            ..Page::default()
        }))
        .render();

        assert!(dump.contains("content_text 6 bytes\nhéllo\n"));
    }

    /// Content is arbitrary bytes, including a line that reads like a header.
    /// The size is what keeps the dump readable as a record rather than prose.
    #[test]
    fn content_that_looks_like_a_header_is_still_sized_correctly() {
        let forged = "metadata.title 99 bytes\nnot a real field";
        let dump = Outcome::Extracted(Box::new(Page {
            content_text: forged.to_string(),
            ..Page::default()
        }))
        .render();

        assert!(dump.contains(&format!("content_text {} bytes\n{forged}\n", forged.len())));
        // The real header is still there, and still says the field is empty.
        assert!(dump.contains("metadata.title 0 bytes\n"));
    }

    /// One item holding a newline and two items render the same bytes; the item
    /// count is what tells them apart.
    #[test]
    fn a_list_records_its_item_count_as_well_as_its_size() {
        let one = Outcome::Extracted(Box::new(Page {
            categories: vec!["News\nSport".to_string()],
            ..Page::default()
        }))
        .render();
        let two = Outcome::Extracted(Box::new(Page {
            categories: vec!["News".to_string(), "Sport".to_string()],
            ..Page::default()
        }))
        .render();

        // Identical bytes on both sides — the item count is the only thing that
        // separates them, which is the reason it is in the header at all.
        assert!(one.contains("metadata.categories 1 items, 10 bytes\nNews\nSport\n"));
        assert!(two.contains("metadata.categories 2 items, 10 bytes\nNews\nSport\n"));
        assert_ne!(one, two);
    }

    #[test]
    fn an_error_is_an_outcome_rather_than_a_missing_dump() {
        let dump = Outcome::Failed("insufficient content".to_string()).render();
        assert_eq!(
            dump,
            "outcome error\nerror 20 bytes\ninsufficient content\n"
        );
    }

    #[test]
    fn a_panic_is_an_outcome_too() {
        let dump = Outcome::Panicked("src/metadata/mod.rs:12:5: boom".to_string()).render();
        assert_eq!(
            dump,
            "outcome panic\npanic 30 bytes\nsrc/metadata/mod.rs:12:5: boom\n"
        );
    }

    /// A page that errors and a page that extracts nothing are different
    /// outcomes, and a diff has to be able to see the difference.
    #[test]
    fn an_error_and_an_empty_extraction_do_not_render_alike() {
        assert_ne!(
            Outcome::Failed(String::new()).render(),
            Outcome::Extracted(Box::default()).render()
        );
    }
}
