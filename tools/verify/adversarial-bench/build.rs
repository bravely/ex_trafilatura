//! Stamps the emitted block with what produced it: the vendored crate's version
//! marker and the compiler that built this binary.
//!
//! The point of keeping this benchmark rather than running it once is that the
//! number it emits is a *shipped artifact* (ADR-0003 §6). A figure with no
//! record of which extractor and which toolchain produced it is the folklore
//! that motivates the tool, one step removed — so the provenance is compiled in
//! rather than left for the operator to remember to paste.
//!
//! `native/ex_trafilatura/build.rs` reads the same marker the same way, for the
//! same reason. The duplication is deliberate: these are two independent tools,
//! and a shared crate to hold eight lines would couple the benchmark to the NIF
//! it does not otherwise need.

use std::fs;
use std::process::Command;

const VENDORED_MANIFEST: &str = "../../../native/ex_trafilatura/vendor/trafilatura/Cargo.toml";

fn main() {
    println!("cargo:rerun-if-changed={VENDORED_MANIFEST}");

    let manifest = fs::read_to_string(VENDORED_MANIFEST).unwrap_or_else(|e| {
        panic!("cannot read {VENDORED_MANIFEST} (is the vendored crate present?): {e}")
    });

    let version = package_version(&manifest)
        .unwrap_or_else(|| panic!("no [package] version in {VENDORED_MANIFEST}"));

    println!("cargo:rustc-env=TRAFILATURA_VERSION={version}");
    println!("cargo:rustc-env=RUSTC_VERSION={}", rustc_version());
}

/// The `version` key of the `[package]` table, ignoring the `version` keys that
/// every `[dependencies]` entry below it also carries.
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

/// The compiler cargo is building us with, not whatever `rustc` is first on the
/// operator's `PATH` — `RUSTC` is what a `rustup` toolchain override resolves
/// to, and getting this wrong would misreport the run.
fn rustc_version() -> String {
    let rustc = std::env::var("RUSTC").unwrap_or_else(|_| "rustc".to_string());

    Command::new(rustc)
        .arg("--version")
        .output()
        .ok()
        .filter(|output| output.status.success())
        .and_then(|output| String::from_utf8(output.stdout).ok())
        .map(|version| version.trim().to_string())
        .unwrap_or_else(|| "unknown".to_string())
}
