use crate::core::resolver::semver::version::Version;

#[derive(Debug, Clone, PartialEq, Eq)]
/// A parsed semantic version range.
///
/// Ranges use npm-compatible semantics, including range sets separated by
/// logical OR.
pub struct Range {
    pub(crate) sets: Vec<ComparatorSet>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct ComparatorSet {
    pub(crate) comparators: Vec<Comparator>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct Comparator {
    pub(crate) op: ComparatorOp,
    pub(crate) version: Version,
    pub(crate) include_zero_suffix: bool,
    pub(crate) include_prerelease_floor: bool,
    pub(crate) include_prerelease_upper_bound: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum ComparatorOp {
    Exact,
    GreaterThan,
    GreaterThanOrEqual,
    LessThan,
    LessThanOrEqual,
}
