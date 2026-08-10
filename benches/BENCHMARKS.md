---
benchmark_data: benches/histories/2026-08-10-000/benchmarks.json
benchmark_chart: benches/histories/2026-08-10-000/benchmark.svg
history_directory: benches/histories/2026-08-10-000
generated_at: 2026-08-10T02:28:30.884Z
status: "Representative suite"
---

# Semver Benchmark Checkpoint

Status: Representative suite
Date: 2026-08-10
History directory: `benches/histories/2026-08-10-000`

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
| version_parse | 2,863 | 6,613.6 | 2.31x |
| valid_canonical | 8,125.2 | 7,215.6 | 0.89x |
| invalid_version | 814 | 35,983.6 | 44.21x |
| range_parse | 8,639.4 | 5,775.2 | 0.67x |
| invalid_range | 2,691.4 | 67,463.4 | 25.07x |
| satisfies | 6,959.4 | 6,063.6 | 0.87x |
| max_satisfying | 6,730 | 30,049.6 | 4.47x |
| min_satisfying | 7,215.4 | 25,823.8 | 3.58x |

## Notes

- Generated from tracked benchmark history.
