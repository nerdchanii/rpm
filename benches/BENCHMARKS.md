---
benchmark_data: benches/histories/2026-06-16-001/benchmarks.json
benchmark_chart: benches/histories/2026-06-16-001/benchmark.svg
history_directory: benches/histories/2026-06-16-001
generated_at: 2026-06-16T02:26:02.017Z
status: "Representative suite"
---

# Semver Benchmark Checkpoint

Status: Representative suite
Date: 2026-06-16
History directory: `benches/histories/2026-06-16-001`

## Command

```sh
node scripts/benchmark-semver.mjs
```

## Environment

- Host: darwin arm64
- Rust: `rustc 1.96.0 (ac68faa20 2026-05-25)`
- Node: `v22.22.3`
- npm: `10.9.8`
- node-semver: `7.8.2`

## Inputs

- Corpus: `benches/semver_corpus.json`
- Iterations: 50000
- Samples: 5
- Warmup samples: 1
- Outlier policy: record_all_samples

## Summary

| Operation | RPM Rust mean ns/iter | node-semver mean ns/iter | Rust speedup |
| --- | ---: | ---: | ---: |
| version_parse | 2,284.6 | 5,509 | 2.41x |
| valid_canonical | 4,893.6 | 5,779.4 | 1.18x |
| invalid_version | 612.2 | 23,172.6 | 37.85x |
| range_parse | 5,871.4 | 4,153.2 | 0.71x |
| invalid_range | 1,699.8 | 52,564.6 | 30.92x |
| satisfies | 4,905.4 | 7,238.6 | 1.48x |
| max_satisfying | 6,045.8 | 28,135 | 4.65x |
| min_satisfying | 5,437.8 | 23,250.8 | 4.28x |

## Notes

- Generated from tracked benchmark history.
