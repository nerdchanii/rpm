---
benchmark_data: benches/histories/2026-08-09-000/benchmarks.json
benchmark_chart: benches/histories/2026-08-09-000/benchmark.svg
history_directory: benches/histories/2026-08-09-000
generated_at: 2026-08-09T17:09:13.215Z
status: "Representative suite"
---

# Semver Benchmark Checkpoint

Status: Representative suite
Date: 2026-08-09
History directory: `benches/histories/2026-08-09-000`

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
| version_parse | 2,023.6 | 5,513.8 | 2.72x |
| valid_canonical | 4,203.8 | 5,518.8 | 1.31x |
| invalid_version | 549.8 | 27,202.6 | 49.48x |
| range_parse | 4,962.2 | 4,420 | 0.89x |
| invalid_range | 1,464.6 | 61,442.4 | 41.95x |
| satisfies | 4,632.2 | 5,948.6 | 1.28x |
| max_satisfying | 5,959.8 | 34,583.6 | 5.80x |
| min_satisfying | 5,581.6 | 32,442.8 | 5.81x |

## Notes

- Generated from tracked benchmark history.
