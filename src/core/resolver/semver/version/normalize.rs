use std::borrow::Cow;

use crate::core::resolver::semver::VersionOptions;

use super::parse::parse_component;
use super::Version;

pub(crate) fn normalize_version_input(input: &str, options: VersionOptions) -> Cow<'_, str> {
    let input = input.strip_prefix('v').unwrap_or(input);
    if !options.loose {
        return Cow::Borrowed(input);
    }

    let input = input.strip_prefix('=').unwrap_or(input).trim_start();
    let input = input.strip_prefix('v').unwrap_or(input);
    if input.parse::<Version>().is_ok() {
        return Cow::Borrowed(input);
    }

    normalize_loose_version(input).map_or(Cow::Borrowed(input), Cow::Owned)
}

fn normalize_loose_version(input: &str) -> Option<String> {
    let (without_build, build) = input
        .split_once('+')
        .map_or((input, None), |(core, build)| (core, Some(build)));

    let (numbers, prerelease) = if let Some((numbers, prerelease)) = without_build.split_once('-') {
        (numbers, Some(prerelease))
    } else if let Some((numbers, prerelease)) = split_loose_prerelease(without_build) {
        (numbers, Some(prerelease))
    } else {
        (without_build, None)
    };

    let numbers = normalize_loose_numeric_parts(numbers)?;
    let mut normalized = String::with_capacity(input.len() + 1);
    normalized.push_str(&numbers);
    if let Some(prerelease) = prerelease {
        normalized.push('-');
        normalized.push_str(&normalize_loose_prerelease(prerelease)?);
    }
    if let Some(build) = build {
        normalized.push('+');
        normalized.push_str(build);
    }
    Some(normalized)
}

pub(crate) fn normalize_loose_partial_version(input: &str) -> Option<String> {
    let (without_build, build) = input
        .split_once('+')
        .map_or((input, None), |(core, build)| (core, Some(build)));

    let (numbers, prerelease) = if let Some((numbers, prerelease)) = without_build.split_once('-') {
        if numbers.split('.').count() < 3 {
            return None;
        }
        (numbers, Some(prerelease))
    } else if let Some((numbers, prerelease)) = split_loose_prerelease(without_build) {
        (numbers, Some(prerelease))
    } else {
        (without_build, None)
    };

    let numbers = normalize_loose_partial_numeric_parts(numbers)?;
    let mut normalized = String::with_capacity(input.len() + 1);
    normalized.push_str(&numbers);
    if let Some(prerelease) = prerelease {
        normalized.push('-');
        normalized.push_str(&normalize_loose_prerelease(prerelease)?);
    }
    if let Some(build) = build {
        normalized.push('+');
        normalized.push_str(build);
    }
    Some(normalized)
}

fn normalize_loose_numeric_parts(numbers: &str) -> Option<String> {
    let mut parts = numbers.split('.');
    let major = normalize_loose_number(parts.next()?)?;
    let minor = normalize_loose_number(parts.next()?)?;
    let patch = normalize_loose_number(parts.next()?)?;
    if parts.next().is_some() {
        return None;
    }
    Some(format!("{major}.{minor}.{patch}"))
}

fn normalize_loose_partial_numeric_parts(numbers: &str) -> Option<String> {
    let mut normalized = Vec::new();
    for part in numbers.split('.') {
        normalized.push(normalize_loose_number(part)?.to_string());
    }
    if normalized.is_empty() || normalized.len() > 3 {
        return None;
    }
    Some(normalized.join("."))
}

fn normalize_loose_number(value: &str) -> Option<u64> {
    if value.is_empty() || !value.chars().all(|c| c.is_ascii_digit()) {
        return None;
    }
    parse_component(value).ok()
}

fn normalize_loose_prerelease(prerelease: &str) -> Option<String> {
    let mut normalized = Vec::new();
    for part in prerelease.split('.') {
        if part.is_empty() || !part.chars().all(|c| c.is_ascii_alphanumeric() || c == '-') {
            return None;
        }
        if part.chars().all(|c| c.is_ascii_digit()) {
            normalized.push(parse_component(part).ok()?.to_string());
        } else {
            normalized.push(part.to_string());
        }
    }
    Some(normalized.join("."))
}

fn split_loose_prerelease(input: &str) -> Option<(&str, &str)> {
    let mut dots = 0;
    let bytes = input.as_bytes();
    let mut index = 0;
    while index < bytes.len() {
        let byte = bytes[index];
        if byte == b'.' {
            dots += 1;
            index += 1;
            continue;
        }
        if !byte.is_ascii_digit() {
            break;
        }
        index += 1;
    }
    if dots == 2
        && index > 0
        && index < input.len()
        && bytes[index - 1].is_ascii_digit()
        && is_valid_loose_prerelease(&input[index..])
    {
        Some((&input[..index], &input[index..]))
    } else {
        None
    }
}

fn is_valid_loose_prerelease(value: &str) -> bool {
    value
        .split('.')
        .all(|part| !part.is_empty() && part.chars().all(|c| c.is_ascii_alphanumeric() || c == '-'))
}

pub(crate) fn strip_build_metadata(version: String) -> String {
    version
        .split_once('+')
        .map_or(version.clone(), |(version, _)| version.to_string())
}
