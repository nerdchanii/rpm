use super::parse::parse_prerelease;
use super::{PrereleaseIdentifier, Version, MAX_SAFE_COMPONENT};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum PrereleaseBase {
    Number(u64),
    Omit,
}

pub(crate) fn increment_version(
    mut version: Version,
    release_type: &str,
    identifier: Option<&str>,
    identifier_base: Option<u64>,
) -> Option<String> {
    version.build.clear();
    let identifier_base = identifier_base.map_or(PrereleaseBase::Omit, PrereleaseBase::Number);
    match release_type {
        "major" => {
            if version.minor != 0 || version.patch != 0 || version.prerelease.is_empty() {
                version.major = increment_component(version.major)?;
            }
            version.minor = 0;
            version.patch = 0;
            version.prerelease.clear();
        }
        "minor" => {
            if version.patch != 0 || version.prerelease.is_empty() {
                version.minor = increment_component(version.minor)?;
            }
            version.patch = 0;
            version.prerelease.clear();
        }
        "patch" => {
            if version.prerelease.is_empty() {
                version.patch = increment_component(version.patch)?;
            }
            version.prerelease.clear();
        }
        "premajor" => {
            version.major = increment_component(version.major)?;
            version.minor = 0;
            version.patch = 0;
            version.prerelease = initial_prerelease(identifier, identifier_base)?;
        }
        "preminor" => {
            version.minor = increment_component(version.minor)?;
            version.patch = 0;
            version.prerelease = initial_prerelease(identifier, identifier_base)?;
        }
        "prepatch" => {
            version.patch = increment_component(version.patch)?;
            version.prerelease = initial_prerelease(identifier, identifier_base)?;
        }
        "prerelease" => {
            if version.prerelease.is_empty() {
                version.patch = increment_component(version.patch)?;
                version.prerelease = initial_prerelease(identifier, identifier_base)?;
            } else if let Some(identifier) = identifier {
                increment_prerelease_with_identifier(
                    &mut version.prerelease,
                    identifier,
                    identifier_base,
                )?;
            } else {
                increment_prerelease(&mut version.prerelease)?;
            }
        }
        "release" => {
            if version.prerelease.is_empty() {
                return None;
            }
            version.prerelease.clear();
        }
        "pre" => {
            if let Some(identifier) = identifier {
                increment_prerelease_with_identifier(
                    &mut version.prerelease,
                    identifier,
                    identifier_base,
                )?;
            } else {
                increment_prerelease(&mut version.prerelease)?;
            }
        }
        _ => return None,
    }
    Some(version.to_string())
}

pub(crate) fn truncate_version(mut version: Version, release_type: &str) -> Option<String> {
    version.build.clear();
    match release_type {
        "prerelease" | "prepatch" | "preminor" | "premajor" => {}
        "patch" => version.prerelease.clear(),
        "minor" => {
            version.patch = 0;
            version.prerelease.clear();
        }
        "major" => {
            version.minor = 0;
            version.patch = 0;
            version.prerelease.clear();
        }
        _ => return None,
    }
    Some(version.to_string())
}

fn increment_component(component: u64) -> Option<u64> {
    let next = component.checked_add(1)?;
    if next > MAX_SAFE_COMPONENT {
        return None;
    }
    Some(next)
}

fn increment_prerelease(prerelease: &mut Vec<PrereleaseIdentifier>) -> Option<()> {
    for identifier in prerelease.iter_mut().rev() {
        if let PrereleaseIdentifier::Numeric(value) = identifier {
            *value = increment_component(*value)?;
            return Some(());
        }
    }
    prerelease.push(PrereleaseIdentifier::Numeric(0));
    Some(())
}

fn increment_prerelease_with_identifier(
    prerelease: &mut Vec<PrereleaseIdentifier>,
    identifier: &str,
    identifier_base: PrereleaseBase,
) -> Option<()> {
    let identifier = parse_identifier_components(identifier)?;
    if identifier.is_empty() {
        match identifier_base {
            PrereleaseBase::Number(value) => {
                prerelease.push(PrereleaseIdentifier::Numeric(value));
                return Some(());
            }
            PrereleaseBase::Omit => return None,
        }
    }

    if prerelease.starts_with(&identifier) {
        let suffix_has_numeric = prerelease[identifier.len()..]
            .iter()
            .any(|part| matches!(part, PrereleaseIdentifier::Numeric(_)));
        match (suffix_has_numeric, identifier_base) {
            (true, _) => increment_prerelease(prerelease),
            (false, PrereleaseBase::Number(value)) => {
                *prerelease = identifier;
                prerelease.push(PrereleaseIdentifier::Numeric(value));
                Some(())
            }
            (false, PrereleaseBase::Omit) => {
                if prerelease.len() == identifier.len() {
                    None
                } else {
                    *prerelease = identifier;
                    Some(())
                }
            }
        }
    } else {
        *prerelease = initial_prerelease_from_parts(identifier, identifier_base)?;
        Some(())
    }
}

fn initial_prerelease(
    identifier: Option<&str>,
    identifier_base: PrereleaseBase,
) -> Option<Vec<PrereleaseIdentifier>> {
    let Some(identifier) = identifier else {
        return Some(vec![PrereleaseIdentifier::Numeric(0)]);
    };
    let identifier = parse_identifier_components(identifier)?;
    initial_prerelease_from_parts(identifier, identifier_base)
}

fn initial_prerelease_from_parts(
    mut identifier: Vec<PrereleaseIdentifier>,
    identifier_base: PrereleaseBase,
) -> Option<Vec<PrereleaseIdentifier>> {
    match identifier_base {
        PrereleaseBase::Number(value) => {
            identifier.push(PrereleaseIdentifier::Numeric(value));
            Some(identifier)
        }
        PrereleaseBase::Omit if identifier.is_empty() => None,
        PrereleaseBase::Omit => Some(identifier),
    }
}

fn parse_identifier_components(identifier: &str) -> Option<Vec<PrereleaseIdentifier>> {
    if identifier.is_empty() {
        return Some(Vec::new());
    }
    parse_prerelease(Some(identifier), identifier).ok()
}
