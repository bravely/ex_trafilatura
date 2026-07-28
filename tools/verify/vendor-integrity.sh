#!/usr/bin/env bash
#
# Prove that native/ex_trafilatura/vendor/trafilatura is exactly the published
# crates.io tarball plus the patches in vendor/patches/, and nothing else.
#
# Fetch the tarball, check it against the sha256 in VENDOR.md, apply the patches
# in order, drop what we do not vendor, and diff. Empty diff or fail.
#
# tools/verify/README.md says what this is for and when it runs.

set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
vendor_dir="$repo_root/native/ex_trafilatura/vendor"
crate_dir="$vendor_dir/trafilatura"
patch_dir="$vendor_dir/patches"
vendor_md="$crate_dir/VENDOR.md"

crate_name=trafilatura

# What we vendor, as VENDOR.md describes it. Everything else the tarball carries
# is dropped before the diff.
kept=(Cargo.toml LICENSE src)

# Ours, not upstream's, so it is not in the rebuilt tree and is not compared.
not_upstream=VENDOR.md

fail() {
  echo "vendor-integrity: $*" >&2
  exit 1
}

for tool in curl tar git diff sed; do
  command -v "$tool" >/dev/null 2>&1 ||
    fail "$tool is not installed; that is a missing tool, not a provenance failure"
done

# The version and the digest live in VENDOR.md so there is exactly one place to
# read them from and one place to change them when we re-vendor.
read_vendor_md() {
  local value
  value=$(sed -n "s/^| $1 | \`\{0,1\}\($2\)\`\{0,1\} |.*\$/\1/p" "$vendor_md")
  [ -n "$value" ] || fail "no '$1' row found in $vendor_md"
  printf '%s\n' "$value"
}

crate_version=$(read_vendor_md 'Upstream version' '[0-9][0-9.]*')
expected_sha=$(read_vendor_md 'sha256' '[0-9a-f]\{64\}')
tarball_url="https://static.crates.io/crates/$crate_name/$crate_name-$crate_version.crate"

# -P because git apply refuses to touch a path reached through a symlink, and on
# macOS $TMPDIR is one.
work_dir=$(cd "$(mktemp -d)" && pwd -P)
trap 'rm -rf "$work_dir"' EXIT

tarball="$work_dir/$crate_name-$crate_version.crate"
echo "vendor-integrity: fetching $tarball_url"
curl --fail --silent --show-error --location --retry 3 --output "$tarball" "$tarball_url" ||
  fail "could not fetch the tarball"

if command -v sha256sum >/dev/null 2>&1; then
  actual_sha=$(sha256sum "$tarball" | cut -d' ' -f1)
else
  actual_sha=$(shasum -a 256 "$tarball" | cut -d' ' -f1)
fi

if [ "$actual_sha" != "$expected_sha" ]; then
  fail "sha256 mismatch
  expected $expected_sha (VENDOR.md)
  got      $actual_sha ($tarball_url)
The published tarball is immutable, so this means VENDOR.md is wrong or the
registry served something else. Neither is a build problem to work around."
fi
echo "vendor-integrity: sha256 matches VENDOR.md"

tar -xzf "$tarball" -C "$work_dir"
rebuilt="$work_dir/$crate_name-$crate_version"
[ -d "$rebuilt" ] || fail "the tarball did not contain $crate_name-$crate_version/"

shopt -s nullglob
patches=("$patch_dir"/*.patch)
shopt -u nullglob
[ ${#patches[@]} -gt 0 ] || fail "no patches found in $patch_dir"

for patch in "${patches[@]}"; do
  echo "vendor-integrity: applying $(basename "$patch")"
  # git apply rather than patch(1): it refuses fuzz, so a patch that no longer
  # describes the file it claims to is a failure rather than a near miss. The
  # two -c overrides keep the rebuilt tree byte-identical to the tarball on a
  # machine whose git is configured to rewrite line endings.
  git -c core.autocrlf=false -c core.eol=lf \
    apply --directory="$rebuilt" --unsafe-paths -p1 "$patch" ||
    fail "$(basename "$patch") does not apply to the pristine tarball"
done

# Drop everything we do not vendor, so the diff below is symmetric: it reports
# files missing from the vendored tree *and* files that should not be in it.
keep_args=()
for name in "${kept[@]}"; do
  keep_args+=(! -name "$name")
done
find "$rebuilt" -mindepth 1 -maxdepth 1 "${keep_args[@]}" -exec rm -rf {} +

if diff -ru --exclude="$not_upstream" "$crate_dir" "$rebuilt"; then
  echo "vendor-integrity: $crate_dir is the tarball plus ${#patches[@]} patches, exactly"
else
  fail "the vendored tree is not the tarball plus the patches
Lines starting '-' are in the vendored tree, '+' are what the patches produce.
Fix whichever is wrong — usually this means an edit landed in the vendored
source without being written back to its .patch file."
fi
