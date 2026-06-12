use crate::core::resolver::semver::version::{PrereleaseIdentifier, Version};
use crate::core::resolver::semver::RangeOptions;

use super::interval::{interval_for_set, is_null_comparator, is_pure_null_set};
use super::{Comparator, ComparatorOp, ComparatorSet, Range};

impl Comparator {
    pub(crate) fn to_comparator_string(&self) -> String {
        self.to_comparator_string_with_options(RangeOptions::default())
    }

    pub(crate) fn to_comparator_string_with_options(&self, options: RangeOptions) -> String {
        let version = if self.include_prerelease_upper_bound && options.include_prerelease {
            self.version.next_patch().next_prerelease().to_string()
        } else if self.include_zero_suffix
            || (self.include_prerelease_floor
                && options.include_prerelease
                && self.op == ComparatorOp::GreaterThanOrEqual
                && self.version.prerelease.is_empty())
        {
            self.version.next_prerelease().to_string()
        } else {
            self.version.to_string()
        };
        let op = if self.include_prerelease_upper_bound && options.include_prerelease {
            ComparatorOp::LessThan
        } else {
            self.op
        };
        match op {
            ComparatorOp::Exact => version,
            ComparatorOp::GreaterThan => format!(">{version}"),
            ComparatorOp::GreaterThanOrEqual => format!(">={version}"),
            ComparatorOp::LessThan => format!("<{version}"),
            ComparatorOp::LessThanOrEqual => format!("<={version}"),
        }
    }
}

pub(crate) fn set_is_null_for_to_comparators(set: &ComparatorSet) -> bool {
    let Some(interval) = interval_for_set(set) else {
        return true;
    };
    let Some(upper) = interval.upper else {
        return false;
    };
    let semver_floor = Version {
        major: 0,
        minor: 0,
        patch: 0,
        prerelease: vec![PrereleaseIdentifier::Numeric(0)],
        build: Vec::new(),
    };
    let stable_floor = Version::plain(0, 0, 0);
    upper.version < semver_floor
        || (upper.version == semver_floor && !upper.inclusive)
        || (upper.version == stable_floor && !upper.inclusive)
}
impl Range {
    pub(crate) fn normalized(&self) -> String {
        self.normalized_with_options(RangeOptions::default())
    }

    pub(crate) fn normalized_with_options(&self, options: RangeOptions) -> String {
        if self.sets.iter().any(|set| set.comparators.is_empty()) {
            return "*".to_string();
        }
        let has_null_set = self.sets.iter().any(is_pure_null_set);
        let mut normalized_sets = Vec::new();
        for set in &self.sets {
            if has_null_set
                && !is_pure_null_set(set)
                && set.comparators.iter().any(is_null_comparator)
            {
                continue;
            }
            let normalized = set
                .comparators
                .iter()
                .map(|comparator| comparator.to_comparator_string_with_options(options))
                .collect::<Vec<_>>()
                .join(" ");
            if !normalized_sets.contains(&normalized) {
                normalized_sets.push(normalized);
            }
        }
        normalized_sets.join("||")
    }
}
