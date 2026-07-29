//! Reads the vendored crate's version marker out of its `Cargo.toml` and hands
//! it to the compiler as `TRAFILATURA_VERSION`.
//!
//! `crate_version/0` exists so a user can establish what extractor they actually
//! hold (ADR-0004 §1), which makes a hardcoded copy of the marker a liability:
//! a re-vendor that bumps `+extrafilatura.N` and forgets the constant leaves the
//! function reporting a version nobody is running. `[patch.crates-io]` points at
//! this exact directory, so this file *is* the version in use.

use std::fs;

const VENDORED_MANIFEST: &str = "vendor/trafilatura/Cargo.toml";

fn main() {
    println!("cargo:rerun-if-changed={VENDORED_MANIFEST}");

    let manifest = fs::read_to_string(VENDORED_MANIFEST).unwrap_or_else(|e| {
        panic!("cannot read {VENDORED_MANIFEST} (is the vendored crate present?): {e}")
    });

    let version = package_version(&manifest)
        .unwrap_or_else(|| panic!("no [package] version in {VENDORED_MANIFEST}"));

    println!("cargo:rustc-env=TRAFILATURA_VERSION={version}");
}

/// The `version` key of the `[package]` table, ignoring the `version` keys that
/// every `[dependencies]` entry below it also carries.
///
/// A line scan is enough because the file it reads is byte-pinned:
/// `tools/verify/vendor-integrity.sh` requires the vendored tree to reproduce
/// exactly from the pristine tarball plus our patches, so it cannot be
/// reformatted underneath this without that check failing first. And a layout
/// this does not expect is a loud build failure, not a wrong version — the
/// caller panics on `None`.
fn package_version(manifest: &str) -> Option<String> {
    manifest
        .lines()
        .map(str::trim)
        .skip_while(|line| *line != "[package]")
        .skip(1)
        .take_while(|line| !line.starts_with('['))
        .find_map(|line| line.strip_prefix("version = "))
        .map(|value| value.trim_matches('"').to_string())
}
