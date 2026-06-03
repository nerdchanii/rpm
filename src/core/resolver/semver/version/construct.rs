use std::{cmp::Ordering, str::FromStr};

use crate::core::resolver::semver::{SemverError, VersionOptions};

use super::{parse, PrereleaseIdentifier, Version};

impl Version {
    /// Parses a semantic version with explicit options.
    ///
    /// # Errors
    ///
    /// Returns [`SemverError::InvalidVersion`] when `input` is not accepted by
    /// the configured version parser.
    pub fn parse_with_options(input: &str, options: VersionOptions) -> Result<Self, SemverError> {
        parse::parse_version(input, options)
    }

    pub(crate) fn plain(major: u64, minor: u64, patch: u64) -> Self {
        Self {
            major,
            minor,
            patch,
            prerelease: Vec::new(),
            build: Vec::new(),
        }
    }

    pub(crate) fn compare_main(&self, other: &Self) -> Ordering {
        self.major
            .cmp(&other.major)
            .then_with(|| self.minor.cmp(&other.minor))
            .then_with(|| self.patch.cmp(&other.patch))
    }

    pub(crate) fn has_same_main_version(&self, other: &Self) -> bool {
        self.major == other.major && self.minor == other.minor && self.patch == other.patch
    }

    pub(crate) fn next_patch(&self) -> Self {
        let mut version = self.clone();
        version.patch += 1;
        version.prerelease.clear();
        version.build.clear();
        version
    }

    pub(crate) fn next_prerelease(&self) -> Self {
        let mut version = self.clone();
        version.prerelease.push(PrereleaseIdentifier::Numeric(0));
        version.build.clear();
        version
    }
}

impl Default for Version {
    fn default() -> Self {
        Self::plain(0, 0, 0)
    }
}

impl FromStr for Version {
    type Err = SemverError;

    fn from_str(input: &str) -> Result<Self, Self::Err> {
        Self::parse_with_options(input, VersionOptions::default())
    }
}
