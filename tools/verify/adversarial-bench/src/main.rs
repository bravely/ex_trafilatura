//! The adversarial nesting benchmark: regenerates the depth-versus-wall-clock
//! figures [ADR-0001] §6 and the README's `## Resource safety` section publish.
//!
//! **It produces a number. It does not pass or fail.** Nothing here asserts a
//! threshold, and it is deliberately not in CI: wall clock on a shared runner is
//! noise, and a benchmark that fails spuriously gets muted within a month
//! ([ADR-0003] §6). It runs pre-release and at each re-vendor.
//!
//! It is kept rather than run once and discarded because its output is a
//! *shipped artifact*. ADR-0001 §6 puts a concrete second-figure in the README,
//! and ADR-0002 §5's re-vendor cadence moves the ground under it again every
//! time. A published number with no reproducible way to regenerate it decays
//! into folklore, and the person who has to update it after the next re-vendor
//! is a stranger reading `VENDOR.md`.
//!
//! [ADR-0001]: ../../../docs/adr/0001-resource-safety-posture.md
//! [ADR-0003]: ../../../docs/adr/0003-verification-posture.md

use std::fmt::Write as _;
use std::thread;
use std::time::{Duration, Instant};

use trafilatura::{ExtractResult, Options, TrafilaturaError};

/// One level of nesting. Six bytes, which is what makes the emitted input sizes
/// comparable with the published ones: ADR-0001 pairs depth 20,000 with ~120 KB
/// and depth 100,000 with ~600 KB.
const LEVEL: &str = "<div>\n";

/// The depths ADR-0001 and `crate-comparison.md` §1.3 tabulate, plus 50,000 —
/// the one row where the published table has a size but no `trafilatura`
/// timing, so filling it costs one measurement and closes a gap in the curve.
const DEFAULT_DEPTHS: &[usize] = &[5_000, 20_000, 50_000, 100_000];

/// Odd, so the median is a measured value rather than an average of two.
///
/// Five rather than three because three is not enough to survive a busy
/// machine: measured on a loaded laptop, depth 20,000 reported a 1.0 s median
/// over a 708 ms–1.5 s spread, and 604 ms over 601–611 ms once the machine was
/// idle. The `range` column exists so that contamination is visible rather than
/// silently averaged into the figure — a wide spread means re-run it, not
/// publish it.
const DEFAULT_REPEATS: usize = 5;

/// The stack the published figures were measured on (`crate-comparison.md`,
/// "Method and reproduction"). Fixed rather than exposed as a flag: a benchmark
/// whose stack size varies per run emits numbers that cannot be compared with
/// the ones it is meant to regenerate.
///
/// This is **not** the stack a NIF call gets. ERTS sizes dirty scheduler stacks
/// far smaller, so the figures below describe how expensive the crate is, not
/// how deep a document the BEAM survives.
const EXTRACTION_STACK_BYTES: usize = 8 * 1024 * 1024;

const USAGE: &str = "\
usage: cargo run --release -- [options]

  --depths 5000,20000,100000   nesting depths to measure (default 5000,20000,50000,100000)
  --repeats 5                  measurements per depth, median reported (default 5)
  --help                       this text

Emits a markdown block on stdout; progress goes to stderr.

Run it on an idle machine. A wide `range` column means the figure is
contaminated rather than interesting.";

/// Nesting-adversarial HTML: `depth` unclosed `<div>`s, one per line.
///
/// Unclosed is not sloppiness. `<div>` has no auto-close rule against another
/// `<div>`, so the parser nests them — the tag stream and the parsed tree agree
/// on the depth, at six bytes per level rather than eleven. `<p>` or `<li>`
/// would auto-close and flatten the tree to depth 1.
///
/// There is no text payload. The published figures were measured against bare
/// nested `<div>`s, and adding content would emit numbers that are not
/// comparable with the ones this exists to regenerate.
fn nesting_html(depth: usize) -> String {
    LEVEL.repeat(depth)
}

/// What one depth cost.
struct Measurement {
    depth: usize,
    bytes: usize,
    /// Ascending, so the median is `timings[len / 2]`.
    timings: Vec<Duration>,
    outcome: String,
}

impl Measurement {
    fn median(&self) -> Duration {
        self.timings[self.timings.len() / 2]
    }

    /// Fastest to slowest, so a reader can see whether the median is a figure or
    /// a coin toss. `43–53 ms` rather than `43 ms–53 ms`: the unit is written
    /// once when both ends share it, which is how the published table reads.
    ///
    /// A single repeat has no spread to report, and saying so is better than
    /// printing a range of one value as though it were evidence of stability.
    fn spread(&self) -> String {
        let (Some(&fastest), Some(&slowest)) = (self.timings.first(), self.timings.last()) else {
            return "—".to_string();
        };

        if fastest == slowest {
            return "—".to_string();
        }

        let (low, high) = (duration(fastest), duration(slowest));

        match (low.rsplit_once(' '), high.rsplit_once(' ')) {
            (Some((value, unit)), Some((_, same_unit))) if unit == same_unit => {
                format!("{value}–{high}")
            }
            _ => format!("{low}–{high}"),
        }
    }
}

fn measure(depth: usize, repeats: usize) -> Measurement {
    let html = nesting_html(depth);
    let mut timings = Vec::with_capacity(repeats);
    let mut outcome = String::new();

    for repeat in 1..=repeats {
        eprintln!("adversarial-bench: depth {depth}, run {repeat}/{repeats}");
        let (elapsed, this_outcome) = time_extraction(&html);
        timings.push(elapsed);
        outcome = this_outcome;
    }

    timings.sort();

    Measurement {
        depth,
        bytes: html.len(),
        timings,
        outcome,
    }
}

/// One extraction, on a thread sized to the published method.
///
/// The clock starts inside the thread so the spawn does not land in the figure.
/// A stack overflow here aborts the process rather than unwinding — that is the
/// hazard being measured, and it is more honest as a crash than as a caught
/// error.
fn time_extraction(html: &str) -> (Duration, String) {
    thread::scope(|scope| {
        thread::Builder::new()
            .stack_size(EXTRACTION_STACK_BYTES)
            .spawn_scoped(scope, || {
                let started = Instant::now();
                let result = trafilatura::extract(html, &Options::default());
                (started.elapsed(), outcome(&result))
            })
            .expect("could not spawn the extraction thread")
            .join()
            .expect("the extraction thread panicked")
    })
}

/// Whether the crate extracted anything, and if not why.
///
/// The named arms are short enough to sit in a table cell. `TrafilaturaError` is
/// `#[non_exhaustive]`, so the last arm is required rather than optional — a
/// variant a re-vendor introduces lands there and reports itself in full, which
/// is the outcome worth having: it cannot be silently mislabelled as a
/// neighbouring variant, and the reader sees a name they can go and look up.
fn outcome(result: &Result<ExtractResult, TrafilaturaError>) -> String {
    match result {
        Ok(_) => "`Ok`".to_string(),
        Err(TrafilaturaError::ParseError(_)) => "`Err ParseError`".to_string(),
        Err(TrafilaturaError::LanguageMismatch { .. }) => "`Err LanguageMismatch`".to_string(),
        Err(TrafilaturaError::InsufficientContent { .. }) => {
            "`Err InsufficientContent`".to_string()
        }
        Err(TrafilaturaError::MissingMetadata(_)) => "`Err MissingMetadata`".to_string(),
        Err(TrafilaturaError::DuplicateContent) => "`Err DuplicateContent`".to_string(),
        Err(TrafilaturaError::TreeTooLarge(_)) => "`Err TreeTooLarge`".to_string(),
        Err(TrafilaturaError::Io(_)) => "`Err Io`".to_string(),
        Err(unrecognised) => format!("`Err` — {unrecognised}"),
    }
}

struct Args {
    depths: Vec<usize>,
    repeats: usize,
}

fn parse_args(argv: impl Iterator<Item = String>) -> Result<Option<Args>, String> {
    let mut depths = DEFAULT_DEPTHS.to_vec();
    let mut repeats = DEFAULT_REPEATS;
    let mut argv = argv;

    while let Some(flag) = argv.next() {
        let mut value = || argv.next().ok_or(format!("{flag} needs a value"));

        match flag.as_str() {
            "--help" | "-h" => return Ok(None),
            "--depths" => {
                depths = value()?
                    .split(',')
                    .map(|depth| {
                        depth
                            .trim()
                            .parse()
                            .map_err(|_| format!("{depth:?} is not a depth"))
                    })
                    .collect::<Result<_, _>>()?;

                if depths.is_empty() {
                    return Err("--depths needs at least one depth".to_string());
                }
            }
            "--repeats" => {
                repeats = value()?
                    .parse()
                    .map_err(|_| "--repeats needs a whole number".to_string())?;

                if repeats == 0 {
                    return Err("--repeats needs to be at least 1".to_string());
                }
            }
            other => return Err(format!("unknown option {other:?}")),
        }
    }

    Ok(Some(Args { depths, repeats }))
}

fn main() {
    let args = match parse_args(std::env::args().skip(1)) {
        Ok(Some(args)) => args,
        Ok(None) => {
            println!("{USAGE}");
            return;
        }
        Err(problem) => {
            eprintln!("adversarial-bench: {problem}\n\n{USAGE}");
            std::process::exit(2);
        }
    };

    let measurements: Vec<_> = args
        .depths
        .iter()
        .map(|&depth| measure(depth, args.repeats))
        .collect();

    eprintln!("adversarial-bench: done\n");
    print!("{}", report(&measurements, args.repeats));
}

fn report(measurements: &[Measurement], repeats: usize) -> String {
    let mut out = String::new();

    out.push_str("# Adversarial nesting benchmark\n\n");

    out.push_str("| | |\n|---|---|\n");
    let row = |out: &mut String, key: &str, value: String| {
        writeln!(out, "| {key} | {value} |").expect("writing to a String cannot fail");
    };
    row(
        &mut out,
        "Date",
        chrono::Local::now().format("%Y-%m-%d").to_string(),
    );
    row(
        &mut out,
        "Extractor",
        format!(
            "`trafilatura {}`, vendored at `native/ex_trafilatura/vendor/trafilatura`",
            env!("TRAFILATURA_VERSION")
        ),
    );
    row(
        &mut out,
        "Toolchain",
        format!("`{}`, release with debug symbols", env!("RUSTC_VERSION")),
    );
    row(
        &mut out,
        "Host",
        format!("`{}` / `{}`", std::env::consts::ARCH, std::env::consts::OS),
    );
    row(
        &mut out,
        "Stack",
        format!("{} MiB per extraction thread", EXTRACTION_STACK_BYTES >> 20),
    );
    row(
        &mut out,
        "Input",
        "unclosed `<div>`, one per line — 6 bytes per level of depth".to_string(),
    );
    row(&mut out, "Options", "`Options::default()`".to_string());
    row(
        &mut out,
        "Repeats",
        format!("{repeats} per depth, median reported"),
    );

    out.push_str("\n| depth | input size | wall clock | range | outcome |\n");
    out.push_str("|---|---|---|---|---|\n");

    for measurement in measurements {
        writeln!(
            &mut out,
            "| {} | {} | **{}** | {} | {} |",
            thousands(measurement.depth),
            kilobytes(measurement.bytes),
            duration(measurement.median()),
            measurement.spread(),
            measurement.outcome,
        )
        .expect("writing to a String cannot fail");
    }

    out.push_str(
        "\n\
        The outcome column is not a failure. The crate's own depth guard declines\n\
        documents nested this far, and the wall clock is what it costs to reach that\n\
        conclusion — the time is spent whether or not anything comes back.\n\
        \n\
        **This benchmark produces the figure; it does not pass or fail.** If the numbers\n\
        above differ from the ones ADR-0001 §6 and the README's `## Resource safety`\n\
        section publish, amend both **in place** and ship. ADR-0001's posture explicitly\n\
        survives the numbers moving either way, so only the figure changes (ADR-0003 §6).\n\
        It becomes a decision point only if the tarpit has got dramatically worse, in a\n\
        way that reopens ADR-0001 §4 or §5.\n",
    );

    out
}

/// `~120 KB`, in the 1000-based units the published table uses.
fn kilobytes(bytes: usize) -> String {
    format!("~{} KB", thousands(bytes / 1000))
}

/// `871 ms` under a second, `20.7 s` over it — the published table's own two
/// scales, so a regenerated row can be compared with the one it replaces
/// without unit arithmetic.
fn duration(elapsed: Duration) -> String {
    let millis = elapsed.as_secs_f64() * 1000.0;

    if millis < 1000.0 {
        format!("{millis:.0} ms")
    } else {
        format!("{:.1} s", millis / 1000.0)
    }
}

fn thousands(number: usize) -> String {
    let digits = number.to_string();
    let mut out = String::with_capacity(digits.len() + digits.len() / 3);

    for (position, digit) in digits.chars().enumerate() {
        if position > 0 && (digits.len() - position) % 3 == 0 {
            out.push(',');
        }
        out.push(digit);
    }

    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use scraper::{Html, Selector};

    #[test]
    fn a_depth_of_zero_is_an_empty_document() {
        assert_eq!(nesting_html(0), "");
    }

    #[test]
    fn each_level_is_one_unclosed_div_on_its_own_line() {
        assert_eq!(nesting_html(3), "<div>\n<div>\n<div>\n");
    }

    /// The published figures pair depth 20,000 with ~120 KB and depth 100,000
    /// with ~600 KB — exactly six bytes per level, the width of `LEVEL`. A
    /// generator that drifted off that ratio would emit numbers that look like
    /// ADR-0001's and are not comparable to them.
    #[test]
    fn the_published_depths_reproduce_the_published_input_sizes() {
        assert_eq!(nesting_html(20_000).len(), 120_000);
        assert_eq!(nesting_html(100_000).len(), 600_000);
    }

    /// The whole benchmark rests on unclosed `<div>`s nesting rather than being
    /// auto-closed: `depth` is a claim about the parsed tree, not about the tag
    /// count in the byte stream. `<div>` has no auto-close rule against another
    /// `<div>` — unlike `<p>` or `<li>`, which would flatten this to depth 1.
    #[test]
    fn the_parsed_tree_nests_as_deep_as_the_requested_depth() {
        let depth = 50;
        let document = Html::parse_document(&nesting_html(depth));
        let div = Selector::parse("div").expect("`div` is a valid selector");

        let deepest = document
            .select(&div)
            .map(|element| {
                1 + element
                    .ancestors()
                    .filter_map(scraper::ElementRef::wrap)
                    .filter(|ancestor| ancestor.value().name() == "div")
                    .count()
            })
            .max()
            .expect("the document contains at least one div");

        assert_eq!(deepest, depth);
    }

    #[test]
    fn the_published_sizes_are_formatted_the_way_the_published_table_writes_them() {
        assert_eq!(kilobytes(120_000), "~120 KB");
        assert_eq!(kilobytes(600_000), "~600 KB");
        assert_eq!(kilobytes(30_000), "~30 KB");
    }

    #[test]
    fn durations_switch_to_seconds_at_one_second() {
        assert_eq!(duration(Duration::from_millis(58)), "58 ms");
        assert_eq!(duration(Duration::from_millis(871)), "871 ms");
        assert_eq!(duration(Duration::from_millis(999)), "999 ms");
        assert_eq!(duration(Duration::from_millis(20_700)), "20.7 s");
    }

    #[test]
    fn depths_are_written_with_thousands_separators() {
        assert_eq!(thousands(5_000), "5,000");
        assert_eq!(thousands(100_000), "100,000");
        assert_eq!(thousands(600), "600");
    }

    #[test]
    fn the_median_is_the_middle_measurement_not_the_last_one() {
        let measurement = Measurement {
            depth: 20_000,
            bytes: 120_000,
            timings: vec![
                Duration::from_millis(800),
                Duration::from_millis(871),
                Duration::from_millis(1_400),
            ],
            outcome: "`Ok`".to_string(),
        };

        assert_eq!(measurement.median(), Duration::from_millis(871));
        assert_eq!(measurement.spread(), "800 ms–1.4 s");
    }

    #[test]
    fn a_shared_unit_is_written_once_across_the_spread() {
        let measurement = Measurement {
            depth: 5_000,
            bytes: 30_000,
            timings: vec![Duration::from_millis(43), Duration::from_millis(53)],
            outcome: "`Ok`".to_string(),
        };

        assert_eq!(measurement.spread(), "43–53 ms");
    }

    /// One repeat is a measurement, not a range. Printing `53–53 ms` would dress
    /// a single sample up as evidence that the figure is stable.
    #[test]
    fn a_single_repeat_reports_no_spread() {
        let measurement = Measurement {
            depth: 5_000,
            bytes: 30_000,
            timings: vec![Duration::from_millis(53)],
            outcome: "`Ok`".to_string(),
        };

        assert_eq!(measurement.spread(), "—");
    }

    /// The variant the depth guard actually produces gets a short label; the
    /// `#[non_exhaustive]` fallback is what a re-vendor's new variant would hit.
    #[test]
    fn known_outcomes_get_a_table_sized_label() {
        let insufficient = Err(TrafilaturaError::InsufficientContent {
            text_len: 0,
            comment_len: 0,
            min_output_size: 250,
            min_output_comment_size: 1,
        });

        assert_eq!(outcome(&insufficient), "`Err InsufficientContent`");
        assert_eq!(
            outcome(&Err(TrafilaturaError::DuplicateContent)),
            "`Err DuplicateContent`"
        );
    }

    #[test]
    fn the_defaults_stand_in_for_omitted_flags() {
        let args = parse_args(std::iter::empty())
            .expect("no arguments is valid")
            .expect("no arguments is not --help");

        assert_eq!(args.depths, DEFAULT_DEPTHS);
        assert_eq!(args.repeats, DEFAULT_REPEATS);
    }

    #[test]
    fn depths_and_repeats_are_overridable() {
        let args = parse_args(
            ["--depths", "100,2000", "--repeats", "1"]
                .iter()
                .map(|arg| arg.to_string()),
        )
        .expect("valid flags")
        .expect("not --help");

        assert_eq!(args.depths, vec![100, 2_000]);
        assert_eq!(args.repeats, 1);
    }

    #[test]
    fn a_flag_that_cannot_produce_a_measurement_is_rejected_rather_than_rounded_up() {
        assert!(parse_args(["--repeats", "0"].iter().map(|a| a.to_string())).is_err());
        assert!(parse_args(["--depths", ""].iter().map(|a| a.to_string())).is_err());
        assert!(parse_args(["--depths", "deep"].iter().map(|a| a.to_string())).is_err());
        assert!(parse_args(["--repeats"].iter().map(|a| a.to_string())).is_err());
        assert!(parse_args(["--warmup", "2"].iter().map(|a| a.to_string())).is_err());
    }
}
