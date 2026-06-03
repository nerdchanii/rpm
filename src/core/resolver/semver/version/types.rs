pub(crate) const MAX_VERSION_LENGTH: usize = 256;
pub(crate) const MAX_SAFE_COMPONENT: u64 = 9_007_199_254_740_991;

#[derive(Debug, Clone, Eq)]
/// A parsed semantic version.
///
/// Ordering follows npm-compatible semver precedence. Build metadata is
/// preserved for display but ignored by normal precedence comparisons.
pub struct Version {
    pub(crate) major: u64,
    pub(crate) minor: u64,
    pub(crate) patch: u64,
    pub(crate) prerelease: Vec<PrereleaseIdentifier>,
    pub(crate) build: Vec<String>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum PrereleaseIdentifier {
    Numeric(u64),
    Text(String),
}
