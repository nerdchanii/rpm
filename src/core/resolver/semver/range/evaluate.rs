use crate::core::resolver::semver::RangeOptions;

use super::{Comparator, ComparatorOp, ComparatorSet, Range};
use crate::core::resolver::semver::version::Version;

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
        let comparison_version;
        let comparator_version = if self.include_zero_suffix {
            comparison_version = self.version.next_prerelease();
            &comparison_version
        } else {
            &self.version
        };
        match self.op {
            ComparatorOp::Exact => version == comparator_version,
            ComparatorOp::GreaterThan => version > comparator_version,
            ComparatorOp::GreaterThanOrEqual => version >= comparator_version,
            ComparatorOp::LessThan => version < comparator_version,
            ComparatorOp::LessThanOrEqual => version <= comparator_version,
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
