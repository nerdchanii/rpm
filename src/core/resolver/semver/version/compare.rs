use std::cmp::Ordering;

use super::{PrereleaseIdentifier, Version};

pub(crate) fn compare_prerelease(
    left: &[PrereleaseIdentifier],
    right: &[PrereleaseIdentifier],
) -> Ordering {
    match (left.is_empty(), right.is_empty()) {
        (true, true) => return Ordering::Equal,
        (true, false) => return Ordering::Greater,
        (false, true) => return Ordering::Less,
        (false, false) => {}
    }
    for (left, right) in left.iter().zip(right.iter()) {
        let ordering = match (left, right) {
            (PrereleaseIdentifier::Numeric(left), PrereleaseIdentifier::Numeric(right)) => {
                left.cmp(right)
            }
            (PrereleaseIdentifier::Numeric(_), PrereleaseIdentifier::Text(_)) => Ordering::Less,
            (PrereleaseIdentifier::Text(_), PrereleaseIdentifier::Numeric(_)) => Ordering::Greater,
            (PrereleaseIdentifier::Text(left), PrereleaseIdentifier::Text(right)) => {
                left.cmp(right)
            }
        };
        if ordering != Ordering::Equal {
            return ordering;
        }
    }
    left.len().cmp(&right.len())
}

fn compare_build_identifiers(left: &[String], right: &[String]) -> Ordering {
    for (left, right) in left.iter().zip(right.iter()) {
        let ordering = compare_identifier_strings(left, right);
        if ordering != Ordering::Equal {
            return ordering;
        }
    }
    left.len().cmp(&right.len())
}

pub(crate) fn compare_build_versions(left: &Version, right: &Version) -> Ordering {
    left.cmp(right)
        .then_with(|| compare_build_identifiers(&left.build, &right.build))
}

pub(crate) fn compare_identifier_strings(left: &str, right: &str) -> Ordering {
    let left_num = parse_identifier_number(left);
    let right_num = parse_identifier_number(right);
    match (left_num, right_num) {
        (Some(left), Some(right)) => left.cmp(&right),
        (Some(_), None) => Ordering::Less,
        (None, Some(_)) => Ordering::Greater,
        (None, None) => left.cmp(right),
    }
}

fn parse_identifier_number(value: &str) -> Option<u64> {
    if value.is_empty() || !value.chars().all(|c| c.is_ascii_digit()) {
        return None;
    }
    value.parse::<u64>().ok()
}
