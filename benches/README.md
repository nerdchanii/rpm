# Benchmarks

This directory contains benchmark runners, shared benchmark input data, and
generated benchmark history for RPM.

Benchmarks are public project artifacts. The generated JSON and SVG history
under `benches/histories/` should be tracked when it records a branch's
benchmark result.

## Layout

```text
benches/
  BENCHMARKS.md                  # Generated current semver checkpoint
  README.md                      # Bench directory overview
  semver.rs                      # RPM Rust implementation runner
  semver_corpus.json             # Shared semver benchmark corpus
  histories/YYYY-MM-DD-000/      # Generated benchmark output
    benchmarks.json
    benchmark.svg
  template/BENCHMARKS.md         # Human-maintained summary template
```

`BENCHMARKS.md` is generated from `template/BENCHMARKS.md` and the selected
history JSON. Do not hand-edit benchmark result tables there; change the
template or rerun the generator.

## Semver Benchmarks

Use the history runner for normal captures:

```sh
node scripts/benchmark-semver.mjs
```

The history runner executes both benchmark implementations, parses their
machine-readable output, writes `benchmarks.json` and `benchmark.svg` under
`benches/histories/YYYY-MM-DD-000/`, then regenerates `benches/BENCHMARKS.md`
from the latest report.

To regenerate only the Markdown summary from an existing report:

```sh
node scripts/benchmark-semver.mjs --render benches/histories/YYYY-MM-DD-000/benchmarks.json
```

For quick local validation:

```sh
RPM_SEMVER_BENCH_ITERATIONS=10 RPM_SEMVER_BENCH_SAMPLES=1 RPM_SEMVER_BENCH_WARMUP_SAMPLES=1 node scripts/benchmark-semver.mjs
```

Reduced runs are useful for checking the pipeline, but they are not
representative performance data.

## Corpus

Both semver runners read `benches/semver_corpus.json`. The corpus includes:

- strict version parsing and canonical string construction inputs
- prerelease-heavy versions
- wildcard, hyphen, comparator-set, prerelease, and logical-OR ranges
- invalid version and invalid range inputs
- small and larger candidate lists for `max_satisfying` and `min_satisfying`

Keeping the corpus in one JSON file makes the Rust and JavaScript samples
directly comparable without mutating package manifests, lockfiles, `.rpm`, or
`node_modules`.

## Runner Roles

```text
benches/semver.rs                    # RPM Rust implementation runner
scripts/benchmark-node-semver.mjs    # node-semver implementation runner
scripts/benchmark-semver.mjs         # history/report generator
```

The implementation runners measure one semver implementation and print a
stable CSV-like stream to stdout. The history runner depends on this stdout
contract. If an implementation runner changes its output columns, update
`scripts/benchmark-semver.mjs`, `template/BENCHMARKS.md`, and any generated
benchmark summary in the same patch.

## GitHub Actions

`.github/workflows/semver-benchmarks.yml` runs the semver benchmark workflow
when semver implementation, corpus, runner, or benchmark template files change
in a same-repository pull request. The workflow commits the generated history
JSON/SVG and regenerated `BENCHMARKS.md` back to the PR branch when the run
changes those files.

Forked pull requests do not receive write tokens, so they must attach generated
benchmark artifacts manually or rerun the workflow from a trusted branch.
