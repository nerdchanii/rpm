---
benchmark_data: benches/histories/2026-06-14-001/benchmarks.json
benchmark_chart: benches/histories/2026-06-14-001/benchmark.svg
history_directory: benches/histories/2026-06-14-001
generated_at: 2026-06-14T13:05:38.798Z
status: "Quick validation checkpoint, not representative benchmark numbers"
---

# Semver Benchmark Checkpoint

Status: Quick validation checkpoint, not representative benchmark numbers
Date: 2026-06-14
History directory: `benches/histories/2026-06-14-001`

## Command

```sh
RPM_SEMVER_BENCH_ITERATIONS=10 RPM_SEMVER_BENCH_SAMPLES=1 RPM_SEMVER_BENCH_WARMUP_SAMPLES=1 node scripts/benchmark-semver.mjs
```

## Environment

- Host: darwin arm64
- Rust: `rustc 1.94.1 (e408947bf 2026-03-25) (Homebrew)`
- Node: `v26.0.0`
- npm: `11.12.1`
- node-semver: `7.8.2`

## Inputs

- Corpus: `benches/semver_corpus.json`
- Iterations: 10
- Samples: 1
- Warmup samples: 1
- Outlier policy: record_all_samples

## Summary

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

## Notes

- Generated from tracked benchmark history.
- This run uses reduced settings for validation and should not be treated as representative performance data.
