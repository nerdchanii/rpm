#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
/// Options for coercing a version from arbitrary text.
pub struct CoerceOptions {
    /// Search from right to left instead of left to right.
    pub rtl: bool,
    /// Preserve prerelease metadata when coercing.
    pub include_prerelease: bool,
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
/// Options for parsing and evaluating ranges.
pub struct RangeOptions {
    /// Include prerelease versions when evaluating ranges.
    pub include_prerelease: bool,
    /// Accept npm loose-mode range syntax where supported.
    pub loose: bool,
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
/// Options for parsing versions.
pub struct VersionOptions {
    /// Accept npm loose-mode version syntax where supported.
    pub loose: bool,
}

pub(crate) fn version_options_from_range(options: RangeOptions) -> VersionOptions {
    VersionOptions {
        loose: options.loose,
    }
}
