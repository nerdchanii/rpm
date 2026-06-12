use crate::core::resolver::semver::{SemverError, VersionOptions};

use super::{
    normalize::normalize_version_input, PrereleaseIdentifier, Version, MAX_SAFE_COMPONENT,
    MAX_VERSION_LENGTH,
};

pub(crate) fn parse_version(input: &str, options: VersionOptions) -> Result<Version, SemverError> {
    let input = input.trim();
    if input.len() > MAX_VERSION_LENGTH {
        return Err(SemverError::InvalidVersion(input.to_string()));
    }
    let normalized = normalize_version_input(input, options);
    let input = normalized.as_ref();
    let (core, build) = input
        .split_once('+')
        .map_or((input, None), |(core, build)| (core, Some(build)));
    let build = build.map_or(Ok(Vec::new()), |build| parse_build(build, input))?;
    let (numbers, prerelease) = core
        .split_once('-')
        .map_or((core, None), |(numbers, prerelease)| {
            (numbers, Some(prerelease))
        });
    let [major, minor, patch] = parse_exact_numeric_parts(numbers, input)?;
    let prerelease = parse_prerelease(prerelease, input)?;
    Ok(Version {
        major,
        minor,
        patch,
        prerelease,
        build,
    })
}

pub(crate) fn parse_numeric_parts(numbers: &str, input: &str) -> Result<Vec<u64>, SemverError> {
    let mut parts = Vec::new();
    for part in numbers.split('.') {
        if part.is_empty() || (part.len() > 1 && part.starts_with('0')) {
            return Err(SemverError::InvalidVersion(input.to_string()));
        }
        parts.push(
            parse_component(part).map_err(|_| SemverError::InvalidVersion(input.to_string()))?,
        );
    }
    Ok(parts)
}

fn parse_exact_numeric_parts(numbers: &str, input: &str) -> Result<[u64; 3], SemverError> {
    let mut parts = numbers.split('.');
    let major = parse_numeric_part(parts.next(), input)?;
    let minor = parse_numeric_part(parts.next(), input)?;
    let patch = parse_numeric_part(parts.next(), input)?;
    if parts.next().is_some() {
        return Err(SemverError::InvalidVersion(input.to_string()));
    }
    Ok([major, minor, patch])
}

fn parse_numeric_part(part: Option<&str>, input: &str) -> Result<u64, SemverError> {
    let Some(part) = part else {
        return Err(SemverError::InvalidVersion(input.to_string()));
    };
    if part.is_empty() || (part.len() > 1 && part.starts_with('0')) {
        return Err(SemverError::InvalidVersion(input.to_string()));
    }
    parse_component(part).map_err(|_| SemverError::InvalidVersion(input.to_string()))
}

pub(crate) fn parse_component(part: &str) -> Result<u64, SemverError> {
    let component = part
        .parse::<u64>()
        .map_err(|_| SemverError::InvalidVersion(part.to_string()))?;
    if component > MAX_SAFE_COMPONENT {
        return Err(SemverError::InvalidVersion(part.to_string()));
    }
    Ok(component)
}

pub(crate) fn is_partial_version(version: &str) -> bool {
    matches!(numeric_part_count(version), 1 | 2)
}

pub(crate) fn numeric_part_count(version: &str) -> usize {
    let numbers = version
        .split_once('-')
        .map_or(version, |(numbers, _)| numbers);
    numbers.split('.').count()
}

pub(crate) fn parse_prerelease(
    prerelease: Option<&str>,
    input: &str,
) -> Result<Vec<PrereleaseIdentifier>, SemverError> {
    let Some(prerelease) = prerelease else {
        return Ok(Vec::new());
    };
    if prerelease.is_empty() {
        return Err(SemverError::InvalidVersion(input.to_string()));
    }
    let mut identifiers = Vec::new();
    for part in prerelease.split('.') {
        if part.is_empty() || !part.chars().all(|c| c.is_ascii_alphanumeric() || c == '-') {
            return Err(SemverError::InvalidVersion(input.to_string()));
        }
        if part.chars().all(|c| c.is_ascii_digit()) {
            if part.len() > 1 && part.starts_with('0') {
                return Err(SemverError::InvalidVersion(input.to_string()));
            }
            identifiers.push(PrereleaseIdentifier::Numeric(
                parse_component(part)
                    .map_err(|_| SemverError::InvalidVersion(input.to_string()))?,
            ));
        } else {
            identifiers.push(PrereleaseIdentifier::Text(part.to_string()));
        }
    }
    Ok(identifiers)
}

pub(crate) fn parse_build(build: &str, input: &str) -> Result<Vec<String>, SemverError> {
    if build.is_empty() {
        return Err(SemverError::InvalidVersion(input.to_string()));
    }
    let mut identifiers = Vec::new();
    for part in build.split('.') {
        if part.is_empty() || !part.chars().all(|c| c.is_ascii_alphanumeric() || c == '-') {
            return Err(SemverError::InvalidVersion(input.to_string()));
        }
        identifiers.push(part.to_string());
    }
    Ok(identifiers)
}
pub(crate) fn parse_number(value: &str, full_input: &str) -> Result<u64, SemverError> {
    let number = value
        .parse::<u64>()
        .map_err(|_| SemverError::InvalidRange(full_input.to_string()))?;
    if number > MAX_SAFE_COMPONENT {
        return Err(SemverError::InvalidRange(full_input.to_string()));
    }
    Ok(number)
}
