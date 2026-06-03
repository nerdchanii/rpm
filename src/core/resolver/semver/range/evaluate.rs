use std::cmp::Ordering;

use crate::core::resolver::semver::RangeOptions;

use super::{Comparator, ComparatorOp, ComparatorSet, Range};
use crate::core::resolver::semver::version::{PrereleaseIdentifier, Version};

impl Range {
    /// Returns whether `version` satisfies this range with default options.
    pub fn satisfies(&self, version: &Version) -> bool {
        self.satisfies_with_options(version, RangeOptions::default())
    }

    /// Returns whether `version` satisfies this range with explicit options.
    pub fn satisfies_with_options(&self, version: &Version, options: RangeOptions) -> bool {
        self.sets.iter().any(|set| {
            set.satisfies(version, options)
                && (options.include_prerelease || set.allows_prerelease(version))
        })
    }
}

impl ComparatorSet {
    fn satisfies(&self, version: &Version, options: RangeOptions) -> bool {
        self.comparators
            .iter()
            .all(|comparator| comparator.matches(version, options))
    }

    fn allows_prerelease(&self, version: &Version) -> bool {
        version.prerelease.is_empty()
            || self.comparators.iter().any(|comparator| {
                !comparator.version.prerelease.is_empty()
                    && comparator.version.has_same_main_version(version)
            })
    }
}

impl Comparator {
    fn matches(&self, version: &Version, options: RangeOptions) -> bool {
        if self.include_prerelease_floor
            && options.include_prerelease
            && self.op == ComparatorOp::GreaterThanOrEqual
            && !version.prerelease.is_empty()
            && self.version.has_same_main_version(version)
        {
            return version >= &self.version.next_prerelease();
        }
        let ordering = if self.include_zero_suffix {
            compare_with_zero_suffix(version, &self.version)
        } else {
            version.cmp(&self.version)
        };
        match self.op {
            ComparatorOp::Exact => ordering == Ordering::Equal,
            ComparatorOp::GreaterThan => ordering == Ordering::Greater,
            ComparatorOp::GreaterThanOrEqual => {
                matches!(ordering, Ordering::Greater | Ordering::Equal)
            }
            ComparatorOp::LessThan => ordering == Ordering::Less,
            ComparatorOp::LessThanOrEqual => matches!(ordering, Ordering::Less | Ordering::Equal),
        }
    }

    pub(crate) fn interval_bound_version(&self) -> Version {
        if self.include_zero_suffix {
            self.version.next_prerelease()
        } else {
            self.version.clone()
        }
    }
}

fn compare_with_zero_suffix(version: &Version, comparator: &Version) -> Ordering {
    version.compare_main(comparator).then_with(|| {
        compare_prerelease_with_zero_suffix(&version.prerelease, &comparator.prerelease)
    })
}

fn compare_prerelease_with_zero_suffix(
    version: &[PrereleaseIdentifier],
    comparator: &[PrereleaseIdentifier],
) -> Ordering {
    if version.is_empty() {
        return Ordering::Greater;
    }
    for (left, right) in version.iter().zip(comparator.iter()) {
        let ordering = compare_prerelease_identifier(left, right);
        if ordering != Ordering::Equal {
            return ordering;
        }
    }
    if version.len() <= comparator.len() {
        return version.len().cmp(&(comparator.len() + 1));
    }
    compare_prerelease_identifier(
        &version[comparator.len()],
        &PrereleaseIdentifier::Numeric(0),
    )
    .then_with(|| version.len().cmp(&(comparator.len() + 1)))
}

fn compare_prerelease_identifier(
    left: &PrereleaseIdentifier,
    right: &PrereleaseIdentifier,
) -> Ordering {
    match (left, right) {
        (PrereleaseIdentifier::Numeric(left), PrereleaseIdentifier::Numeric(right)) => {
            left.cmp(right)
        }
        (PrereleaseIdentifier::Numeric(_), PrereleaseIdentifier::Text(_)) => Ordering::Less,
        (PrereleaseIdentifier::Text(_), PrereleaseIdentifier::Numeric(_)) => Ordering::Greater,
        (PrereleaseIdentifier::Text(left), PrereleaseIdentifier::Text(right)) => left.cmp(right),
    }
}
