---
benchmark_data: benches/histories/2026-06-16-002/benchmarks.json
benchmark_chart: benches/histories/2026-06-16-002/benchmark.svg
history_directory: benches/histories/2026-06-16-002
generated_at: 2026-06-16T04:25:01.398Z
status: "Representative suite"
---

# Semver Benchmark Checkpoint

Status: Representative suite
Date: 2026-06-16
History directory: `benches/histories/2026-06-16-002`

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
| version_parse | 1,941.2 | 5,635.4 | 2.90x |
| valid_canonical | 3,911.6 | 4,988.6 | 1.28x |
| invalid_version | 503 | 24,519 | 48.75x |
| range_parse | 4,816.2 | 4,998.6 | 1.04x |
| invalid_range | 1,394.8 | 64,006.2 | 45.89x |
| satisfies | 4,246.2 | 6,380.4 | 1.50x |
| max_satisfying | 5,763 | 31,960.8 | 5.55x |
| min_satisfying | 5,373.4 | 24,837.4 | 4.62x |

## Notes

- Generated from tracked benchmark history.
