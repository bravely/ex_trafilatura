#!/usr/bin/env bash
#
# Did the patched crate's output move? Runs the same harness twice — once linked
# against stock crates.io 0.3.0, once against the vendored copy — over the same
# real-page corpus, and diffs the two dumps byte for byte.
#
# Pre-release and at each re-vendor. It gates the release, with an escalation:
# a non-empty diff is not automatically a stop, it is a reason to score. See
# tools/verify/README.md.

set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
drift_dir="$repo_root/tools/verify/drift"
vendor_dir="$repo_root/native/ex_trafilatura/vendor/trafilatura"

# Both on demand, both gitignored. The corpus is upstream's and never enters
# this repository or the Hex package (ADR-0003 §2); the dumps are a working
# artifact of one run.
corpus_root="$repo_root/tools/verify/.corpus/trafilatura-rs"
out_root="$repo_root/tools/verify/.drift"

corpus_repo="https://github.com/nchapman/trafilatura-rs.git"

refresh=0
for arg in "$@"; do
  case "$arg" in
    --refresh) refresh=1 ;;
    *)
      echo "usage: tools/verify/drift.sh [--refresh]" >&2
      exit 2
      ;;
  esac
done

fail() {
  echo "drift: $*" >&2
  exit 1
}

for tool in cargo git diff; do
  command -v "$tool" >/dev/null 2>&1 ||
    fail "$tool is not installed; that is a missing tool, not a drift result"
done

# ---------------------------------------------------------------------------
# The corpus
# ---------------------------------------------------------------------------

if [ "$refresh" -eq 1 ]; then
  rm -rf "$corpus_root"
fi

if [ ! -d "$corpus_root/.git" ]; then
  echo "drift: shallow-cloning $corpus_repo"
  rm -rf "$corpus_root"
  mkdir -p "$(dirname "$corpus_root")"
  git clone --depth 1 --quiet "$corpus_repo" "$corpus_root" ||
    fail "could not clone the corpus"
else
  echo "drift: reusing the corpus already at $corpus_root (--refresh to re-clone)"
fi

corpus_sha=$(git -C "$corpus_root" rev-parse HEAD)
corpus_files="$corpus_root/test-files"
[ -d "$corpus_files" ] || fail "the clone has no test-files/ — is $corpus_repo still the right repository?"

# Without this the run is not reproducible if upstream moves (ADR-0003 §2).
echo "drift: corpus at $corpus_sha"

# ---------------------------------------------------------------------------
# The two builds
# ---------------------------------------------------------------------------

# What each side must and must not link. This is the check that matters most:
# if the patch entry silently stopped engaging, both sides would build stock,
# the diff would be empty, and an empty diff is exactly what we ship on.
assert_links() {
  local side=$1 expectation=$2 resolved
  resolved=$(cargo tree \
    --manifest-path "$drift_dir/$side/Cargo.toml" \
    --package trafilatura --depth 0 --edges normal --quiet | tail -1)

  case "$expectation" in
    vendored)
      [[ "$resolved" == *"$vendor_dir"* ]] ||
        fail "the patched side did not link the vendored crate; cargo resolved: $resolved
[patch.crates-io] is not engaging, so both sides would be stock and the diff
would be empty for the wrong reason."
      ;;
    registry)
      [[ "$resolved" != *"$vendor_dir"* && "$resolved" != *"+extrafilatura"* ]] ||
        fail "the stock side linked the vendored crate; cargo resolved: $resolved"
      ;;
    # A renamed or misspelled expectation must not fall through asserting
    # nothing. This function exists to prevent a false clean; a silent no-op
    # here would be one.
    *)
      fail "assert_links: unknown expectation '$expectation'"
      ;;
  esac

  printf '%s\n' "$resolved"
}

for side in stock patched; do
  echo "drift: building $side"
  cargo build --release --quiet --manifest-path "$drift_dir/$side/Cargo.toml" ||
    fail "the $side harness did not build"
done

stock_crate=$(assert_links stock registry)
patched_crate=$(assert_links patched vendored)
echo "drift: stock links   $stock_crate"
echo "drift: patched links $patched_crate"

# ---------------------------------------------------------------------------
# The run
# ---------------------------------------------------------------------------

rm -rf "$out_root"
mkdir -p "$out_root"

# Two plain variables rather than an associative array: macOS still ships bash
# 3.2, and this is a script a maintainer runs on their own machine.
dump_side() {
  local side=$1
  echo "drift: dumping $side" >&2
  "$drift_dir/$side/target/release/drift-dump" "$corpus_files" "$out_root/$side" ||
    fail "the $side harness did not finish"
}

stock_tally=$(dump_side stock)
echo "drift: stock — $stock_tally"
patched_tally=$(dump_side patched)
echo "drift: patched — $patched_tally"

pages=$(find "$out_root/stock" -type f -name '*.dump' | wc -l | tr -d ' ')

# ---------------------------------------------------------------------------
# The diff
# ---------------------------------------------------------------------------

diff_file="$out_root/drift.diff"

# The verdict comes from diff's own exit status — 0 same, 1 different, 2 or more
# trouble — and not from counting lines in its output. Counting cannot tell "no
# pages differ" from "diff never ran", and those must not agree: the first ships
# and the second is a broken instrument.
diff_status=0
diff -ru "$out_root/stock" "$out_root/patched" > "$diff_file" || diff_status=$?

if [ "$diff_status" -ge 2 ]; then
  fail "diff could not compare the two dumps (exit $diff_status)
That is a broken instrument, not a drift result. Nothing about the vendored
crate has been established by this run."
fi

if [ "$diff_status" -eq 0 ]; then
  verdict="empty — byte-identical across $pages pages"
  fscore="not triggered"
else
  # Entries, not pages: diff reports a whole missing directory as one "Only in"
  # line, so this is a lower bound on how much moved. The diff file is the
  # record; this number is there to say how much of it to expect.
  entries=$(grep -c '^Only in \|^diff -ru ' "$diff_file" || true)
  verdict="NON-EMPTY — $entries differences over $pages pages, see ${diff_file#"$repo_root"/}"
  fscore="escalation required"
fi

# ---------------------------------------------------------------------------
# The record
# ---------------------------------------------------------------------------

result_file="$out_root/RESULT.md"
cat > "$result_file" <<RECORD
| Date | Corpus SHA | Pages | Diff | F-score |
|---|---|---|---|---|
| $(date -u +%F) | \`$corpus_sha\` | $pages | $verdict | $fscore |

- stock: $stock_tally, linking \`$stock_crate\`
- patched: $patched_tally, linking \`$patched_crate\`
RECORD

echo
echo "drift: $verdict"
echo
echo "Paste into the Verification section of"
echo "native/ex_trafilatura/vendor/trafilatura/VENDOR.md (ADR-0003 §9):"
echo
cat "$result_file"

if [ "$diff_status" -ne 0 ]; then
  cat >&2 <<'ESCALATION'

The diff is not empty, which is not by itself a stop. Escalate: score the
patched crate with upstream's own tests/comparison_test.rs, which is what
tools/verify/escalate.sh runs. F-score >= 0.903 ships with the delta recorded;
below 0.903 reopens ADR-0002 §1.

    tools/verify/escalate.sh
ESCALATION
  exit 1
fi
