---
benchmark_data: benches/histories/2026-06-22-000/benchmarks.json
benchmark_chart: benches/histories/2026-06-22-000/benchmark.svg
history_directory: benches/histories/2026-06-22-000
generated_at: 2026-06-22T06:20:11.055Z
status: "Representative suite"
---

# Semver Benchmark Checkpoint

Status: Representative suite
Date: 2026-06-22
History directory: `benches/histories/2026-06-22-000`

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
| version_parse | 2,414 | 5,498.8 | 2.28x |
| valid_canonical | 4,791.2 | 6,257.6 | 1.31x |
| invalid_version | 598.2 | 28,989.6 | 48.46x |
| range_parse | 5,933.6 | 5,067.6 | 0.85x |
| invalid_range | 1,926.2 | 63,877 | 33.16x |
| satisfies | 5,410 | 6,041 | 1.12x |
| max_satisfying | 7,306.6 | 34,251.8 | 4.69x |
| min_satisfying | 7,030.2 | 25,525.8 | 3.63x |

## Notes

- Generated from tracked benchmark history.
