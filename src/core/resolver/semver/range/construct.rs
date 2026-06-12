use std::str::FromStr;

use crate::core::resolver::semver::{RangeOptions, SemverError};

use super::{parse, Range};

impl Range {
    /// Parses a semantic version range with explicit options.
    ///
    /// # Errors
    ///
    /// Returns [`SemverError::InvalidRange`] when `input` is not accepted by
    /// the configured range parser.
    pub fn parse_with_options(input: &str, options: RangeOptions) -> Result<Self, SemverError> {
        parse::parse_range(input, options)
    }
}

impl FromStr for Range {
    type Err = SemverError;

    fn from_str(input: &str) -> Result<Self, Self::Err> {
        Self::parse_with_options(input, RangeOptions::default())
    }
}
