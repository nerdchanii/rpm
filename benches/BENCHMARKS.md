---
benchmark_data: benches/histories/2026-06-22-003/benchmarks.json
benchmark_chart: benches/histories/2026-06-22-003/benchmark.svg
history_directory: benches/histories/2026-06-22-003
generated_at: 2026-06-22T10:07:58.941Z
status: "Representative suite"
---

# Semver Benchmark Checkpoint

Status: Representative suite
Date: 2026-06-22
History directory: `benches/histories/2026-06-22-003`

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
| version_parse | 2,167.8 | 5,589.4 | 2.58x |
| valid_canonical | 4,077.6 | 5,805.4 | 1.42x |
| invalid_version | 532.4 | 28,893.2 | 54.27x |
| range_parse | 5,640.4 | 5,077.2 | 0.90x |
| invalid_range | 1,738 | 59,550.8 | 34.26x |
| satisfies | 4,947 | 6,512.4 | 1.32x |
| max_satisfying | 6,777 | 33,920.8 | 5.01x |
| min_satisfying | 6,307.8 | 25,238.8 | 4.00x |

## Notes

- Generated from tracked benchmark history.
