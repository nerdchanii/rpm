use crate::core::resolver::semver::version::normalize::normalize_loose_partial_version;
use crate::core::resolver::semver::version::parse::{
    is_partial_version, numeric_part_count, parse_number, parse_numeric_parts, parse_prerelease,
};
use crate::core::resolver::semver::version::{Version, MAX_SAFE_COMPONENT};
use crate::core::resolver::semver::{RangeOptions, SemverError, VersionOptions};

use super::{Comparator, ComparatorOp};

pub(super) fn normalize_comparator_tokens(
    raw_set: &str,
    full_input: &str,
) -> Result<Vec<String>, SemverError> {
    let mut normalized = Vec::new();
    let mut tokens = raw_set.split_whitespace().peekable();
    while let Some(token) = tokens.next() {
        if is_standalone_comparator_operator(token) || matches!(token, "^" | "~" | "~>") {
            let Some(version) = tokens.next() else {
                return Err(SemverError::InvalidRange(full_input.to_string()));
            };
            let operator = if token == "~>" { "~" } else { token };
            normalized.push(format!("{operator}{version}"));
        } else if let Some(rest) = token.strip_prefix("~>") {
            normalized.push(format!("~{rest}"));
        } else {
            normalized.push(token.to_string());
        }
    }
    Ok(normalized)
}

fn is_standalone_comparator_operator(token: &str) -> bool {
    matches!(token, ">" | ">=" | "<" | "<=" | "=")
}

pub(super) fn parse_hyphen_range(
    raw_set: &str,
    full_input: &str,
    options: RangeOptions,
) -> Result<Option<Vec<Comparator>>, SemverError> {
    let Some((lower, upper)) = raw_set.split_once(" - ") else {
        return Ok(None);
    };
    if upper.contains(" - ") {
        return Err(SemverError::InvalidRange(full_input.to_string()));
    }

    let mut comparators = Vec::new();
    comparators.extend(hyphen_lower_bound(lower.trim(), full_input, options)?);
    comparators.extend(hyphen_upper_bound(upper.trim(), full_input, options)?);
    Ok(Some(comparators))
}

fn hyphen_lower_bound(
    version: &str,
    full_input: &str,
    options: RangeOptions,
) -> Result<Vec<Comparator>, SemverError> {
    if is_wildcard(version) {
        return Ok(Vec::new());
    }
    if contains_wildcard(version) {
        let Some((lower, _)) = wildcard_bounds(version, full_input)? else {
            return Ok(Vec::new());
        };
        return Ok(vec![Comparator {
            op: ComparatorOp::GreaterThanOrEqual,
            version: lower,
            include_zero_suffix: false,
            include_prerelease_floor: true,
            include_prerelease_upper_bound: false,
        }]);
    }
    Ok(vec![Comparator {
        op: ComparatorOp::GreaterThanOrEqual,
        version: complete_partial_version(version, full_input, options)?,
        include_zero_suffix: false,
        include_prerelease_floor: true,
        include_prerelease_upper_bound: false,
    }])
}

fn hyphen_upper_bound(
    version: &str,
    full_input: &str,
    options: RangeOptions,
) -> Result<Vec<Comparator>, SemverError> {
    if is_wildcard(version) {
        return Ok(Vec::new());
    }
    if contains_wildcard(version) {
        let Some((_, upper)) = wildcard_bounds(version, full_input)? else {
            return Ok(Vec::new());
        };
        return Ok(vec![Comparator {
            op: ComparatorOp::LessThan,
            version: upper,
            include_zero_suffix: true,
            include_prerelease_floor: false,
            include_prerelease_upper_bound: false,
        }]);
    }
    let upper = complete_partial_version(version, full_input, options)?;
    if is_partial_version(version) {
        let upper = match numeric_part_count(version) {
            1 => Version::plain(upper.major + 1, 0, 0),
            2 => Version::plain(upper.major, upper.minor + 1, 0),
            _ => upper,
        };
        return Ok(vec![Comparator {
            op: ComparatorOp::LessThan,
            version: upper,
            include_zero_suffix: true,
            include_prerelease_floor: false,
            include_prerelease_upper_bound: false,
        }]);
    }
    Ok(vec![Comparator {
        op: ComparatorOp::LessThanOrEqual,
        version: upper,
        include_zero_suffix: false,
        include_prerelease_floor: false,
        include_prerelease_upper_bound: true,
    }])
}

pub(super) fn parse_token(
    token: &str,
    full_input: &str,
    options: RangeOptions,
) -> Result<Vec<Comparator>, SemverError> {
    if is_wildcard(token) {
        return Ok(Vec::new());
    }
    if let Some(rest) = token.strip_prefix('^') {
        return caret_range(rest, full_input, options);
    }
    if let Some(rest) = token.strip_prefix('~') {
        return tilde_range(rest, full_input, options);
    }
    let (op, version) = comparator_parts(token);
    if contains_wildcard(version) {
        return wildcard_range_with_op(op, version, full_input);
    }
    if is_partial_version(version) {
        return partial_range(op, version, full_input, options);
    }
    let version = parse_range_version(version, full_input, options)?;
    Ok(vec![Comparator {
        op,
        version,
        include_zero_suffix: false,
        include_prerelease_floor: false,
        include_prerelease_upper_bound: false,
    }])
}

fn comparator_parts(token: &str) -> (ComparatorOp, &str) {
    if let Some(rest) = token.strip_prefix(">=") {
        (ComparatorOp::GreaterThanOrEqual, rest)
    } else if let Some(rest) = token.strip_prefix("<=") {
        (ComparatorOp::LessThanOrEqual, rest)
    } else if let Some(rest) = token.strip_prefix('>') {
        (ComparatorOp::GreaterThan, rest)
    } else if let Some(rest) = token.strip_prefix('<') {
        (ComparatorOp::LessThan, rest)
    } else if let Some(rest) = token.strip_prefix('=') {
        (ComparatorOp::Exact, rest)
    } else {
        (ComparatorOp::Exact, token)
    }
}

fn caret_range(
    version: &str,
    full_input: &str,
    options: RangeOptions,
) -> Result<Vec<Comparator>, SemverError> {
    if is_wildcard(version) {
        return wildcard_range(version, full_input);
    }
    if contains_wildcard(version) {
        let Some((lower, _)) = wildcard_bounds(version, full_input)? else {
            return Ok(Vec::new());
        };
        let upper = if lower.major > 0 {
            Version::plain(lower.major + 1, 0, 0)
        } else if lower.minor > 0 {
            Version::plain(0, lower.minor + 1, 0)
        } else {
            Version::plain(1, 0, 0)
        };
        reject_oversized_version(&upper, full_input)?;
        return Ok(lower_upper_with_floor(lower, upper, true));
    }
    let lower = complete_partial_version(version, full_input, options)?;
    if numeric_part_count(version) == 1 && lower.major == 0 {
        return Ok(vec![Comparator {
            op: ComparatorOp::LessThan,
            version: Version::plain(1, 0, 0),
            include_zero_suffix: true,
            include_prerelease_floor: false,
            include_prerelease_upper_bound: false,
        }]);
    }
    let upper = if lower.major > 0 {
        Version::plain(lower.major + 1, 0, 0)
    } else if lower.minor > 0 {
        Version::plain(0, lower.minor + 1, 0)
    } else {
        Version::plain(0, 0, lower.patch + 1)
    };
    reject_oversized_version(&upper, full_input)?;
    Ok(lower_upper(lower, upper))
}

fn tilde_range(
    version: &str,
    full_input: &str,
    options: RangeOptions,
) -> Result<Vec<Comparator>, SemverError> {
    if contains_wildcard(version) || is_wildcard(version) {
        return wildcard_range(version, full_input);
    }
    let lower = complete_partial_version(version, full_input, options)?;
    let upper = match numeric_part_count(version) {
        0 | 1 => Version::plain(lower.major + 1, 0, 0),
        _ => Version::plain(lower.major, lower.minor + 1, 0),
    };
    Ok(lower_upper(lower, upper))
}

fn wildcard_range(version: &str, full_input: &str) -> Result<Vec<Comparator>, SemverError> {
    wildcard_range_with_op(ComparatorOp::Exact, version, full_input)
}

fn wildcard_range_with_op(
    op: ComparatorOp,
    version: &str,
    full_input: &str,
) -> Result<Vec<Comparator>, SemverError> {
    if is_wildcard(version) {
        return match op {
            ComparatorOp::Exact | ComparatorOp::GreaterThanOrEqual => Ok(Vec::new()),
            ComparatorOp::GreaterThan | ComparatorOp::LessThan | ComparatorOp::LessThanOrEqual => {
                Ok(vec![Comparator {
                    op: ComparatorOp::LessThan,
                    version: Version::plain(0, 0, 0),
                    include_zero_suffix: true,
                    include_prerelease_floor: false,
                    include_prerelease_upper_bound: false,
                }])
            }
        };
    }
    let Some((lower, upper)) = wildcard_bounds(version, full_input)? else {
        return Ok(Vec::new());
    };
    Ok(match op {
        ComparatorOp::Exact => lower_upper_with_floor(lower, upper, true),
        ComparatorOp::GreaterThanOrEqual => vec![Comparator {
            op,
            version: lower,
            include_zero_suffix: false,
            include_prerelease_floor: true,
            include_prerelease_upper_bound: false,
        }],
        ComparatorOp::GreaterThan => vec![Comparator {
            op: ComparatorOp::GreaterThanOrEqual,
            version: upper,
            include_zero_suffix: false,
            include_prerelease_floor: true,
            include_prerelease_upper_bound: false,
        }],
        ComparatorOp::LessThan => vec![Comparator {
            op,
            version: lower,
            include_zero_suffix: true,
            include_prerelease_floor: false,
            include_prerelease_upper_bound: false,
        }],
        ComparatorOp::LessThanOrEqual => vec![Comparator {
            op: ComparatorOp::LessThan,
            version: upper,
            include_zero_suffix: true,
            include_prerelease_floor: false,
            include_prerelease_upper_bound: false,
        }],
    })
}

fn wildcard_bounds(
    version: &str,
    full_input: &str,
) -> Result<Option<(Version, Version)>, SemverError> {
    let version = strip_range_metadata(version);
    let parts: Vec<&str> = version.split('.').collect();
    if parts.is_empty() || parts.len() > 3 {
        return Err(SemverError::InvalidRange(full_input.to_string()));
    }
    if is_wildcard(parts[0]) {
        return Ok(None);
    }
    let major = parse_number(parts[0], full_input)?;
    if parts.len() == 1 || is_wildcard(parts[1]) {
        return Ok(Some((
            Version::plain(major, 0, 0),
            Version::plain(major + 1, 0, 0),
        )));
    }
    let minor = parse_number(parts[1], full_input)?;
    if parts.len() == 2 || is_wildcard(parts[2]) {
        return Ok(Some((
            Version::plain(major, minor, 0),
            Version::plain(major, minor + 1, 0),
        )));
    }
    Err(SemverError::InvalidRange(full_input.to_string()))
}

fn lower_upper(lower: Version, upper: Version) -> Vec<Comparator> {
    lower_upper_with_floor(lower, upper, false)
}

fn lower_upper_with_floor(
    lower: Version,
    upper: Version,
    include_prerelease_floor: bool,
) -> Vec<Comparator> {
    vec![
        Comparator {
            op: ComparatorOp::GreaterThanOrEqual,
            version: lower,
            include_zero_suffix: false,
            include_prerelease_floor,
            include_prerelease_upper_bound: false,
        },
        Comparator {
            op: ComparatorOp::LessThan,
            version: upper,
            include_zero_suffix: true,
            include_prerelease_floor: false,
            include_prerelease_upper_bound: false,
        },
    ]
}

fn partial_range(
    op: ComparatorOp,
    version: &str,
    full_input: &str,
    options: RangeOptions,
) -> Result<Vec<Comparator>, SemverError> {
    let lower = complete_partial_version(version, full_input, options)?;
    match op {
        ComparatorOp::Exact => {
            let upper = match numeric_part_count(version) {
                0 => return Ok(Vec::new()),
                1 => Version::plain(lower.major + 1, 0, 0),
                2 => Version::plain(lower.major, lower.minor + 1, 0),
                _ => lower.clone(),
            };
            if upper == lower {
                Ok(vec![Comparator {
                    op: ComparatorOp::Exact,
                    version: lower,
                    include_zero_suffix: false,
                    include_prerelease_floor: false,
                    include_prerelease_upper_bound: false,
                }])
            } else {
                Ok(lower_upper_with_floor(lower, upper, true))
            }
        }
        ComparatorOp::GreaterThan => {
            let upper = match numeric_part_count(version) {
                0 => return Ok(Vec::new()),
                1 => Version::plain(lower.major + 1, 0, 0),
                2 => Version::plain(lower.major, lower.minor + 1, 0),
                _ => {
                    return Ok(vec![Comparator {
                        op,
                        version: lower,
                        include_zero_suffix: false,
                        include_prerelease_floor: false,
                        include_prerelease_upper_bound: false,
                    }]);
                }
            };
            Ok(vec![Comparator {
                op: ComparatorOp::GreaterThanOrEqual,
                version: upper,
                include_zero_suffix: false,
                include_prerelease_floor: true,
                include_prerelease_upper_bound: false,
            }])
        }
        ComparatorOp::GreaterThanOrEqual => Ok(vec![Comparator {
            op,
            version: lower,
            include_zero_suffix: false,
            include_prerelease_floor: true,
            include_prerelease_upper_bound: false,
        }]),
        ComparatorOp::LessThan => Ok(vec![Comparator {
            op,
            version: lower,
            include_zero_suffix: true,
            include_prerelease_floor: false,
            include_prerelease_upper_bound: false,
        }]),
        ComparatorOp::LessThanOrEqual => Ok(vec![Comparator {
            op,
            version: lower,
            include_zero_suffix: false,
            include_prerelease_floor: false,
            include_prerelease_upper_bound: false,
        }]),
    }
}

fn complete_partial_version(
    version: &str,
    full_input: &str,
    options: RangeOptions,
) -> Result<Version, SemverError> {
    let normalized;
    let version = if options.loose {
        normalized = normalize_loose_partial_version(version);
        normalized.as_deref().unwrap_or(version)
    } else {
        version
    };
    let version = version.strip_prefix('v').unwrap_or(version);
    let version = version
        .split_once('+')
        .map_or(version, |(version, _)| version);
    let (numbers, prerelease) = version
        .split_once('-')
        .map_or((version, None), |(numbers, prerelease)| {
            (numbers, Some(prerelease))
        });
    let mut parts = parse_numeric_parts(numbers, full_input)?;
    if parts.is_empty() || parts.len() > 3 {
        return Err(SemverError::InvalidRange(full_input.to_string()));
    }
    while parts.len() < 3 {
        parts.push(0);
    }
    let prerelease = parse_prerelease(prerelease, full_input)
        .map_err(|_| SemverError::InvalidRange(full_input.to_string()))?;
    Ok(Version {
        major: parts[0],
        minor: parts[1],
        patch: parts[2],
        prerelease,
        build: Vec::new(),
    })
}

fn parse_range_version(
    version: &str,
    full_input: &str,
    options: RangeOptions,
) -> Result<Version, SemverError> {
    let version = strip_range_build_metadata(version);
    Version::parse_with_options(
        version,
        VersionOptions {
            loose: options.loose,
        },
    )
    .map_err(|_| SemverError::InvalidRange(full_input.to_string()))
}

fn reject_oversized_version(version: &Version, full_input: &str) -> Result<(), SemverError> {
    if version.major > MAX_SAFE_COMPONENT
        || version.minor > MAX_SAFE_COMPONENT
        || version.patch > MAX_SAFE_COMPONENT
    {
        return Err(SemverError::InvalidRange(full_input.to_string()));
    }
    Ok(())
}
fn contains_wildcard(value: &str) -> bool {
    value.split('.').any(is_wildcard_component)
}

pub(super) fn is_wildcard(value: &str) -> bool {
    matches!(value, "*" | "x" | "X")
}

fn is_wildcard_component(value: &str) -> bool {
    is_wildcard(strip_range_metadata(value))
}

fn strip_range_metadata(value: &str) -> &str {
    let value = value.split_once('+').map_or(value, |(value, _)| value);
    value.split_once('-').map_or(value, |(value, _)| value)
}

fn strip_range_build_metadata(value: &str) -> &str {
    value.split_once('+').map_or(value, |(value, _)| value)
}
