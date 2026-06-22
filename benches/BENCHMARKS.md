---
benchmark_data: benches/histories/2026-06-22-001/benchmarks.json
benchmark_chart: benches/histories/2026-06-22-001/benchmark.svg
history_directory: benches/histories/2026-06-22-001
generated_at: 2026-06-22T08:20:24.975Z
status: "Representative suite"
---

# Semver Benchmark Checkpoint

Status: Representative suite
Date: 2026-06-22
History directory: `benches/histories/2026-06-22-001`

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
| version_parse | 1,975.2 | 5,060 | 2.56x |
| valid_canonical | 3,961.4 | 4,960.2 | 1.25x |
| invalid_version | 505.2 | 22,101.2 | 43.75x |
| range_parse | 4,648 | 3,930.6 | 0.85x |
| invalid_range | 1,400.6 | 48,214.2 | 34.42x |
| satisfies | 4,075.6 | 5,169.2 | 1.27x |
| max_satisfying | 5,280.8 | 26,006.4 | 4.92x |
| min_satisfying | 5,265 | 21,893.4 | 4.16x |

## Notes

- Generated from tracked benchmark history.
