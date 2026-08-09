---
benchmark_data: benches/histories/2026-08-09-001/benchmarks.json
benchmark_chart: benches/histories/2026-08-09-001/benchmark.svg
history_directory: benches/histories/2026-08-09-001
generated_at: 2026-08-09T19:22:46.502Z
status: "Representative suite"
---

# Semver Benchmark Checkpoint

Status: Representative suite
Date: 2026-08-09
History directory: `benches/histories/2026-08-09-001`

## Command

```sh
node scripts/benchmark-semver.mjs
```

## Environment

- Host: darwin arm64
- Rust: `rustc 1.97.1 (8bab26f4f 2026-07-14)`
- Node: `v24.18.0`
- npm: `11.16.0`
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
| version_parse | 2,070.8 | 6,424.8 | 3.10x |
| valid_canonical | 4,884.8 | 6,866.8 | 1.41x |
| invalid_version | 671.2 | 33,750.4 | 50.28x |
| range_parse | 5,731 | 5,207.8 | 0.91x |
| invalid_range | 1,937 | 73,197 | 37.79x |
| satisfies | 5,447.2 | 8,069.6 | 1.48x |
| max_satisfying | 6,793 | 34,230.6 | 5.04x |
| min_satisfying | 6,769.8 | 29,606.8 | 4.37x |

## Notes

- Generated from tracked benchmark history.
