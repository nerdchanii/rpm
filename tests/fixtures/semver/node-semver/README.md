# node-semver Derived Fixtures

These fixtures are derived from `npm/node-semver` and are kept separate from
RPM-authored resolver fixtures.

Source repository: https://github.com/npm/node-semver

Pinned revision: `76416081a8413383cf6e24c82cafa438bd076d41`

Derived source files:

- `test/fixtures/comparisons.js`
- `test/fixtures/equality.js`
- `test/fixtures/increments.js`
- `test/fixtures/invalid-versions.js`
- `test/internal/identifiers.js`
- `test/fixtures/range-exclude.js`
- `test/fixtures/range-include.js`
- `test/fixtures/range-intersection.js`
- `test/fixtures/truncations.js`
- `test/fixtures/valid-versions.js`
- `test/fixtures/version-gt-range.js`
- `test/fixtures/version-lt-range.js`
- `test/fixtures/version-not-gt-range.js`
- `test/fixtures/version-not-lt-range.js`
- `test/functions/cmp.js`
- `test/functions/compare-build.js`
- `test/functions/coerce.js`
- `test/functions/diff.js`
- `test/functions/inc.js`
- `test/functions/major.js`
- `test/functions/prerelease.js`
- `test/functions/rcompare.js`
- `test/functions/rsort.js`
- `test/functions/satisfies.js`
- `test/functions/sort.js`
- `test/functions/truncate.js`
- `test/ranges/gtr.js`
- `test/ranges/ltr.js`
- `test/ranges/max-satisfying.js`
- `test/ranges/min-satisfying.js`
- `test/ranges/min-version.js`
- `test/ranges/outside.js`
- `test/ranges/simplify.js`
- `test/ranges/subset.js`
- `test/ranges/to-comparators.js`
- `test/ranges/valid.js`

License: ISC. See `THIRD_PARTY_NOTICES.md`.

## Current Coverage

`compatibility-subset.json` contains strict-mode cases that the current Rust
core is expected to pass now:

- version comparison ordering, including `rcompare`, `compareLoose`, and
  loose-mode comparison predicate subsets
- `compare_build`, `sort`, and `rsort` build metadata ordering
- version part and prerelease extraction, including loose-mode subsets
- `compare_identifiers` and `rcompare_identifiers` helper ordering
- `inc` release-type increments with identifier, identifier-base, and loose
  parsing subsets
- `coerce` default, numeric non-string input, and include-prerelease
  left-to-right and right-to-left version extraction
- `cmp` operator dispatch for strict semver comparisons and raw string identity
- strict valid and invalid version parsing, plus loose-mode `valid` and
  comparison subsets
- `clean` normalization for strict valid inputs, `=v` prefixes, and build
  metadata removal
- `diff` release type classification
- `truncate` release-type truncation for strict valid versions
- range `intersects` for exact, comparator, wildcard, partial, tilde, union,
  disjoint, and hyphen ranges
- `subset` for exact, comparator, wildcard, partial, tilde, caret, impossible,
  and union ranges, plus include-prerelease mode
- `simplify_range` over caller-supplied version lists, plus
  include-prerelease mode
- `min_version` for strict-mode exact, wildcard, partial, hyphen, tilde, caret,
  union, less-than, greater-than, and impossible ranges
- `outside`, `gtr`, and `ltr` for strict-mode exact, comparator, wildcard,
  partial, tilde, union ranges, include-prerelease, and loose-mode option
  subsets
- `to_comparators` for exact, comparator, spaced comparator, wildcard, partial,
  hyphen, tilde, `~>` alias, union, and impossible ranges
- `valid_range` canonicalization for strict-mode exact, comparator, wildcard,
  partial, hyphen, tilde, caret, union, invalid ranges, spaced operators,
  standalone operators, wildcard ranges with prerelease/build metadata,
  numeric safety boundaries, include-prerelease hyphen ranges, and loose-mode
  range parsing subsets, including long build metadata stripping
- `satisfies` for exact, wildcard, comparator, spaced comparator, union, caret,
  tilde, `~>` alias, partial, hyphen range forms, and loose-mode include and
  exclude range parsing subsets
- `satisfies` strict prerelease gating and include-prerelease mode for wildcard,
  partial, comparator, caret, and hyphen range forms
- `max_satisfying` order-independent selection, including include-prerelease
  and loose-mode option subsets
- `min_satisfying` order-independent selection, including include-prerelease
  and loose-mode option subsets

## Tracked Gaps

The full upstream fixture corpus also covers behavior that remains tracked
outside this Rust-core subset:

- Remaining advanced loose-mode fixture inventory and classification is
  tracked by #68.
- Dist-tags are registry metadata selectors, not semver ranges; that boundary
  is defined in `docs/specs/core/semver/SPEC.md`.
- JavaScript-only `coerce` object and function input behavior is tracked by
  #67 because those value kinds do not map directly to the typed Rust string
  and number APIs.
