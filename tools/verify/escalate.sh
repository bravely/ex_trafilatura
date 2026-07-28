#!/usr/bin/env bash
#
# Score the patched crate with upstream's own comparison test.
#
# This is the escalation drift.sh names, and it only runs when drift.sh reports
# a non-empty diff: a diff says whether output moved, not whether the move is an
# improvement, and this is what judges that (ADR-0003 §7).
#
# It clones upstream at the tag our vendored copy came from, re-applies what the
# vendored copy carries, and runs `tests/comparison_test.rs` unmodified. Nothing
# here scores anything — the scoring is upstream's, which is the point.

set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
vendor_dir="$repo_root/native/ex_trafilatura/vendor"
patch_dir="$vendor_dir/patches"
vendor_md="$vendor_dir/trafilatura/VENDOR.md"

corpus_repo="https://github.com/nchapman/trafilatura-rs.git"
clone_dir="$repo_root/tools/verify/.corpus/escalation"

# ADR-0003 §7. Below this, ADR-0002 §1 — taking patch 0001 at all — reopens.
# It is a stated number rather than a judgment call precisely so that the person
# reading it on release day argues with a prior decision and not their deadline.
tripwire=0.903

# The row that matches our call path. `Options::default()` is
# `enable_fallback: false` and `focus: Balanced`, and #11 §6 defines `extract/1`
# to equal `trafilatura::extract(html, &Options::default())` — so this is the
# configuration our callers get. The other three rows are reported but do not
# gate: scoring a configuration we do not ship would be measuring someone else.
gated_row="Balanced (no fallback)"

fail() {
  echo "escalate: $*" >&2
  exit 1
}

for tool in cargo git awk sed; do
  command -v "$tool" >/dev/null 2>&1 ||
    fail "$tool is not installed; that is a missing tool, not a score"
done

# ---------------------------------------------------------------------------
# The clone, at the release the vendored copy came from
# ---------------------------------------------------------------------------

# VENDOR.md is the one place the vendored version is written down;
# vendor-integrity.sh reads the same row, so a re-vendor moves both.
crate_version=$(sed -n "s/^| Upstream version | \`\{0,1\}\([0-9][0-9.]*\)\`\{0,1\} |.*\$/\1/p" "$vendor_md")
[ -n "$crate_version" ] || fail "no 'Upstream version' row found in $vendor_md"
tag="v$crate_version"

# The corpus and the scorer ship with the repository, not the tarball, so this
# has to be a checkout. Shallow and tag-pinned: we want one commit's worth.
rm -rf "$clone_dir"
mkdir -p "$(dirname "$clone_dir")"
echo "escalate: cloning $corpus_repo at $tag"
git clone --depth 1 --branch "$tag" --quiet "$corpus_repo" "$clone_dir" ||
  fail "could not clone $corpus_repo at $tag — does that tag exist?"

# ---------------------------------------------------------------------------
# What the vendored copy carries, re-applied to the checkout
# ---------------------------------------------------------------------------

# Named rather than globbed, because each is re-applied a different way and a
# patch this script has not been taught about would otherwise be skipped in
# silence — scoring a crate that is not the one we ship.
manifest_patch=0001-bump-deps-upstream-pr-2.patch
source_patch=0002-fix-char-boundary-panic.patch

# nullglob so an empty patches/ is a named failure rather than an unglobbed
# literal or a bare `set -e` abort, the same way vendor-integrity.sh handles it.
shopt -s nullglob
patches=("$patch_dir"/*.patch)
shopt -u nullglob
[ ${#patches[@]} -gt 0 ] || fail "no patches found in $patch_dir"

found=$(for patch in "${patches[@]}"; do basename "$patch"; done | sort | tr '\n' ' ')
expected="$manifest_patch $source_patch "
[ "$found" = "$expected" ] || fail "the patch set has changed
  expected: $expected
  found:    $found
Each patch is re-applied here by name. Teach this script the new one before
scoring, or the score describes a crate we do not ship."

# 0002 touches src/ only, so it applies to the repository unchanged.
echo "escalate: applying $source_patch"
git -C "$clone_dir" apply "$patch_dir/$source_patch" ||
  fail "$source_patch does not apply to $tag"

# 0001 cannot: it edits the *normalised* manifest cargo generates when it
# packages the crate, which is not the hand-written Cargo.toml in the
# repository. Its substance is four dependency bumps — the version marker and
# the Apache-2.0 notice it also carries do not affect a score — so those four
# are re-applied here against their exact current values.
bump() {
  local name=$1 from=$2 to=$3 manifest="$clone_dir/Cargo.toml"
  grep -q "^$name = \"$from\"\$" "$manifest" ||
    fail "$manifest does not require $name $from, so $manifest_patch's bump to $to
cannot be reproduced. Upstream's manifest has moved; re-read $manifest_patch."
  sed "s|^$name = \"$from\"\$|$name = \"$to\"|" "$manifest" > "$manifest.bumped"
  mv "$manifest.bumped" "$manifest"
  echo "escalate: $name $from -> $to"
}

bump ego-tree 0.10 0.11
bump html5ever 0.36 0.39
bump scraper 0.25 0.26
bump tendril 0.4 0.5

# ---------------------------------------------------------------------------
# Upstream's scorer, unmodified
# ---------------------------------------------------------------------------

# The clone carries upstream's own Cargo.lock, so everything except the four
# edges bumped above stays pinned to what upstream resolved at this tag. The
# scored build is a reconstruction of the vendored crate rather than the
# vendored crate itself — close enough to judge a score by, and the guards above
# are what keep "close enough" honest.
echo "escalate: running upstream's tests/comparison_test.rs"
log="$clone_dir/comparison.log"
(cd "$clone_dir" && cargo test --release --test comparison_test -- --nocapture) \
  2>&1 | tee "$log" || fail "upstream's comparison test did not run to completion"

echo
grep -E 'f-score=' "$log" || fail "the comparison test printed no scores"

fscore=$(sed -n "s/^$gated_row: .*f-score=\([0-9.]*\) .*\$/\1/p" "$log" | head -1)
[ -n "$fscore" ] || fail "no '$gated_row' row in the comparison output"

echo
if awk -v f="$fscore" -v t="$tripwire" 'BEGIN { exit !(f < t) }'; then
  cat >&2 <<VERDICT
escalate: $gated_row f-score=$fscore is BELOW the $tripwire tripwire.

This reopens ADR-0002 §1, where taking patch 0001 at all was decided. The
alternatives named there — drop the bump and carry the ego-tree panic, or patch
dom::tree::remove directly — are ADR-scale. Do not ship past this.
VERDICT
  exit 1
fi

echo "escalate: $gated_row f-score=$fscore, at or above the $tripwire tripwire."
echo "escalate: ship, recording the f-score and the affected page count in"
echo "escalate: $(dirname "${vendor_md#"$repo_root"/}")/VENDOR.md (ADR-0003 §9)."
