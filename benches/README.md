# Benchmarks

This directory contains benchmark runners, shared benchmark input data, and
generated benchmark history for RPM.

## Layout

```text
benches/
  README.md
  BENCHMARKS.md
  semver.rs
  semver_corpus.json
  histories/
  template/
```

`BENCHMARKS.md` is the current operating document for semver benchmarks.
`template/BENCHMARKS.md` is a human-written checkpoint template. `histories/`
contains generated artifacts from `node scripts/benchmark-semver.mjs`.

Generated history is ignored by default. Review it locally before deciding
whether any generated checkpoint should be copied into a tracked artifact.
