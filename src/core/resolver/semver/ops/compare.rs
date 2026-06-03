use std::cmp::Ordering;

use crate::core::resolver::semver::version::compare::{
    compare_build_versions, compare_identifier_strings,
};
use crate::core::resolver::semver::version::normalize::strip_build_metadata;
use crate::core::resolver::semver::version::Version;
use crate::core::resolver::semver::{SemverError, VersionOptions};

pub fn valid(version: &str) -> Option<String> {
    valid_with_options(version, VersionOptions::default())
}

pub fn valid_with_options(version: &str, options: VersionOptions) -> Option<String> {
    Version::parse_with_options(version, options)
        .ok()
        .map(|version| version.to_string())
}

pub fn clean(version: &str) -> Option<String> {
    clean_with_options(version, VersionOptions::default())
}

pub fn clean_with_options(version: &str, options: VersionOptions) -> Option<String> {
    let version = version.trim();
    valid_with_options(version, options)
        .map(strip_build_metadata)
        .or_else(|| {
            let cleaned = version.strip_prefix('=').unwrap_or(version).trim_start();
            let cleaned = cleaned.strip_prefix('v').unwrap_or(cleaned);
            valid_with_options(cleaned, options).map(strip_build_metadata)
        })
}

pub fn compare(left: &str, right: &str) -> Result<Ordering, SemverError> {
    compare_with_options(left, right, VersionOptions::default())
}

pub fn compare_with_options(
    left: &str,
    right: &str,
    options: VersionOptions,
) -> Result<Ordering, SemverError> {
    Ok(Version::parse_with_options(left, options)?
        .cmp(&Version::parse_with_options(right, options)?))
}

pub fn compare_loose(left: &str, right: &str) -> Result<Ordering, SemverError> {
    compare_with_options(left, right, VersionOptions { loose: true })
}

pub fn rcompare(left: &str, right: &str) -> Result<Ordering, SemverError> {
    compare(right, left)
}

pub fn compare_build(left: &str, right: &str) -> Result<Ordering, SemverError> {
    let left = left.parse::<Version>()?;
    let right = right.parse::<Version>()?;
    Ok(compare_build_versions(&left, &right))
}

pub fn compare_identifiers(left: &str, right: &str) -> Ordering {
    compare_identifier_strings(left, right)
}

pub fn rcompare_identifiers(left: &str, right: &str) -> Ordering {
    compare_identifiers(right, left)
}

pub fn eq(left: &str, right: &str) -> Result<bool, SemverError> {
    eq_with_options(left, right, VersionOptions::default())
}

pub fn eq_with_options(
    left: &str,
    right: &str,
    options: VersionOptions,
) -> Result<bool, SemverError> {
    Ok(compare_with_options(left, right, options)? == Ordering::Equal)
}

pub fn neq(left: &str, right: &str) -> Result<bool, SemverError> {
    neq_with_options(left, right, VersionOptions::default())
}

pub fn neq_with_options(
    left: &str,
    right: &str,
    options: VersionOptions,
) -> Result<bool, SemverError> {
    Ok(!eq_with_options(left, right, options)?)
}

pub fn gt(left: &str, right: &str) -> Result<bool, SemverError> {
    gt_with_options(left, right, VersionOptions::default())
}

pub fn gt_with_options(
    left: &str,
    right: &str,
    options: VersionOptions,
) -> Result<bool, SemverError> {
    Ok(compare_with_options(left, right, options)? == Ordering::Greater)
}

pub fn gte(left: &str, right: &str) -> Result<bool, SemverError> {
    gte_with_options(left, right, VersionOptions::default())
}

pub fn gte_with_options(
    left: &str,
    right: &str,
    options: VersionOptions,
) -> Result<bool, SemverError> {
    Ok(matches!(
        compare_with_options(left, right, options)?,
        Ordering::Greater | Ordering::Equal
    ))
}

pub fn lt(left: &str, right: &str) -> Result<bool, SemverError> {
    lt_with_options(left, right, VersionOptions::default())
}

pub fn lt_with_options(
    left: &str,
    right: &str,
    options: VersionOptions,
) -> Result<bool, SemverError> {
    Ok(compare_with_options(left, right, options)? == Ordering::Less)
}

pub fn lte(left: &str, right: &str) -> Result<bool, SemverError> {
    lte_with_options(left, right, VersionOptions::default())
}

pub fn lte_with_options(
    left: &str,
    right: &str,
    options: VersionOptions,
) -> Result<bool, SemverError> {
    Ok(matches!(
        compare_with_options(left, right, options)?,
        Ordering::Less | Ordering::Equal
    ))
}

pub fn cmp(left: &str, op: &str, right: &str) -> Result<bool, SemverError> {
    cmp_with_options(left, op, right, VersionOptions::default())
}

pub fn cmp_with_options(
    left: &str,
    op: &str,
    right: &str,
    options: VersionOptions,
) -> Result<bool, SemverError> {
    match op {
        "===" => Ok(left == right),
        "!==" => Ok(left != right),
        "" | "=" | "==" => eq_with_options(left, right, options),
        "!=" => neq_with_options(left, right, options),
        ">" => gt_with_options(left, right, options),
        ">=" => gte_with_options(left, right, options),
        "<" => lt_with_options(left, right, options),
        "<=" => lte_with_options(left, right, options),
        _ => Err(SemverError::InvalidOperator(op.to_string())),
    }
}

pub fn major(version: &str) -> Result<u64, SemverError> {
    major_with_options(version, VersionOptions::default())
}

pub fn major_with_options(version: &str, options: VersionOptions) -> Result<u64, SemverError> {
    Ok(Version::parse_with_options(version, options)?.major)
}

pub fn minor(version: &str) -> Result<u64, SemverError> {
    minor_with_options(version, VersionOptions::default())
}

pub fn minor_with_options(version: &str, options: VersionOptions) -> Result<u64, SemverError> {
    Ok(Version::parse_with_options(version, options)?.minor)
}

pub fn patch(version: &str) -> Result<u64, SemverError> {
    patch_with_options(version, VersionOptions::default())
}

pub fn patch_with_options(version: &str, options: VersionOptions) -> Result<u64, SemverError> {
    Ok(Version::parse_with_options(version, options)?.patch)
}

pub fn prerelease(version: &str) -> Result<Option<Vec<String>>, SemverError> {
    prerelease_with_options(version, VersionOptions::default())
}

pub fn prerelease_with_options(
    version: &str,
    options: VersionOptions,
) -> Result<Option<Vec<String>>, SemverError> {
    let prerelease = Version::parse_with_options(version, options)?.prerelease;
    if prerelease.is_empty() {
        Ok(None)
    } else {
        Ok(Some(
            prerelease
                .into_iter()
                .map(|identifier| identifier.to_string())
                .collect(),
        ))
    }
}

pub fn diff(left: &str, right: &str) -> Result<Option<&'static str>, SemverError> {
    let left = left.parse::<Version>()?;
    let right = right.parse::<Version>()?;
    let comparison = left.cmp(&right);
    if comparison == Ordering::Equal {
        return Ok(None);
    }

    let (high, low) = if comparison == Ordering::Greater {
        (&left, &right)
    } else {
        (&right, &left)
    };
    let high_has_pre = !high.prerelease.is_empty();
    let low_has_pre = !low.prerelease.is_empty();

    if low_has_pre && !high_has_pre {
        if low.minor == 0 && low.patch == 0 {
            return Ok(Some("major"));
        }
        if low.compare_main(high) == Ordering::Equal {
            if low.minor > 0 && low.patch == 0 {
                return Ok(Some("minor"));
            }
            return Ok(Some("patch"));
        }
    }

    let prefix = if high_has_pre { "pre" } else { "" };
    if left.major != right.major {
        return Ok(Some(if prefix.is_empty() {
            "major"
        } else {
            "premajor"
        }));
    }
    if left.minor != right.minor {
        return Ok(Some(if prefix.is_empty() {
            "minor"
        } else {
            "preminor"
        }));
    }
    if left.patch != right.patch {
        return Ok(Some(if prefix.is_empty() {
            "patch"
        } else {
            "prepatch"
        }));
    }
    Ok(Some("prerelease"))
}
