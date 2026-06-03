use crate::core::resolver::semver::options::version_options_from_range;
use crate::core::resolver::semver::range::Range;
use crate::core::resolver::semver::version::compare::compare_build_versions;
use crate::core::resolver::semver::version::Version;
use crate::core::resolver::semver::{RangeOptions, SemverError, VersionOptions};

pub fn sort<'a, I>(versions: I) -> Result<Vec<&'a str>, SemverError>
where
    I: IntoIterator<Item = &'a str>,
{
    sort_with_options(versions, VersionOptions::default())
}

pub fn sort_with_options<'a, I>(
    versions: I,
    options: VersionOptions,
) -> Result<Vec<&'a str>, SemverError>
where
    I: IntoIterator<Item = &'a str>,
{
    let mut parsed = parse_sort_versions_with_options(versions, options)?;
    parsed.sort_by(|(_, left), (_, right)| compare_build_versions(left, right));
    Ok(parsed.into_iter().map(|(raw, _)| raw).collect())
}

pub fn rsort<'a, I>(versions: I) -> Result<Vec<&'a str>, SemverError>
where
    I: IntoIterator<Item = &'a str>,
{
    rsort_with_options(versions, VersionOptions::default())
}

pub fn rsort_with_options<'a, I>(
    versions: I,
    options: VersionOptions,
) -> Result<Vec<&'a str>, SemverError>
where
    I: IntoIterator<Item = &'a str>,
{
    let mut parsed = parse_sort_versions_with_options(versions, options)?;
    parsed.sort_by(|(_, left), (_, right)| compare_build_versions(right, left));
    Ok(parsed.into_iter().map(|(raw, _)| raw).collect())
}

pub fn max_satisfying<'a, I>(versions: I, range: &str) -> Result<Option<&'a str>, SemverError>
where
    I: IntoIterator<Item = &'a str>,
{
    max_satisfying_with_options(versions, range, RangeOptions::default())
}

pub fn max_satisfying_with_options<'a, I>(
    versions: I,
    range: &str,
    options: RangeOptions,
) -> Result<Option<&'a str>, SemverError>
where
    I: IntoIterator<Item = &'a str>,
{
    let range = Range::parse_with_options(range, options)?;
    let mut selected: Option<(&'a str, Version)> = None;
    for raw_version in versions {
        let Ok(version) =
            Version::parse_with_options(raw_version, version_options_from_range(options))
        else {
            continue;
        };
        if !range.satisfies_with_options(&version, options) {
            continue;
        }
        match &selected {
            Some((_, selected_version)) if version <= *selected_version => {}
            _ => selected = Some((raw_version, version)),
        }
    }
    Ok(selected.map(|(raw_version, _)| raw_version))
}

pub fn min_satisfying<'a, I>(versions: I, range: &str) -> Result<Option<&'a str>, SemverError>
where
    I: IntoIterator<Item = &'a str>,
{
    min_satisfying_with_options(versions, range, RangeOptions::default())
}

pub fn min_satisfying_with_options<'a, I>(
    versions: I,
    range: &str,
    options: RangeOptions,
) -> Result<Option<&'a str>, SemverError>
where
    I: IntoIterator<Item = &'a str>,
{
    let range = Range::parse_with_options(range, options)?;
    let mut selected: Option<(&'a str, Version)> = None;
    for raw_version in versions {
        let Ok(version) =
            Version::parse_with_options(raw_version, version_options_from_range(options))
        else {
            continue;
        };
        if !range.satisfies_with_options(&version, options) {
            continue;
        }
        match &selected {
            Some((_, selected_version)) if version >= *selected_version => {}
            _ => selected = Some((raw_version, version)),
        }
    }
    Ok(selected.map(|(raw_version, _)| raw_version))
}

pub fn simplify_range<'a, I>(versions: I, range: &str) -> Result<String, SemverError>
where
    I: IntoIterator<Item = &'a str>,
{
    simplify_range_with_options(versions, range, RangeOptions::default())
}

pub fn simplify_range_with_options<'a, I>(
    versions: I,
    range: &str,
    options: RangeOptions,
) -> Result<String, SemverError>
where
    I: IntoIterator<Item = &'a str>,
{
    let original = range.trim();
    let range = Range::parse_with_options(range, options)?;
    let mut parsed =
        parse_sort_versions_with_options(versions, version_options_from_range(options))?;
    parsed.sort_by(|(_, left), (_, right)| left.cmp(right));
    if parsed.is_empty() {
        return Ok(String::new());
    }

    let first_available = parsed[0].0;
    let mut runs: Vec<(&str, Option<&str>)> = Vec::new();
    let mut first_in_run: Option<&str> = None;
    let mut previous_in_run: Option<&str> = None;

    for (raw, version) in &parsed {
        if range.satisfies_with_options(version, options) {
            previous_in_run = Some(raw);
            if first_in_run.is_none() {
                first_in_run = Some(raw);
            }
        } else if let (Some(first), Some(previous)) = (first_in_run, previous_in_run) {
            runs.push((first, Some(previous)));
            first_in_run = None;
            previous_in_run = None;
        }
    }
    if let Some(first) = first_in_run {
        runs.push((first, None));
    }

    let simplified = runs
        .into_iter()
        .map(|(min, max)| match max {
            Some(max) if min == max => min.to_string(),
            None if min == first_available => "*".to_string(),
            None => format!(">={min}"),
            Some(max) if min == first_available => format!("<={max}"),
            Some(max) => format!("{min} - {max}"),
        })
        .collect::<Vec<_>>()
        .join(" || ");

    if simplified.len() < original.len() {
        Ok(simplified)
    } else {
        Ok(original.to_string())
    }
}
fn parse_sort_versions_with_options<'a, I>(
    versions: I,
    options: VersionOptions,
) -> Result<Vec<(&'a str, Version)>, SemverError>
where
    I: IntoIterator<Item = &'a str>,
{
    let mut parsed = Vec::new();
    for version in versions {
        parsed.push((version, Version::parse_with_options(version, options)?));
    }
    Ok(parsed)
}
