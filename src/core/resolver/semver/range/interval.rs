use crate::core::resolver::semver::version::{PrereleaseIdentifier, Version};
use crate::core::resolver::semver::RangeOptions;

use super::{Comparator, ComparatorOp, ComparatorSet, Range};

impl Range {
    pub(crate) fn intersects(&self, other: &Self) -> bool {
        self.sets.iter().any(|left| {
            other
                .sets
                .iter()
                .any(|right| comparator_sets_intersect(left, right))
        })
    }

    pub(crate) fn subset_of(&self, other: &Self, options: RangeOptions) -> bool {
        self.sets.iter().all(|left| {
            let Some(left_interval) = interval_for_set(left) else {
                return true;
            };
            other.sets.iter().any(|right| {
                let Some(right_interval) = interval_for_set(right) else {
                    return false;
                };
                interval_contains_with_options(&right_interval, &left_interval, options)
                    && prerelease_subset_allowed(left, right, options)
            })
        })
    }

    pub(crate) fn outside(&self, version: &Version, direction: OutsideDirection) -> bool {
        if self.satisfies(version) {
            return false;
        }

        let mut saw_satisfiable_set = false;
        for set in &self.sets {
            let Some(interval) = interval_for_set(set) else {
                continue;
            };
            saw_satisfiable_set = true;
            if !version_is_outside_interval(version, &interval, direction) {
                return false;
            }
        }
        saw_satisfiable_set
    }
}

pub(crate) fn is_pure_null_set(set: &ComparatorSet) -> bool {
    set.comparators.len() == 1 && is_null_comparator(&set.comparators[0])
}

pub(crate) fn is_null_comparator(comparator: &Comparator) -> bool {
    comparator.op == ComparatorOp::LessThan
        && comparator.include_zero_suffix
        && comparator.version == Version::plain(0, 0, 0)
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum OutsideDirection {
    GreaterThan,
    LessThan,
}

#[derive(Debug, Clone)]
pub(crate) struct Bound {
    pub(crate) version: Version,
    pub(crate) inclusive: bool,
}

#[derive(Debug, Clone, Default)]
pub(crate) struct Interval {
    pub(crate) lower: Option<Bound>,
    pub(crate) upper: Option<Bound>,
}

fn stricter_lower<'a>(left: Option<&'a Bound>, right: Option<&'a Bound>) -> Option<&'a Bound> {
    match (left, right) {
        (Some(left), Some(right)) => {
            if left.version > right.version {
                Some(left)
            } else if right.version > left.version {
                Some(right)
            } else if !left.inclusive {
                Some(left)
            } else {
                Some(right)
            }
        }
        (Some(bound), None) | (None, Some(bound)) => Some(bound),
        (None, None) => None,
    }
}

fn stricter_upper<'a>(left: Option<&'a Bound>, right: Option<&'a Bound>) -> Option<&'a Bound> {
    match (left, right) {
        (Some(left), Some(right)) => {
            if left.version < right.version {
                Some(left)
            } else if right.version < left.version {
                Some(right)
            } else if !left.inclusive {
                Some(left)
            } else {
                Some(right)
            }
        }
        (Some(bound), None) | (None, Some(bound)) => Some(bound),
        (None, None) => None,
    }
}

fn comparator_sets_intersect(left: &ComparatorSet, right: &ComparatorSet) -> bool {
    let Some(left) = interval_for_set(left) else {
        return false;
    };
    let Some(right) = interval_for_set(right) else {
        return false;
    };
    intervals_intersect(&left, &right)
}

pub(crate) fn interval_for_set(set: &ComparatorSet) -> Option<Interval> {
    let mut interval = Interval::default();
    for comparator in &set.comparators {
        apply_comparator_to_interval(&mut interval, comparator);
        if !interval_is_satisfiable(&interval) {
            return None;
        }
    }
    Some(interval)
}

pub(crate) fn min_version_for_set(set: &ComparatorSet) -> Option<Version> {
    let mut selected: Option<Version> = None;
    for comparator in &set.comparators {
        let candidate = match comparator.op {
            ComparatorOp::Exact | ComparatorOp::GreaterThanOrEqual => {
                Some(comparator.version.clone())
            }
            ComparatorOp::GreaterThan => {
                if comparator.version.prerelease.is_empty() {
                    Some(comparator.version.next_patch())
                } else {
                    Some(comparator.version.next_prerelease())
                }
            }
            ComparatorOp::LessThan | ComparatorOp::LessThanOrEqual => None,
        };
        if let Some(candidate) = candidate {
            if selected
                .as_ref()
                .is_none_or(|selected| candidate > *selected)
            {
                selected = Some(candidate);
            }
        }
    }
    selected
}

fn apply_comparator_to_interval(interval: &mut Interval, comparator: &Comparator) {
    let bound_version = comparator.interval_bound_version();
    match comparator.op {
        ComparatorOp::Exact => {
            let bound = Bound {
                version: bound_version,
                inclusive: true,
            };
            replace_lower_if_stricter(interval, bound.clone());
            replace_upper_if_stricter(interval, bound);
        }
        ComparatorOp::GreaterThan => replace_lower_if_stricter(
            interval,
            Bound {
                version: bound_version,
                inclusive: false,
            },
        ),
        ComparatorOp::GreaterThanOrEqual => replace_lower_if_stricter(
            interval,
            Bound {
                version: bound_version,
                inclusive: true,
            },
        ),
        ComparatorOp::LessThan => replace_upper_if_stricter(
            interval,
            Bound {
                version: bound_version,
                inclusive: false,
            },
        ),
        ComparatorOp::LessThanOrEqual => replace_upper_if_stricter(
            interval,
            Bound {
                version: bound_version,
                inclusive: true,
            },
        ),
    }
}

fn replace_lower_if_stricter(interval: &mut Interval, candidate: Bound) {
    let replace = interval.lower.as_ref().is_none_or(|current| {
        candidate.version > current.version
            || (candidate.version == current.version && !candidate.inclusive && current.inclusive)
    });
    if replace {
        interval.lower = Some(candidate);
    }
}

fn replace_upper_if_stricter(interval: &mut Interval, candidate: Bound) {
    let replace = interval.upper.as_ref().is_none_or(|current| {
        candidate.version < current.version
            || (candidate.version == current.version && !candidate.inclusive && current.inclusive)
    });
    if replace {
        interval.upper = Some(candidate);
    }
}

fn interval_is_satisfiable(interval: &Interval) -> bool {
    match (&interval.lower, &interval.upper) {
        (Some(lower), Some(upper)) => {
            lower.version < upper.version
                || (lower.version == upper.version && lower.inclusive && upper.inclusive)
        }
        _ => true,
    }
}

fn intervals_intersect(left: &Interval, right: &Interval) -> bool {
    let lower = stricter_lower(left.lower.as_ref(), right.lower.as_ref());
    let upper = stricter_upper(left.upper.as_ref(), right.upper.as_ref());
    match (lower, upper) {
        (Some(lower), Some(upper)) => {
            lower.version < upper.version
                || (lower.version == upper.version && lower.inclusive && upper.inclusive)
        }
        _ => true,
    }
}

fn interval_contains(outer: &Interval, inner: &Interval) -> bool {
    lower_contains(outer.lower.as_ref(), inner.lower.as_ref())
        && upper_contains(outer.upper.as_ref(), inner.upper.as_ref())
}

fn interval_contains_with_options(
    outer: &Interval,
    inner: &Interval,
    options: RangeOptions,
) -> bool {
    let floor = if options.include_prerelease {
        Version {
            major: 0,
            minor: 0,
            patch: 0,
            prerelease: vec![PrereleaseIdentifier::Numeric(0)],
            build: Vec::new(),
        }
    } else {
        Version::plain(0, 0, 0)
    };
    let mut normalized_inner = inner.clone();
    replace_lower_if_stricter(
        &mut normalized_inner,
        Bound {
            version: floor,
            inclusive: true,
        },
    );
    let inner = &normalized_inner;
    interval_contains(outer, inner)
}

fn prerelease_subset_allowed(
    left: &ComparatorSet,
    right: &ComparatorSet,
    options: RangeOptions,
) -> bool {
    options.include_prerelease
        || prerelease_mains(left)
            .into_iter()
            .all(|main| set_allows_prerelease_main(right, main))
}

fn prerelease_mains(set: &ComparatorSet) -> Vec<(u64, u64, u64)> {
    let mut mains = Vec::new();
    for comparator in &set.comparators {
        if comparator.version.prerelease.is_empty() {
            continue;
        }
        let main = (
            comparator.version.major,
            comparator.version.minor,
            comparator.version.patch,
        );
        if !mains.contains(&main) {
            mains.push(main);
        }
    }
    mains
}

fn set_allows_prerelease_main(set: &ComparatorSet, main: (u64, u64, u64)) -> bool {
    set.comparators.iter().any(|comparator| {
        !comparator.version.prerelease.is_empty()
            && (
                comparator.version.major,
                comparator.version.minor,
                comparator.version.patch,
            ) == main
    })
}

fn lower_contains(outer: Option<&Bound>, inner: Option<&Bound>) -> bool {
    match (outer, inner) {
        (None, _) => true,
        (Some(_), None) => false,
        (Some(outer), Some(inner)) => {
            outer.version < inner.version
                || (outer.version == inner.version && (outer.inclusive || !inner.inclusive))
        }
    }
}

fn upper_contains(outer: Option<&Bound>, inner: Option<&Bound>) -> bool {
    match (outer, inner) {
        (None, _) => true,
        (Some(_), None) => false,
        (Some(outer), Some(inner)) => {
            outer.version > inner.version
                || (outer.version == inner.version && (outer.inclusive || !inner.inclusive))
        }
    }
}

fn version_is_outside_interval(
    version: &Version,
    interval: &Interval,
    direction: OutsideDirection,
) -> bool {
    match direction {
        OutsideDirection::GreaterThan => {
            let Some(upper) = &interval.upper else {
                return false;
            };
            version > &upper.version || (version == &upper.version && !upper.inclusive)
        }
        OutsideDirection::LessThan => {
            let Some(lower) = &interval.lower else {
                return false;
            };
            version < &lower.version || (version == &lower.version && !lower.inclusive)
        }
    }
}
