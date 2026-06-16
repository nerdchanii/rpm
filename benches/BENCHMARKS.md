---
benchmark_data: benches/histories/2026-06-16-000/benchmarks.json
benchmark_chart: benches/histories/2026-06-16-000/benchmark.svg
history_directory: benches/histories/2026-06-16-000
generated_at: 2026-06-16T02:09:17.980Z
status: "Representative suite"
---

# Semver Benchmark Checkpoint

Status: Representative suite
Date: 2026-06-16
History directory: `benches/histories/2026-06-16-000`

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
| version_parse | 1,897 | 4,699 | 2.48x |
| valid_canonical | 3,681.2 | 4,760 | 1.29x |
| invalid_version | 468 | 21,290 | 45.49x |
| range_parse | 4,369.2 | 3,632.2 | 0.83x |
| invalid_range | 1,317.8 | 45,255.4 | 34.34x |
| satisfies | 3,831.4 | 4,820.8 | 1.26x |
| max_satisfying | 5,107 | 24,457.2 | 4.79x |
| min_satisfying | 5,069 | 20,161.2 | 3.98x |

## Notes

- Generated from tracked benchmark history.
