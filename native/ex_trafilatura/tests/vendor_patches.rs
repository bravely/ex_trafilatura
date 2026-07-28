//! Regression tests for the patches carried in `vendor/patches/`.
//!
//! These assert on the vendored crate rather than on our own code, because the
//! patches are the only reason its behaviour differs from published 0.3.0. If a
//! future re-vendor drops a patch, this is what notices.

use trafilatura::{extract, Options};

/// `1234567é9` puts a two-byte `é` across byte 8 — the boundary
/// `fast_parse_date` slices at when it tests for a bare `YYYYMMDD` date.
/// Attacker-reachable, since the value comes from a meta tag in an untrusted
/// document. Fixed by `0002-fix-char-boundary-panic.patch`.
const PUBLISHED_TIME_SPLITTING_A_CHARACTER: &str = r#"<!DOCTYPE html>
<html lang="en">
  <head>
    <title>A boundary case</title>
    <meta property="article:published_time" content="1234567é9">
  </head>
  <body>
    <article>
      <p>The published time above is not a date. It is nine characters long in
      bytes but not in characters, and the eighth byte lands in the middle of
      one of them.</p>
      <p>This paragraph is here so the document carries enough body text for
      extraction to run to completion rather than bailing out early, which
      would take the metadata path with it.</p>
    </article>
  </body>
</html>
"#;

#[test]
fn a_published_time_splitting_a_multi_byte_character_does_not_panic() {
    let result = extract(PUBLISHED_TIME_SPLITTING_A_CHARACTER, &Options::default())
        .expect("extraction should succeed");

    assert!(
        result.metadata.date.is_none(),
        "`1234567é9` is not a date, so no date should be parsed from it"
    );
    assert!(
        result.content_text.contains("eighth byte"),
        "the body text should still be extracted, got: {:?}",
        result.content_text
    );
}
