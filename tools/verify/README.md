# Verification tooling

What each tool is, and exactly when it runs. Nothing here ships: this directory
is excluded from the Hex package's `:files`.
[ADR-0003](../../docs/adr/0003-verification-posture.md) is the posture these
implement.

| Tool | What it answers | When it runs | Gates? |
|---|---|---|---|
| `vendor-integrity.sh` | Is `native/ex_trafilatura/vendor/trafilatura/` exactly the published tarball plus our patches? | every push | yes |

Two more tools belong here and are not built yet:

- **The differential drift harness**
  ([#33](https://github.com/bravely/ex_trafilatura/issues/33)) — "did the patched
  crate's output move?", byte for byte across the real-page corpus. Pre-release
  and at each re-vendor; **gates the release**, with an escalation to scoring if
  the diff is non-empty.
- **The adversarial nesting benchmark**
  ([#34](https://github.com/bravely/ex_trafilatura/issues/34)) — regenerates the
  depth-versus-wall-clock figure the README publishes. Pre-release and at each
  re-vendor, never in CI, and it produces a number rather than passing or
  failing.

## `vendor-integrity.sh`

```sh
tools/verify/vendor-integrity.sh
```

Fetches the crates.io tarball, checks it against the sha256 in
[`VENDOR.md`](../../native/ex_trafilatura/vendor/trafilatura/VENDOR.md), applies
`vendor/patches/*.patch` in order, drops what we do not vendor, and diffs the
result against the vendored tree. Empty diff or fail. Needs network and `git`.

It runs on **every push**, not behind a `vendor/**` path filter: it takes
seconds, and a path filter is wrong the first time someone moves a directory. A
provenance check you have to remember to run is a provenance claim, not a check.

The specific rot it catches: someone fixes something by editing
`vendor/trafilatura/src/` directly without updating the `.patch` file.
Everything builds, tests pass, `VENDOR.md` still looks right — and it surfaces
months later at the exact moment we re-vendor onto a new upstream release,
which is when the patch files are the mechanism.

Its accepted cost is that it is the only CI step pinned to one specific fetched
artifact, so a yanked or relocated tarball breaks the build for a non-reason.
That is the same registry `cargo` is already hitting, and a yanked `trafilatura`
0.3.0 is news we would want.
