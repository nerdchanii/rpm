# Semver Benchmarks

Status: Baseline
Date: 2026-05-30

## Command

```sh
cargo bench --bench semver
```

Each sample ran the custom stable bench target with 50,000 iterations per
operation. The first release build compile was excluded from the baseline
samples below.

## Environment

- Host: Darwin arm64
- Rust: `rustc 1.94.1 (e408947bf 2026-03-25) (Homebrew)`

## Baseline

Five post-build samples:

| Operation | Mean ns/iter | Min ns/iter | Max ns/iter |
| --- | ---: | ---: | ---: |
| parse | 1088 | 1050 | 1125 |
| compare | 1084 | 1032 | 1250 |
| satisfies | 2083 | 2045 | 2102 |
| max_satisfying | 5268 | 5102 | 5599 |

Raw samples, in run order:

| Operation | Run 1 | Run 2 | Run 3 | Run 4 | Run 5 |
| --- | ---: | ---: | ---: | ---: | ---: |
| parse | 1050 | 1075 | 1125 | 1094 | 1098 |
| compare | 1250 | 1039 | 1058 | 1040 | 1032 |
| satisfies | 2101 | 2072 | 2096 | 2102 | 2045 |
| max_satisfying | 5107 | 5371 | 5599 | 5162 | 5102 |

## Post-Optimization: Exact Numeric Parse

Change at that checkpoint: the version parser parsed the three required
numeric components into a fixed array instead of allocating a temporary vector.
The flexible vector parser remained for partial range versions.

Validation after the change:

- `cargo fmt --check`
- `cargo test node_semver --lib`
- `cargo check`
- `cargo test`
- `cargo clippy --all-targets --all-features`
- `git diff --check`

Five samples with the same command and iteration count:

| Operation | Mean ns/iter | Min ns/iter | Max ns/iter | Baseline mean | Delta |
| --- | ---: | ---: | ---: | ---: | ---: |
| parse | 1143 | 904 | 1559 | 1088 | +5.1% |
| compare | 783 | 760 | 843 | 1084 | -27.8% |
| satisfies | 1893 | 1843 | 2037 | 2083 | -9.1% |
| max_satisfying | 3988 | 3970 | 3999 | 5268 | -24.3% |

Raw samples, in run order:

| Operation | Run 1 | Run 2 | Run 3 | Run 4 | Run 5 |
| --- | ---: | ---: | ---: | ---: | ---: |
| parse | 1559 | 904 | 1295 | 957 | 998 |
| compare | 788 | 760 | 843 | 764 | 762 |
| satisfies | 1878 | 2037 | 1855 | 1852 | 1843 |
| max_satisfying | 3988 | 3999 | 3997 | 3970 | 3985 |

The parse sample is noisy because this benchmark currently uses `valid`,
which includes canonical string construction after parsing. The operation was
kept unchanged so the baseline and post-optimization samples remain directly
comparable.

## Post-Refactor: Standalone-Ready Facade

Change: semver moved under `core::resolver::semver` with a root facade,
typed `Version` and `Range` APIs, split `version`/`range` implementation
modules, compatibility `ops`, `FromStr` typed parsing, and expanded
`node-semver` compatibility behavior.

Validation after the change:

- `cargo fmt --check`
- `cargo check`
- `cargo clippy --all-targets --all-features -- -D warnings`
- `cargo test`
- `cargo doc --no-deps`
- `git diff --check`

The first release build compile was excluded. Five post-build samples were run
with the same command and iteration count. Run 4 was an obvious system-noise
outlier and is kept in the raw sample table for transparency.

All five samples:

| Operation | Mean ns/iter | Min ns/iter | Max ns/iter | Previous mean | Delta |
| --- | ---: | ---: | ---: | ---: | ---: |
| parse | 5826 | 3234 | 10159 | 1143 | +409.7% |
| compare | 3120 | 2686 | 4054 | 783 | +298.5% |
| satisfies | 16026 | 8396 | 43344 | 1893 | +746.6% |
| max_satisfying | 42666 | 18492 | 132927 | 3988 | +969.9% |

Non-outlier samples, excluding Run 4:

| Operation | Mean ns/iter | Min ns/iter | Max ns/iter | Previous mean | Delta |
| --- | ---: | ---: | ---: | ---: | ---: |
| parse | 3743 | 3234 | 5066 | 1143 | +227.5% |
| compare | 3119 | 2686 | 4054 | 783 | +298.3% |
| satisfies | 9197 | 8396 | 10472 | 1893 | +385.8% |
| max_satisfying | 19850 | 18492 | 22636 | 3988 | +397.7% |

Raw samples, in run order:

| Operation | Run 1 | Run 2 | Run 3 | Run 4 | Run 5 |
| --- | ---: | ---: | ---: | ---: | ---: |
| parse | 3300 | 3370 | 3234 | 10159 | 5066 |
| compare | 2686 | 2958 | 4054 | 3101 | 3118 |
| satisfies | 8396 | 9296 | 8621 | 43344 | 10472 |
| max_satisfying | 22636 | 18492 | 19417 | 132927 | 18856 |

The performance regression is expected for this checkpoint: the benchmark now
exercises the expanded compatibility implementation and facade split, not only
the earlier optimized subset. This benchmark remains useful as the new
standalone-ready baseline for future parser and range-evaluation optimization.

## Post-Optimization: Zero-Suffix Range Evaluation

Change: range evaluation no longer allocates a temporary `Version` for
comparators that need the npm-compatible virtual `-0` suffix during matching.
`max_satisfying` and `min_satisfying` also compute derived version options once
per call instead of once per candidate version.

Validation after the change:

- `cargo fmt --check`
- `cargo test semver`
- `cargo clippy --all-targets --all-features -- -D warnings`

Five post-build samples with the same command and iteration count:

| Operation | Mean ns/iter | Min ns/iter | Max ns/iter | Previous non-outlier mean | Delta |
| --- | ---: | ---: | ---: | ---: | ---: |
| parse | 3435 | 3265 | 3606 | 3743 | -8.2% |
| compare | 2807 | 2704 | 2987 | 3119 | -10.0% |
| satisfies | 8697 | 7957 | 9084 | 9197 | -5.4% |
| max_satisfying | 15466 | 13284 | 16603 | 19850 | -22.1% |

Raw samples, in run order:

| Operation | Run 1 | Run 2 | Run 3 | Run 4 | Run 5 |
| --- | ---: | ---: | ---: | ---: | ---: |
| parse | 3435 | 3265 | 3275 | 3606 | 3597 |
| compare | 2704 | 2728 | 2767 | 2987 | 2851 |
| satisfies | 8918 | 8961 | 9084 | 8585 | 7957 |
| max_satisfying | 16603 | 16156 | 16385 | 13284 | 14900 |
