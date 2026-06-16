---
benchmark_data: {{benchmark_data}}
benchmark_chart: {{benchmark_chart}}
history_directory: {{history_directory}}
generated_at: {{generated_at}}
status: {{status_yaml}}
---

# Semver Benchmark Checkpoint

Status: {{status}}
Date: {{date}}
History directory: `{{history_directory}}`

## Command

```sh
{{command}}
```

## Environment

- Host: {{host}}
- Rust: `{{rust}}`
- Node: `{{node}}`
- npm: `{{npm}}`
- node-semver: `{{node_semver}}`

## Inputs

- Corpus: `benches/semver_corpus.json`
- Iterations: {{iterations}}
- Samples: {{samples}}
- Warmup samples: {{warmup_samples}}
- Outlier policy: {{outlier_policy}}

## Summary

| Operation | RPM Rust mean ns/iter | node-semver mean ns/iter | Rust speedup |
| --- | ---: | ---: | ---: |
{{summary_rows}}

## Notes

{{notes}}
