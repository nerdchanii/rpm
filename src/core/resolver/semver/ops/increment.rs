use crate::core::resolver::semver::version::increment::{increment_version, truncate_version};
use crate::core::resolver::semver::version::Version;
use crate::core::resolver::semver::VersionOptions;

pub fn inc(version: &str, release_type: &str) -> Option<String> {
    inc_with_options(version, release_type, VersionOptions::default())
}

pub fn inc_with_options(
    version: &str,
    release_type: &str,
    options: VersionOptions,
) -> Option<String> {
    let version = Version::parse_with_options(version, options).ok()?;
    increment_version(version, release_type, None, Some(0))
}

pub fn inc_with_identifier(version: &str, release_type: &str, identifier: &str) -> Option<String> {
    inc_with_identifier_options(version, release_type, identifier, VersionOptions::default())
}

pub fn inc_with_identifier_options(
    version: &str,
    release_type: &str,
    identifier: &str,
    options: VersionOptions,
) -> Option<String> {
    let version = Version::parse_with_options(version, options).ok()?;
    increment_version(version, release_type, Some(identifier), Some(0))
}

pub fn inc_with_identifier_base(
    version: &str,
    release_type: &str,
    identifier: &str,
    identifier_base: Option<u64>,
) -> Option<String> {
    inc_with_identifier_base_options(
        version,
        release_type,
        identifier,
        identifier_base,
        VersionOptions::default(),
    )
}

pub fn inc_with_identifier_base_options(
    version: &str,
    release_type: &str,
    identifier: &str,
    identifier_base: Option<u64>,
    options: VersionOptions,
) -> Option<String> {
    let version = Version::parse_with_options(version, options).ok()?;
    increment_version(version, release_type, Some(identifier), identifier_base)
}

pub fn truncate(version: &str, release_type: &str) -> Option<String> {
    let version = version.parse::<Version>().ok()?;
    truncate_version(version, release_type)
}
