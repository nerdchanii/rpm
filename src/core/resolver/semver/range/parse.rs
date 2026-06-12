use crate::core::resolver::semver::{RangeOptions, SemverError};

use super::desugar::{is_wildcard, normalize_comparator_tokens, parse_hyphen_range, parse_token};
use super::{ComparatorSet, Range};

pub(crate) fn parse_range(input: &str, options: RangeOptions) -> Result<Range, SemverError> {
    let input = input.trim();
    if input.is_empty() {
        return Ok(any_range());
    }
    let mut sets = Vec::new();
    for raw_set in input.split("||") {
        let raw_set = raw_set.trim();
        if raw_set.is_empty() {
            sets.push(ComparatorSet {
                comparators: Vec::new(),
            });
            continue;
        }
        sets.push(parse_comparator_set(raw_set, input, options)?);
    }
    Ok(Range { sets })
}

fn any_range() -> Range {
    Range {
        sets: vec![ComparatorSet {
            comparators: Vec::new(),
        }],
    }
}

fn parse_comparator_set(
    raw_set: &str,
    full_input: &str,
    options: RangeOptions,
) -> Result<ComparatorSet, SemverError> {
    if is_wildcard(raw_set) {
        return Ok(ComparatorSet {
            comparators: Vec::new(),
        });
    }
    if let Some(comparators) = parse_hyphen_range(raw_set, full_input, options)? {
        return Ok(ComparatorSet { comparators });
    }
    let mut comparators = Vec::new();
    for token in normalize_comparator_tokens(raw_set, full_input)? {
        for comparator in parse_token(&token, full_input, options)? {
            if !comparators.contains(&comparator) {
                comparators.push(comparator);
            }
        }
    }
    Ok(ComparatorSet { comparators })
}
