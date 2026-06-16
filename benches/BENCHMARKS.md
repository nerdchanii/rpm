# Semver Benchmarks

Status: Representative suite
Date: 2026-06-12

These benchmarks are a performance investigation tool, not a permanent product
claim. Use them to compare broad trends between RPM's Rust semver facade and
`node-semver` before deciding whether an optimization is worth pursuing.

## Current Public Checkpoint

Status: Quick validation checkpoint, not representative benchmark numbers
Date: 2026-06-14
Generated history: `benches/histories/2026-06-14-001/`

This checkpoint proves the history runner works end-to-end and gives reviewers a
public snapshot with tracked JSON and SVG artifacts. The run used only 10
iterations, one measured sample, and one warmup sample, so use it as validation
output only. Run the default command before making performance claims.

Command:

```sh
RPM_SEMVER_BENCH_ITERATIONS=10 RPM_SEMVER_BENCH_SAMPLES=1 RPM_SEMVER_BENCH_WARMUP_SAMPLES=1 node scripts/benchmark-semver.mjs
```

Environment:

- Host: macOS aarch64
- Rust: `rustc 1.94.1 (e408947bf 2026-03-25) (Homebrew)`
- Node: `v26.0.0`
- npm: `11.12.1`
- node-semver: `7.8.2`

Summary:

| Operation | RPM Rust mean ns/iter | node-semver mean ns/iter | Rust speedup |
| --- | ---: | ---: | ---: |
| version_parse | 3,083 | 30,583 | 9.92x |
| valid_canonical | 5,845 | 7,100 | 1.21x |
| invalid_version | 920 | 26,441 | 28.74x |
| range_parse | 7,500 | 8,987 | 1.20x |
| invalid_range | 2,012 | 67,962 | 33.78x |
| satisfies | 4,700 | 8,974 | 1.91x |
| max_satisfying | 6,045 | 38,158 | 6.31x |
| min_satisfying | 5,950 | 41,816 | 7.03x |

## Directory Structure

```text
benches/
  BENCHMARKS.md                  # Actual benchmark documentation
  README.md                      # Bench directory overview
  semver.rs                      # RPM Rust implementation runner
  semver_corpus.json             # Shared benchmark corpus
  histories/YYYY-MM-DD-000/      # Generated benchmark output
    benchmarks.json
    benchmark.svg
  template/BENCHMARKS.md         # Human summary template
```

`benches/histories/` contains generated JSON and SVG benchmark output. These
artifacts are public benchmark records and should be tracked when they are part
of a branch's benchmark result.

## Corpus

Both benchmark runners read `benches/semver_corpus.json`. The corpus includes:

- strict version parsing and canonical string construction inputs
- prerelease-heavy versions
- wildcard, hyphen, comparator-set, prerelease, and logical-OR ranges
- invalid version and invalid range inputs
- small and larger candidate lists for `max_satisfying` and `min_satisfying`

Keeping the corpus in one JSON file makes the Rust and JavaScript samples
directly comparable without mutating package manifests, lockfiles, `.rpm`, or
`node_modules`.

## Runner Roles

The benchmark suite has two implementation runners and one history runner:

```text
benches/semver.rs                    # RPM Rust implementation runner
scripts/benchmark-node-semver.mjs    # node-semver implementation runner
scripts/benchmark-semver.mjs         # history/report generator
```

The implementation runners measure one semver implementation and print a
stable CSV-like stream to stdout. The history runner executes both
implementation runners, parses that stream, computes aggregate metrics, and
writes history artifacts.

Use the history runner for normal benchmark captures. Use the implementation
runners directly only when debugging one side of the comparison or checking the
raw machine-readable output.

When a benchmark result needs PR review, rerun the comparison with the history
runner, inspect the generated `benches/histories/YYYY-MM-DD-000/` artifacts
locally, track the generated JSON and SVG artifacts, and copy a concise human
checkpoint into this document. Do not keep ad hoc spec-doc benchmark SVG
comparisons going.

## History Runner

```sh
node scripts/benchmark-semver.mjs
```

The history runner executes both benchmark implementations, parses their
machine-readable output, computes per-operation summary statistics, and writes
the results under `benches/histories/`.

Each run creates the next available dated directory:

```text
benches/histories/YYYY-MM-DD-000/benchmarks.json
benches/histories/YYYY-MM-DD-000/benchmark.svg
```

If `YYYY-MM-DD-000` already exists, the suffix advances to `-001`, `-002`, and
so on. `benchmarks.json` stores raw runner output, metadata, per-operation
samples, summary statistics, and Rust-vs-node comparison ratios.
`benchmark.svg` renders the mean `ns_per_iter` values for quick visual review.

The JSON report uses this shape:

```text
schemaVersion
generatedAt
startedAt
outputDir
history
settings
commands
runs
summaries
comparisons
```

Important fields:

- `runs`: raw per-run data, including runner metadata, samples, and stdout
- `summaries`: mean, median, min, max, standard deviation, and sample count per
  operation
- `comparisons`: operation-level Rust and node mean `ns_per_iter` values plus
  Rust-vs-node speedup ratio

For quick local validation:

```sh
RPM_SEMVER_BENCH_ITERATIONS=10 RPM_SEMVER_BENCH_SAMPLES=1 RPM_SEMVER_BENCH_WARMUP_SAMPLES=1 node scripts/benchmark-semver.mjs
```

## Rust Runner

```sh
cargo bench --bench semver --quiet
```

The Rust runner records implementation metadata, target OS/architecture,
iteration count, sample count, warmup samples, and the outlier policy. By
default it runs one warmup sample, then records five samples with 50,000
iterations each.

For quick local validation:

```sh
RPM_SEMVER_BENCH_ITERATIONS=10 RPM_SEMVER_BENCH_SAMPLES=1 RPM_SEMVER_BENCH_WARMUP_SAMPLES=1 cargo bench --bench semver --quiet
```

## node-semver Runner

```sh
node scripts/benchmark-node-semver.mjs
```

The JavaScript runner installs the `semver` version declared in
`benches/semver_corpus.json` into a temporary directory, runs the same operation
groups over the same corpus, prints environment metadata, and removes the
temporary install when it exits. To reuse a prepared install instead, set
`NODE_SEMVER_MODULE_DIR` to a directory containing `node_modules/semver`.

For quick local validation:

```sh
RPM_SEMVER_BENCH_ITERATIONS=10 RPM_SEMVER_BENCH_SAMPLES=1 RPM_SEMVER_BENCH_WARMUP_SAMPLES=1 node scripts/benchmark-node-semver.mjs
```

## Output

Both runners emit CSV-like rows:

```text
semver benchmark suite=representative
metadata,key,value
metadata,implementation,rpm-rust
metadata,iterations,50000
name,sample,total_ms,ns_per_iter
version_parse,1,123.456,2469
```

The history runner depends on this stdout contract. If an implementation runner
changes its output columns, update `scripts/benchmark-semver.mjs` and this
document in the same patch.

`ns_per_iter` is the elapsed time for one full pass over the operation's corpus.
All samples are recorded. If a run contains an obvious system-noise outlier,
keep it in the raw output and explain any excluded summary separately.

## Operation Groups

- `version_parse`: parse strict versions without canonical string construction
- `valid_canonical`: parse versions through the compatibility facade and return
  canonical strings
- `invalid_version`: reject invalid versions
- `range_parse`: parse valid range expressions
- `invalid_range`: reject invalid range expressions
- `satisfies`: evaluate individual version/range pairs
- `max_satisfying`: select the highest satisfying candidate from each list
- `min_satisfying`: select the lowest satisfying candidate from each list
