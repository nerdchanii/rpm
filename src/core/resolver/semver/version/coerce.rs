use crate::core::resolver::semver::CoerceOptions;

use super::{parse::parse_build, parse::parse_prerelease, Version, MAX_SAFE_COMPONENT};

#[derive(Debug, Clone)]
struct CoerceCandidate {
    version: Version,
    end: usize,
    components: usize,
}

impl CoerceCandidate {
    fn is_better_rtl_than(&self, other: &Self) -> bool {
        self.end > other.end || (self.end == other.end && self.components > other.components)
    }
}

pub fn coerce(input: &str) -> Option<String> {
    coerce_with_options(input, CoerceOptions::default())
}

pub fn coerce_number(input: u64) -> Option<String> {
    coerce_number_with_options(input, CoerceOptions::default())
}

pub fn coerce_number_with_options(input: u64, options: CoerceOptions) -> Option<String> {
    if input > MAX_SAFE_COMPONENT {
        return None;
    }
    coerce_with_options(&input.to_string(), options)
}

pub fn coerce_rtl(input: &str) -> Option<String> {
    coerce_with_options(
        input,
        CoerceOptions {
            rtl: true,
            include_prerelease: false,
        },
    )
}

pub fn coerce_with_options(input: &str, options: CoerceOptions) -> Option<String> {
    if options.rtl {
        return coerce_with_options_rtl(input, options);
    }

    let bytes = input.as_bytes();
    let mut index = 0;
    while index < bytes.len() {
        if !bytes[index].is_ascii_digit() {
            index += 1;
            continue;
        }

        let Some(candidate) = parse_coerce_candidate(input, index, options.include_prerelease)
        else {
            index = skip_ascii_digits(bytes, index);
            continue;
        };
        return Some(candidate.version.to_string());
    }
    None
}

fn coerce_with_options_rtl(input: &str, options: CoerceOptions) -> Option<String> {
    let bytes = input.as_bytes();
    let mut selected: Option<CoerceCandidate> = None;
    let mut index = 0;
    while index < bytes.len() {
        if !bytes[index].is_ascii_digit() || is_coerce_metadata_identifier_digit(input, index) {
            index += 1;
            continue;
        }
        if let Some(candidate) = parse_coerce_candidate(input, index, options.include_prerelease) {
            if selected
                .as_ref()
                .is_none_or(|selected| candidate.is_better_rtl_than(selected))
            {
                selected = Some(candidate);
            }
        }
        index = skip_ascii_digits(bytes, index);
    }
    selected.map(|candidate| candidate.version.to_string())
}
fn parse_coerce_component(input: &str, start: usize) -> (Option<u64>, usize) {
    let bytes = input.as_bytes();
    let end = skip_ascii_digits(bytes, start);
    let value = &input[start..end];
    let parsed = if value.len() > 16 {
        None
    } else {
        value
            .parse::<u64>()
            .ok()
            .filter(|component| *component <= MAX_SAFE_COMPONENT)
    };
    (parsed, end)
}

fn parse_coerce_candidate(
    input: &str,
    start: usize,
    include_prerelease: bool,
) -> Option<CoerceCandidate> {
    let (Some(major), mut end) = parse_coerce_component(input, start) else {
        return None;
    };
    let mut components = 1;
    let mut minor = 0;
    let mut patch = 0;

    if let Some((value, next_index)) = parse_coerce_dot_component(input, end) {
        minor = value;
        end = next_index;
        components = 2;
        if let Some((value, next_index)) = parse_coerce_dot_component(input, end) {
            patch = value;
            end = next_index;
            components = 3;
        }
    }

    let mut version = Version::plain(major, minor, patch);
    if include_prerelease {
        append_coerce_metadata(input, end, &mut version);
    }

    Some(CoerceCandidate {
        version,
        end,
        components,
    })
}

fn append_coerce_metadata(input: &str, index: usize, version: &mut Version) {
    let mut cursor = index;
    if input.as_bytes().get(cursor) == Some(&b'-') {
        if let Some((prerelease, next_index)) = read_coerce_identifier(input, cursor + 1) {
            if let Ok(parsed) = parse_prerelease(Some(prerelease), input) {
                version.prerelease = parsed;
                cursor = next_index;
            }
        }
    }

    if input.as_bytes().get(cursor) == Some(&b'+') {
        if let Some((build, _)) = read_coerce_identifier(input, cursor + 1) {
            if let Ok(parsed) = parse_build(build, input) {
                version.build = parsed;
            }
        }
    }
}

fn read_coerce_identifier(input: &str, start: usize) -> Option<(&str, usize)> {
    let bytes = input.as_bytes();
    let mut end = start;
    while bytes
        .get(end)
        .is_some_and(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'.'))
    {
        end += 1;
    }
    if end == start {
        return None;
    }
    Some((&input[start..end], end))
}

fn is_coerce_metadata_identifier_digit(input: &str, start: usize) -> bool {
    let bytes = input.as_bytes();
    start >= 2
        && bytes.get(start - 1) == Some(&b'.')
        && bytes
            .get(start - 2)
            .is_some_and(|byte| byte.is_ascii_alphabetic() || *byte == b'-')
}

fn parse_coerce_dot_component(input: &str, index: usize) -> Option<(u64, usize)> {
    let bytes = input.as_bytes();
    if bytes.get(index) != Some(&b'.') || !bytes.get(index + 1).is_some_and(u8::is_ascii_digit) {
        return None;
    }
    let (component, end) = parse_coerce_component(input, index + 1);
    component.map(|component| (component, end))
}

fn skip_ascii_digits(bytes: &[u8], mut index: usize) -> usize {
    while bytes.get(index).is_some_and(u8::is_ascii_digit) {
        index += 1;
    }
    index
}
