#!/usr/bin/env sh
#
# ADR-0004 §10's per-artifact smoke test, from the project root:
#
#     tools/verify/artifact-smoke.sh artifact/libex_trafilatura-v0.1.0-nif-2.15-….tar.gz
#
# Loads one built artifact through the same path a user's `mix deps.get` takes
# and calls `crate_version/0` on it. The reasoning, and what each half asserts,
# is in tools/verify/artifact_smoke.exs.
#
# POSIX sh rather than bash: the two musl legs run in an Alpine container, which
# has no bash. Everything below is portable to the git-bash the Windows leg uses.
set -eu

if [ $# -ne 1 ]; then
  echo "usage: $0 <artifact.tar.gz>" >&2
  exit 2
fi

# Passed through the environment rather than interpolated into `-e`, so a path
# is a path and not a fragment of Elixir source.
ARTIFACT=$1
export ARTIFACT

# Relative, deliberately. The Windows leg runs this under git-bash, where `$PWD`
# is `/d/a/…` — a path the Elixir on the other side of these commands cannot
# open. Every command here runs from the project root, so relative is both
# correct and portable.
RUSTLER_PRECOMPILED_GLOBAL_CACHE_PATH=_build/artifact-smoke
export RUSTLER_PRECOMPILED_GLOBAL_CACHE_PATH

# A source build would satisfy every assertion downstream while proving nothing
# about the artifact, so neither escape hatch may be inherited from whoever
# called this. `verify!/1` checks this again from inside, since these two are
# read at *compile* time and a mismatch there is silent.
unset EX_TRAFILATURA_BUILD
unset RUSTLER_PRECOMPILED_FORCE_BUILD_ALL

# prod rather than the default dev: `usage_rules` is a dev-only dependency
# declaring `elixir: "~> 1.18"`, and compiling it here would put an unrelated
# version constraint on a job whose subject is a binary.
MIX_ENV=prod
export MIX_ENV

# `stage!/1` writes a one-entry checksum file under the same name ADR-0004 §7
# commits, so leaving it behind puts a file in the working tree that would break
# every downstream `mix deps.get` if it were ever committed by accident. Restored
# from git if it is tracked, removed if it is not — either way the tree ends
# where it started. Set before the file is written so a failure cleans up too.
checksum_file="checksum-Elixir.ExTrafilatura.Native.exs"
trap 'git checkout -- "$checksum_file" 2>/dev/null || rm -f "$checksum_file"' EXIT

# Put the artifact where the compile will find it, and pin its bytes.
elixir -r tools/verify/artifact_smoke.exs \
  -e 'ArtifactSmoke.stage!(System.fetch_env!("ARTIFACT"))'

mix deps.get

# `--force` because the whole point is to re-run the macro that resolves the
# NIF. A `_build` left over from an earlier run would otherwise let this pass
# without the artifact being opened at all.
mix compile --force

mix run -r tools/verify/artifact_smoke.exs \
  -e 'ArtifactSmoke.verify!(System.fetch_env!("ARTIFACT"))'
