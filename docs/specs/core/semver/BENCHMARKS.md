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

Change: `Version::parse` now parses the three required numeric components into
a fixed array instead of allocating a temporary vector. The flexible vector
parser remains for partial range versions.

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
