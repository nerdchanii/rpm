use crate::core::resolver::semver::options::version_options_from_range;
use crate::core::resolver::semver::range::interval::{min_version_for_set, OutsideDirection};
use crate::core::resolver::semver::range::normalize::set_is_null_for_to_comparators;
use crate::core::resolver::semver::range::{Comparator, ComparatorSet, Range};
use crate::core::resolver::semver::version::Version;
use crate::core::resolver::semver::{RangeOptions, SemverError};

pub fn satisfies(version: &str, range: &str) -> Result<bool, SemverError> {
    let version = version.parse::<Version>()?;
    let range = range.parse::<Range>()?;
    Ok(range.satisfies(&version))
}

pub fn satisfies_with_options(
    version: &str,
    range: &str,
    options: RangeOptions,
) -> Result<bool, SemverError> {
    let version = Version::parse_with_options(version, version_options_from_range(options))?;
    let range = Range::parse_with_options(range, options)?;
    Ok(range.satisfies_with_options(&version, options))
}
pub fn to_comparators(range: &str) -> Result<Vec<Vec<String>>, SemverError> {
    let range = range.parse::<Range>()?;
    if range.sets.iter().any(|set| set.comparators.is_empty()) {
        return Ok(vec![vec![String::new()]]);
    }

    let sets: Vec<&ComparatorSet> = if range.sets.len() == 1 {
        range.sets.iter().collect()
    } else {
        let satisfiable_sets: Vec<&ComparatorSet> = range
            .sets
            .iter()
            .filter(|set| !set_is_null_for_to_comparators(set))
            .collect();
        if satisfiable_sets.is_empty() {
            return Ok(vec![vec!["<0.0.0-0".to_string()]]);
        }
        satisfiable_sets
    };

    Ok(sets
        .into_iter()
        .map(|set| {
            set.comparators
                .iter()
                .map(Comparator::to_comparator_string)
                .collect()
        })
        .collect())
}

pub fn valid_range(range: &str) -> Option<String> {
    range.parse::<Range>().ok().map(|range| range.normalized())
}

pub fn valid_range_with_options(range: &str, options: RangeOptions) -> Option<String> {
    Range::parse_with_options(range, options)
        .ok()
        .map(|range| range.normalized_with_options(options))
}

pub fn intersects(left: &str, right: &str) -> Result<bool, SemverError> {
    let left = left.parse::<Range>()?;
    let right = right.parse::<Range>()?;
    Ok(left.intersects(&right))
}

pub fn subset(sub: &str, dom: &str) -> Result<bool, SemverError> {
    subset_with_options(sub, dom, RangeOptions::default())
}

pub fn subset_with_options(
    sub: &str,
    dom: &str,
    options: RangeOptions,
) -> Result<bool, SemverError> {
    let sub = Range::parse_with_options(sub, options)?;
    let dom = Range::parse_with_options(dom, options)?;
    Ok(sub.subset_of(&dom, options))
}

pub fn outside(version: &str, range: &str, hilo: &str) -> Result<bool, SemverError> {
    outside_with_options(version, range, hilo, RangeOptions::default())
}

pub fn outside_with_options(
    version: &str,
    range: &str,
    hilo: &str,
    options: RangeOptions,
) -> Result<bool, SemverError> {
    let direction = match hilo {
        ">" => OutsideDirection::GreaterThan,
        "<" => OutsideDirection::LessThan,
        _ => return Err(SemverError::InvalidRange(hilo.to_string())),
    };
    let version = Version::parse_with_options(version, version_options_from_range(options))?;
    let range = Range::parse_with_options(range, options)?;
    Ok(range.outside(&version, direction))
}

pub fn gtr(version: &str, range: &str) -> Result<bool, SemverError> {
    outside(version, range, ">")
}

pub fn gtr_with_options(
    version: &str,
    range: &str,
    options: RangeOptions,
) -> Result<bool, SemverError> {
    outside_with_options(version, range, ">", options)
}

pub fn ltr(version: &str, range: &str) -> Result<bool, SemverError> {
    outside(version, range, "<")
}

pub fn ltr_with_options(
    version: &str,
    range: &str,
    options: RangeOptions,
) -> Result<bool, SemverError> {
    outside_with_options(version, range, "<", options)
}

pub fn min_version(range: &str) -> Result<Option<String>, SemverError> {
    let range = range.parse::<Range>()?;
    for candidate in ["0.0.0", "0.0.0-0"] {
        let version = candidate.parse::<Version>()?;
        if range.satisfies(&version) {
            return Ok(Some(version.to_string()));
        }
    }

    let mut selected: Option<Version> = None;
    for set in &range.sets {
        let Some(mut candidate) = min_version_for_set(set) else {
            continue;
        };
        if !range.satisfies(&candidate) {
            continue;
        }
        if selected
            .as_ref()
            .is_none_or(|selected| candidate < *selected)
        {
            selected = Some(std::mem::take(&mut candidate));
        }
    }
    Ok(selected.map(|version| version.to_string()))
}
