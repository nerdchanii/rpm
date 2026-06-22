---
benchmark_data: benches/histories/2026-06-22-002/benchmarks.json
benchmark_chart: benches/histories/2026-06-22-002/benchmark.svg
history_directory: benches/histories/2026-06-22-002
generated_at: 2026-06-22T10:03:30.871Z
status: "Representative suite"
---

# Semver Benchmark Checkpoint

Status: Representative suite
Date: 2026-06-22
History directory: `benches/histories/2026-06-22-002`

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
| version_parse | 2,148 | 4,776.6 | 2.22x |
| valid_canonical | 3,964.2 | 4,903 | 1.24x |
| invalid_version | 469.6 | 22,571.8 | 48.07x |
| range_parse | 4,473.2 | 4,021.2 | 0.90x |
| invalid_range | 1,429.8 | 47,552.8 | 33.26x |
| satisfies | 4,197.4 | 5,192 | 1.24x |
| max_satisfying | 5,230 | 26,371.8 | 5.04x |
| min_satisfying | 5,197 | 20,631.2 | 3.97x |

## Notes

- Generated from tracked benchmark history.
