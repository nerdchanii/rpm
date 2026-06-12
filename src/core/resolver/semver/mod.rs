//! npm-compatible semantic version parsing, range evaluation, and version
//! selection.
//!
//! This module is the semver facade used by RPM resolver and registry code.
//! Compatibility behavior is defined by `docs/specs/core/semver/SPEC.md`.

mod ops;
pub mod range;
pub mod version;

mod error;
mod options;

pub use error::SemverError;
pub use ops::{
    clean, clean_with_options, cmp, cmp_with_options, coerce, coerce_number,
    coerce_number_with_options, coerce_rtl, coerce_with_options, compare, compare_build,
    compare_identifiers, compare_loose, compare_with_options, diff, eq, eq_with_options, gt,
    gt_with_options, gte, gte_with_options, gtr, gtr_with_options, inc, inc_with_identifier,
    inc_with_identifier_base, inc_with_identifier_base_options, inc_with_identifier_options,
    inc_with_options, intersects, lt, lt_with_options, lte, lte_with_options, ltr,
    ltr_with_options, major, major_with_options, max_satisfying, max_satisfying_with_options,
    min_satisfying, min_satisfying_with_options, min_version, minor, minor_with_options, neq,
    neq_with_options, outside, outside_with_options, patch, patch_with_options, prerelease,
    prerelease_with_options, rcompare, rcompare_identifiers, rsort, rsort_with_options, satisfies,
    satisfies_with_options, simplify_range, simplify_range_with_options, sort, sort_with_options,
    subset, subset_with_options, to_comparators, truncate, valid, valid_range,
    valid_range_with_options, valid_with_options,
};
pub use options::{CoerceOptions, RangeOptions, VersionOptions};
pub use range::Range;
pub use version::Version;

#[cfg(test)]
mod tests;
