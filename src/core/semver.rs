use std::{borrow::Cow, cmp::Ordering, fmt};

use thiserror::Error;

#[derive(Debug, Error, Clone, PartialEq, Eq)]
pub enum SemverError {
    #[error("invalid version {0}")]
    InvalidVersion(String),
    #[error("invalid range {0}")]
    InvalidRange(String),
    #[error("invalid operator {0}")]
    InvalidOperator(String),
    #[error("unsatisfied range {range}")]
    UnsatisfiedRange { range: String },
}

const MAX_VERSION_LENGTH: usize = 256;
const MAX_SAFE_COMPONENT: u64 = 9_007_199_254_740_991;

#[derive(Debug, Clone, Eq)]
pub struct Version {
    major: u64,
    minor: u64,
    patch: u64,
    prerelease: Vec<PrereleaseIdentifier>,
    build: Vec<String>,
}

impl PartialEq for Version {
    fn eq(&self, other: &Self) -> bool {
        self.cmp(other) == Ordering::Equal
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
enum PrereleaseIdentifier {
    Numeric(u64),
    Text(String),
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Range {
    sets: Vec<ComparatorSet>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct ComparatorSet {
    comparators: Vec<Comparator>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct Comparator {
    op: ComparatorOp,
    version: Version,
    include_zero_suffix: bool,
    include_prerelease_floor: bool,
    include_prerelease_upper_bound: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum ComparatorOp {
    Exact,
    GreaterThan,
    GreaterThanOrEqual,
    LessThan,
    LessThanOrEqual,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum PrereleaseBase {
    Number(u64),
    Omit,
}

#[derive(Debug, Clone)]
struct CoerceCandidate {
    version: Version,
    end: usize,
    components: usize,
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct CoerceOptions {
    pub rtl: bool,
    pub include_prerelease: bool,
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct RangeOptions {
    pub include_prerelease: bool,
    pub loose: bool,
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct VersionOptions {
    pub loose: bool,
}

impl CoerceCandidate {
    fn is_better_rtl_than(&self, other: &Self) -> bool {
        self.end > other.end || (self.end == other.end && self.components > other.components)
    }
}

impl Version {
    pub fn parse(input: &str) -> Result<Self, SemverError> {
        Self::parse_with_options(input, VersionOptions::default())
    }

    pub fn parse_with_options(input: &str, options: VersionOptions) -> Result<Self, SemverError> {
        let input = input.trim();
        if input.len() > MAX_VERSION_LENGTH {
            return Err(SemverError::InvalidVersion(input.to_string()));
        }
        let normalized = normalize_version_input(input, options);
        let input = normalized.as_ref();
        let (core, build) = input
            .split_once('+')
            .map_or((input, None), |(core, build)| (core, Some(build)));
        let build = build.map_or(Ok(Vec::new()), |build| parse_build(build, input))?;
        let (numbers, prerelease) = core
            .split_once('-')
            .map_or((core, None), |(numbers, prerelease)| {
                (numbers, Some(prerelease))
            });
        let [major, minor, patch] = parse_exact_numeric_parts(numbers, input)?;
        let prerelease = parse_prerelease(prerelease, input)?;
        Ok(Self {
            major,
            minor,
            patch,
            prerelease,
            build,
        })
    }
}

impl fmt::Display for Version {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(formatter, "{}.{}.{}", self.major, self.minor, self.patch)?;
        if !self.prerelease.is_empty() {
            write!(formatter, "-")?;
            for (index, identifier) in self.prerelease.iter().enumerate() {
                if index > 0 {
                    write!(formatter, ".")?;
                }
                write!(formatter, "{identifier}")?;
            }
        }
        if !self.build.is_empty() {
            write!(formatter, "+{}", self.build.join("."))?;
        }
        Ok(())
    }
}

impl fmt::Display for PrereleaseIdentifier {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Numeric(value) => write!(formatter, "{value}"),
            Self::Text(value) => formatter.write_str(value),
        }
    }
}

impl Ord for Version {
    fn cmp(&self, other: &Self) -> Ordering {
        self.major
            .cmp(&other.major)
            .then_with(|| self.minor.cmp(&other.minor))
            .then_with(|| self.patch.cmp(&other.patch))
            .then_with(|| compare_prerelease(&self.prerelease, &other.prerelease))
    }
}

impl PartialOrd for Version {
    fn partial_cmp(&self, other: &Self) -> Option<Ordering> {
        Some(self.cmp(other))
    }
}

impl Range {
    pub fn parse(input: &str) -> Result<Self, SemverError> {
        Self::parse_with_options(input, RangeOptions::default())
    }

    pub fn parse_with_options(input: &str, options: RangeOptions) -> Result<Self, SemverError> {
        let input = input.trim();
        if input.is_empty() || input == "latest" {
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
        Ok(Self { sets })
    }

    pub fn satisfies(&self, version: &Version) -> bool {
        self.satisfies_with_options(version, RangeOptions::default())
    }

    pub fn satisfies_with_options(&self, version: &Version, options: RangeOptions) -> bool {
        self.sets.iter().any(|set| {
            set.satisfies(version, options)
                && (options.include_prerelease || set.allows_prerelease(version))
        })
    }
}

impl ComparatorSet {
    fn satisfies(&self, version: &Version, options: RangeOptions) -> bool {
        self.comparators
            .iter()
            .all(|comparator| comparator.matches(version, options))
    }

    fn allows_prerelease(&self, version: &Version) -> bool {
        version.prerelease.is_empty()
            || self.comparators.iter().any(|comparator| {
                !comparator.version.prerelease.is_empty()
                    && comparator.version.has_same_main_version(version)
            })
    }
}

impl Comparator {
    fn matches(&self, version: &Version, options: RangeOptions) -> bool {
        if self.include_prerelease_floor
            && options.include_prerelease
            && self.op == ComparatorOp::GreaterThanOrEqual
            && !version.prerelease.is_empty()
            && self.version.has_same_main_version(version)
        {
            return version >= &self.version.next_prerelease();
        }
        let comparison_version;
        let comparator_version = if self.include_zero_suffix {
            comparison_version = self.version.next_prerelease();
            &comparison_version
        } else {
            &self.version
        };
        match self.op {
            ComparatorOp::Exact => version == comparator_version,
            ComparatorOp::GreaterThan => version > comparator_version,
            ComparatorOp::GreaterThanOrEqual => version >= comparator_version,
            ComparatorOp::LessThan => version < comparator_version,
            ComparatorOp::LessThanOrEqual => version <= comparator_version,
        }
    }

    fn interval_bound_version(&self) -> Version {
        if self.include_zero_suffix {
            self.version.next_prerelease()
        } else {
            self.version.clone()
        }
    }

    fn to_comparator_string(&self) -> String {
        self.to_comparator_string_with_options(RangeOptions::default())
    }

    fn to_comparator_string_with_options(&self, options: RangeOptions) -> String {
        let version = if self.include_prerelease_upper_bound && options.include_prerelease {
            self.version.next_patch().next_prerelease().to_string()
        } else if self.include_zero_suffix
            || (self.include_prerelease_floor
                && options.include_prerelease
                && self.op == ComparatorOp::GreaterThanOrEqual
                && self.version.prerelease.is_empty())
        {
            self.version.next_prerelease().to_string()
        } else {
            self.version.to_string()
        };
        let op = if self.include_prerelease_upper_bound && options.include_prerelease {
            ComparatorOp::LessThan
        } else {
            self.op
        };
        match op {
            ComparatorOp::Exact => version,
            ComparatorOp::GreaterThan => format!(">{version}"),
            ComparatorOp::GreaterThanOrEqual => format!(">={version}"),
            ComparatorOp::LessThan => format!("<{version}"),
            ComparatorOp::LessThanOrEqual => format!("<={version}"),
        }
    }
}

pub fn satisfies(version: &str, range: &str) -> Result<bool, SemverError> {
    let version = Version::parse(version)?;
    let range = Range::parse(range)?;
    Ok(range.satisfies(&version))
}

pub fn satisfies_with_options(
    version: &str,
    range: &str,
    options: RangeOptions,
) -> Result<bool, SemverError> {
    let version = Version::parse_with_options(version, version_options_from_range(options))?;
    let range = Range::parse_with_options(range, options)?;
    Ok(range.satisfies_with_options(&version, options))
}

pub fn valid(version: &str) -> Option<String> {
    valid_with_options(version, VersionOptions::default())
}

pub fn valid_with_options(version: &str, options: VersionOptions) -> Option<String> {
    Version::parse_with_options(version, options)
        .ok()
        .map(|version| version.to_string())
}

pub fn clean(version: &str) -> Option<String> {
    clean_with_options(version, VersionOptions::default())
}

pub fn clean_with_options(version: &str, options: VersionOptions) -> Option<String> {
    let version = version.trim();
    valid_with_options(version, options)
        .map(strip_build_metadata)
        .or_else(|| {
            let cleaned = version.strip_prefix('=').unwrap_or(version).trim_start();
            let cleaned = cleaned.strip_prefix('v').unwrap_or(cleaned);
            valid_with_options(cleaned, options).map(strip_build_metadata)
        })
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

pub fn inc(version: &str, release_type: &str) -> Option<String> {
    inc_with_options(version, release_type, VersionOptions::default())
}

pub fn inc_with_options(
    version: &str,
    release_type: &str,
    options: VersionOptions,
) -> Option<String> {
    inc_internal(
        version,
        release_type,
        None,
        PrereleaseBase::Number(0),
        options,
    )
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
    inc_internal(
        version,
        release_type,
        Some(identifier),
        PrereleaseBase::Number(0),
        options,
    )
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
    inc_internal(
        version,
        release_type,
        Some(identifier),
        identifier_base.map_or(PrereleaseBase::Omit, PrereleaseBase::Number),
        options,
    )
}

fn inc_internal(
    version: &str,
    release_type: &str,
    identifier: Option<&str>,
    identifier_base: PrereleaseBase,
    options: VersionOptions,
) -> Option<String> {
    let mut version = Version::parse_with_options(version, options).ok()?;
    version.build.clear();
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

pub fn compare(left: &str, right: &str) -> Result<Ordering, SemverError> {
    compare_with_options(left, right, VersionOptions::default())
}

pub fn compare_with_options(
    left: &str,
    right: &str,
    options: VersionOptions,
) -> Result<Ordering, SemverError> {
    Ok(Version::parse_with_options(left, options)?
        .cmp(&Version::parse_with_options(right, options)?))
}

pub fn compare_loose(left: &str, right: &str) -> Result<Ordering, SemverError> {
    compare_with_options(left, right, VersionOptions { loose: true })
}

pub fn rcompare(left: &str, right: &str) -> Result<Ordering, SemverError> {
    compare(right, left)
}

pub fn compare_build(left: &str, right: &str) -> Result<Ordering, SemverError> {
    let left = Version::parse(left)?;
    let right = Version::parse(right)?;
    Ok(compare_build_versions(&left, &right))
}

pub fn compare_identifiers(left: &str, right: &str) -> Ordering {
    compare_identifier_strings(left, right)
}

pub fn rcompare_identifiers(left: &str, right: &str) -> Ordering {
    compare_identifiers(right, left)
}

pub fn eq(left: &str, right: &str) -> Result<bool, SemverError> {
    eq_with_options(left, right, VersionOptions::default())
}

pub fn eq_with_options(
    left: &str,
    right: &str,
    options: VersionOptions,
) -> Result<bool, SemverError> {
    Ok(compare_with_options(left, right, options)? == Ordering::Equal)
}

pub fn neq(left: &str, right: &str) -> Result<bool, SemverError> {
    neq_with_options(left, right, VersionOptions::default())
}

pub fn neq_with_options(
    left: &str,
    right: &str,
    options: VersionOptions,
) -> Result<bool, SemverError> {
    Ok(!eq_with_options(left, right, options)?)
}

pub fn gt(left: &str, right: &str) -> Result<bool, SemverError> {
    gt_with_options(left, right, VersionOptions::default())
}

pub fn gt_with_options(
    left: &str,
    right: &str,
    options: VersionOptions,
) -> Result<bool, SemverError> {
    Ok(compare_with_options(left, right, options)? == Ordering::Greater)
}

pub fn gte(left: &str, right: &str) -> Result<bool, SemverError> {
    gte_with_options(left, right, VersionOptions::default())
}

pub fn gte_with_options(
    left: &str,
    right: &str,
    options: VersionOptions,
) -> Result<bool, SemverError> {
    Ok(matches!(
        compare_with_options(left, right, options)?,
        Ordering::Greater | Ordering::Equal
    ))
}

pub fn lt(left: &str, right: &str) -> Result<bool, SemverError> {
    lt_with_options(left, right, VersionOptions::default())
}

pub fn lt_with_options(
    left: &str,
    right: &str,
    options: VersionOptions,
) -> Result<bool, SemverError> {
    Ok(compare_with_options(left, right, options)? == Ordering::Less)
}

pub fn lte(left: &str, right: &str) -> Result<bool, SemverError> {
    lte_with_options(left, right, VersionOptions::default())
}

pub fn lte_with_options(
    left: &str,
    right: &str,
    options: VersionOptions,
) -> Result<bool, SemverError> {
    Ok(matches!(
        compare_with_options(left, right, options)?,
        Ordering::Less | Ordering::Equal
    ))
}

pub fn cmp(left: &str, op: &str, right: &str) -> Result<bool, SemverError> {
    cmp_with_options(left, op, right, VersionOptions::default())
}

pub fn cmp_with_options(
    left: &str,
    op: &str,
    right: &str,
    options: VersionOptions,
) -> Result<bool, SemverError> {
    match op {
        "===" => Ok(left == right),
        "!==" => Ok(left != right),
        "" | "=" | "==" => eq_with_options(left, right, options),
        "!=" => neq_with_options(left, right, options),
        ">" => gt_with_options(left, right, options),
        ">=" => gte_with_options(left, right, options),
        "<" => lt_with_options(left, right, options),
        "<=" => lte_with_options(left, right, options),
        _ => Err(SemverError::InvalidOperator(op.to_string())),
    }
}

pub fn major(version: &str) -> Result<u64, SemverError> {
    major_with_options(version, VersionOptions::default())
}

pub fn major_with_options(version: &str, options: VersionOptions) -> Result<u64, SemverError> {
    Ok(Version::parse_with_options(version, options)?.major)
}

pub fn minor(version: &str) -> Result<u64, SemverError> {
    minor_with_options(version, VersionOptions::default())
}

pub fn minor_with_options(version: &str, options: VersionOptions) -> Result<u64, SemverError> {
    Ok(Version::parse_with_options(version, options)?.minor)
}

pub fn patch(version: &str) -> Result<u64, SemverError> {
    patch_with_options(version, VersionOptions::default())
}

pub fn patch_with_options(version: &str, options: VersionOptions) -> Result<u64, SemverError> {
    Ok(Version::parse_with_options(version, options)?.patch)
}

pub fn prerelease(version: &str) -> Result<Option<Vec<String>>, SemverError> {
    prerelease_with_options(version, VersionOptions::default())
}

pub fn prerelease_with_options(
    version: &str,
    options: VersionOptions,
) -> Result<Option<Vec<String>>, SemverError> {
    let prerelease = Version::parse_with_options(version, options)?.prerelease;
    if prerelease.is_empty() {
        Ok(None)
    } else {
        Ok(Some(
            prerelease
                .into_iter()
                .map(|identifier| identifier.to_string())
                .collect(),
        ))
    }
}

pub fn diff(left: &str, right: &str) -> Result<Option<&'static str>, SemverError> {
    let left = Version::parse(left)?;
    let right = Version::parse(right)?;
    let comparison = left.cmp(&right);
    if comparison == Ordering::Equal {
        return Ok(None);
    }

    let (high, low) = if comparison == Ordering::Greater {
        (&left, &right)
    } else {
        (&right, &left)
    };
    let high_has_pre = !high.prerelease.is_empty();
    let low_has_pre = !low.prerelease.is_empty();

    if low_has_pre && !high_has_pre {
        if low.minor == 0 && low.patch == 0 {
            return Ok(Some("major"));
        }
        if low.compare_main(high) == Ordering::Equal {
            if low.minor > 0 && low.patch == 0 {
                return Ok(Some("minor"));
            }
            return Ok(Some("patch"));
        }
    }

    let prefix = if high_has_pre { "pre" } else { "" };
    if left.major != right.major {
        return Ok(Some(if prefix.is_empty() {
            "major"
        } else {
            "premajor"
        }));
    }
    if left.minor != right.minor {
        return Ok(Some(if prefix.is_empty() {
            "minor"
        } else {
            "preminor"
        }));
    }
    if left.patch != right.patch {
        return Ok(Some(if prefix.is_empty() {
            "patch"
        } else {
            "prepatch"
        }));
    }
    Ok(Some("prerelease"))
}

pub fn truncate(version: &str, release_type: &str) -> Option<String> {
    let mut version = Version::parse(version).ok()?;
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

pub fn to_comparators(range: &str) -> Result<Vec<Vec<String>>, SemverError> {
    let range = Range::parse(range)?;
    if range.sets.iter().any(|set| set.comparators.is_empty()) {
        return Ok(vec![vec![String::new()]]);
    }

    let sets: Vec<&ComparatorSet> = if range.sets.len() == 1 {
        range.sets.iter().collect()
    } else {
        let satisfiable_sets: Vec<&ComparatorSet> = range
            .sets
            .iter()
            .filter(|set| !set_is_null_for_to_comparators(set))
            .collect();
        if satisfiable_sets.is_empty() {
            return Ok(vec![vec!["<0.0.0-0".to_string()]]);
        }
        satisfiable_sets
    };

    Ok(sets
        .into_iter()
        .map(|set| {
            set.comparators
                .iter()
                .map(Comparator::to_comparator_string)
                .collect()
        })
        .collect())
}

fn set_is_null_for_to_comparators(set: &ComparatorSet) -> bool {
    let Some(interval) = interval_for_set(set) else {
        return true;
    };
    let Some(upper) = interval.upper else {
        return false;
    };
    let semver_floor = Version {
        major: 0,
        minor: 0,
        patch: 0,
        prerelease: vec![PrereleaseIdentifier::Numeric(0)],
        build: Vec::new(),
    };
    let stable_floor = Version::plain(0, 0, 0);
    upper.version < semver_floor
        || (upper.version == semver_floor && !upper.inclusive)
        || (upper.version == stable_floor && !upper.inclusive)
}

pub fn valid_range(range: &str) -> Option<String> {
    Range::parse(range).ok().map(|range| range.normalized())
}

pub fn valid_range_with_options(range: &str, options: RangeOptions) -> Option<String> {
    Range::parse_with_options(range, options)
        .ok()
        .map(|range| range.normalized_with_options(options))
}

pub fn intersects(left: &str, right: &str) -> Result<bool, SemverError> {
    let left = Range::parse(left)?;
    let right = Range::parse(right)?;
    Ok(left.intersects(&right))
}

pub fn subset(sub: &str, dom: &str) -> Result<bool, SemverError> {
    subset_with_options(sub, dom, RangeOptions::default())
}

pub fn subset_with_options(
    sub: &str,
    dom: &str,
    options: RangeOptions,
) -> Result<bool, SemverError> {
    let sub = Range::parse_with_options(sub, options)?;
    let dom = Range::parse_with_options(dom, options)?;
    Ok(sub.subset_of(&dom, options))
}

pub fn outside(version: &str, range: &str, hilo: &str) -> Result<bool, SemverError> {
    outside_with_options(version, range, hilo, RangeOptions::default())
}

pub fn outside_with_options(
    version: &str,
    range: &str,
    hilo: &str,
    options: RangeOptions,
) -> Result<bool, SemverError> {
    let direction = match hilo {
        ">" => OutsideDirection::GreaterThan,
        "<" => OutsideDirection::LessThan,
        _ => return Err(SemverError::InvalidRange(hilo.to_string())),
    };
    let version = Version::parse_with_options(version, version_options_from_range(options))?;
    let range = Range::parse_with_options(range, options)?;
    Ok(range.outside(&version, direction))
}

pub fn gtr(version: &str, range: &str) -> Result<bool, SemverError> {
    outside(version, range, ">")
}

pub fn gtr_with_options(
    version: &str,
    range: &str,
    options: RangeOptions,
) -> Result<bool, SemverError> {
    outside_with_options(version, range, ">", options)
}

pub fn ltr(version: &str, range: &str) -> Result<bool, SemverError> {
    outside(version, range, "<")
}

pub fn ltr_with_options(
    version: &str,
    range: &str,
    options: RangeOptions,
) -> Result<bool, SemverError> {
    outside_with_options(version, range, "<", options)
}

pub fn min_version(range: &str) -> Result<Option<String>, SemverError> {
    let range = Range::parse(range)?;
    for candidate in ["0.0.0", "0.0.0-0"] {
        let version = Version::parse(candidate)?;
        if range.satisfies(&version) {
            return Ok(Some(version.to_string()));
        }
    }

    let mut selected: Option<Version> = None;
    for set in &range.sets {
        let Some(mut candidate) = min_version_for_set(set) else {
            continue;
        };
        if !range.satisfies(&candidate) {
            continue;
        }
        if selected
            .as_ref()
            .is_none_or(|selected| candidate < *selected)
        {
            selected = Some(std::mem::take(&mut candidate));
        }
    }
    Ok(selected.map(|version| version.to_string()))
}

pub fn sort<'a, I>(versions: I) -> Result<Vec<&'a str>, SemverError>
where
    I: IntoIterator<Item = &'a str>,
{
    sort_with_options(versions, VersionOptions::default())
}

pub fn sort_with_options<'a, I>(
    versions: I,
    options: VersionOptions,
) -> Result<Vec<&'a str>, SemverError>
where
    I: IntoIterator<Item = &'a str>,
{
    let mut parsed = parse_sort_versions_with_options(versions, options)?;
    parsed.sort_by(|(_, left), (_, right)| compare_build_versions(left, right));
    Ok(parsed.into_iter().map(|(raw, _)| raw).collect())
}

pub fn rsort<'a, I>(versions: I) -> Result<Vec<&'a str>, SemverError>
where
    I: IntoIterator<Item = &'a str>,
{
    rsort_with_options(versions, VersionOptions::default())
}

pub fn rsort_with_options<'a, I>(
    versions: I,
    options: VersionOptions,
) -> Result<Vec<&'a str>, SemverError>
where
    I: IntoIterator<Item = &'a str>,
{
    let mut parsed = parse_sort_versions_with_options(versions, options)?;
    parsed.sort_by(|(_, left), (_, right)| compare_build_versions(right, left));
    Ok(parsed.into_iter().map(|(raw, _)| raw).collect())
}

pub fn max_satisfying<'a, I>(versions: I, range: &str) -> Result<Option<&'a str>, SemverError>
where
    I: IntoIterator<Item = &'a str>,
{
    max_satisfying_with_options(versions, range, RangeOptions::default())
}

pub fn max_satisfying_with_options<'a, I>(
    versions: I,
    range: &str,
    options: RangeOptions,
) -> Result<Option<&'a str>, SemverError>
where
    I: IntoIterator<Item = &'a str>,
{
    let range = Range::parse_with_options(range, options)?;
    let mut selected: Option<(&'a str, Version)> = None;
    for raw_version in versions {
        let Ok(version) =
            Version::parse_with_options(raw_version, version_options_from_range(options))
        else {
            continue;
        };
        if !range.satisfies_with_options(&version, options) {
            continue;
        }
        match &selected {
            Some((_, selected_version)) if version <= *selected_version => {}
            _ => selected = Some((raw_version, version)),
        }
    }
    Ok(selected.map(|(raw_version, _)| raw_version))
}

pub fn min_satisfying<'a, I>(versions: I, range: &str) -> Result<Option<&'a str>, SemverError>
where
    I: IntoIterator<Item = &'a str>,
{
    min_satisfying_with_options(versions, range, RangeOptions::default())
}

pub fn min_satisfying_with_options<'a, I>(
    versions: I,
    range: &str,
    options: RangeOptions,
) -> Result<Option<&'a str>, SemverError>
where
    I: IntoIterator<Item = &'a str>,
{
    let range = Range::parse_with_options(range, options)?;
    let mut selected: Option<(&'a str, Version)> = None;
    for raw_version in versions {
        let Ok(version) =
            Version::parse_with_options(raw_version, version_options_from_range(options))
        else {
            continue;
        };
        if !range.satisfies_with_options(&version, options) {
            continue;
        }
        match &selected {
            Some((_, selected_version)) if version >= *selected_version => {}
            _ => selected = Some((raw_version, version)),
        }
    }
    Ok(selected.map(|(raw_version, _)| raw_version))
}

pub fn simplify_range<'a, I>(versions: I, range: &str) -> Result<String, SemverError>
where
    I: IntoIterator<Item = &'a str>,
{
    simplify_range_with_options(versions, range, RangeOptions::default())
}

pub fn simplify_range_with_options<'a, I>(
    versions: I,
    range: &str,
    options: RangeOptions,
) -> Result<String, SemverError>
where
    I: IntoIterator<Item = &'a str>,
{
    let original = range.trim();
    let range = Range::parse_with_options(range, options)?;
    let mut parsed =
        parse_sort_versions_with_options(versions, version_options_from_range(options))?;
    parsed.sort_by(|(_, left), (_, right)| left.cmp(right));
    if parsed.is_empty() {
        return Ok(String::new());
    }

    let first_available = parsed[0].0;
    let mut runs: Vec<(&str, Option<&str>)> = Vec::new();
    let mut first_in_run: Option<&str> = None;
    let mut previous_in_run: Option<&str> = None;

    for (raw, version) in &parsed {
        if range.satisfies_with_options(version, options) {
            previous_in_run = Some(raw);
            if first_in_run.is_none() {
                first_in_run = Some(raw);
            }
        } else if let (Some(first), Some(previous)) = (first_in_run, previous_in_run) {
            runs.push((first, Some(previous)));
            first_in_run = None;
            previous_in_run = None;
        }
    }
    if let Some(first) = first_in_run {
        runs.push((first, None));
    }

    let simplified = runs
        .into_iter()
        .map(|(min, max)| match max {
            Some(max) if min == max => min.to_string(),
            None if min == first_available => "*".to_string(),
            None => format!(">={min}"),
            Some(max) if min == first_available => format!("<={max}"),
            Some(max) => format!("{min} - {max}"),
        })
        .collect::<Vec<_>>()
        .join(" || ");

    if simplified.len() < original.len() {
        Ok(simplified)
    } else {
        Ok(original.to_string())
    }
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

fn normalize_comparator_tokens(
    raw_set: &str,
    full_input: &str,
) -> Result<Vec<String>, SemverError> {
    let mut normalized = Vec::new();
    let mut tokens = raw_set.split_whitespace().peekable();
    while let Some(token) = tokens.next() {
        if is_standalone_comparator_operator(token) || matches!(token, "^" | "~" | "~>") {
            let Some(version) = tokens.next() else {
                return Err(SemverError::InvalidRange(full_input.to_string()));
            };
            let operator = if token == "~>" { "~" } else { token };
            normalized.push(format!("{operator}{version}"));
        } else if let Some(rest) = token.strip_prefix("~>") {
            normalized.push(format!("~{rest}"));
        } else {
            normalized.push(token.to_string());
        }
    }
    Ok(normalized)
}

fn is_standalone_comparator_operator(token: &str) -> bool {
    matches!(token, ">" | ">=" | "<" | "<=" | "=")
}

fn parse_hyphen_range(
    raw_set: &str,
    full_input: &str,
    options: RangeOptions,
) -> Result<Option<Vec<Comparator>>, SemverError> {
    let Some((lower, upper)) = raw_set.split_once(" - ") else {
        return Ok(None);
    };
    if upper.contains(" - ") {
        return Err(SemverError::InvalidRange(full_input.to_string()));
    }

    let mut comparators = Vec::new();
    comparators.extend(hyphen_lower_bound(lower.trim(), full_input, options)?);
    comparators.extend(hyphen_upper_bound(upper.trim(), full_input, options)?);
    Ok(Some(comparators))
}

fn hyphen_lower_bound(
    version: &str,
    full_input: &str,
    options: RangeOptions,
) -> Result<Vec<Comparator>, SemverError> {
    if is_wildcard(version) {
        return Ok(Vec::new());
    }
    if contains_wildcard(version) {
        let Some((lower, _)) = wildcard_bounds(version, full_input)? else {
            return Ok(Vec::new());
        };
        return Ok(vec![Comparator {
            op: ComparatorOp::GreaterThanOrEqual,
            version: lower,
            include_zero_suffix: false,
            include_prerelease_floor: true,
            include_prerelease_upper_bound: false,
        }]);
    }
    Ok(vec![Comparator {
        op: ComparatorOp::GreaterThanOrEqual,
        version: complete_partial_version(version, full_input, options)?,
        include_zero_suffix: false,
        include_prerelease_floor: true,
        include_prerelease_upper_bound: false,
    }])
}

fn hyphen_upper_bound(
    version: &str,
    full_input: &str,
    options: RangeOptions,
) -> Result<Vec<Comparator>, SemverError> {
    if is_wildcard(version) {
        return Ok(Vec::new());
    }
    if contains_wildcard(version) {
        let Some((_, upper)) = wildcard_bounds(version, full_input)? else {
            return Ok(Vec::new());
        };
        return Ok(vec![Comparator {
            op: ComparatorOp::LessThan,
            version: upper,
            include_zero_suffix: true,
            include_prerelease_floor: false,
            include_prerelease_upper_bound: false,
        }]);
    }
    let upper = complete_partial_version(version, full_input, options)?;
    if is_partial_version(version) {
        let upper = match numeric_part_count(version) {
            1 => Version::plain(upper.major + 1, 0, 0),
            2 => Version::plain(upper.major, upper.minor + 1, 0),
            _ => upper,
        };
        return Ok(vec![Comparator {
            op: ComparatorOp::LessThan,
            version: upper,
            include_zero_suffix: true,
            include_prerelease_floor: false,
            include_prerelease_upper_bound: false,
        }]);
    }
    Ok(vec![Comparator {
        op: ComparatorOp::LessThanOrEqual,
        version: upper,
        include_zero_suffix: false,
        include_prerelease_floor: false,
        include_prerelease_upper_bound: true,
    }])
}

fn parse_token(
    token: &str,
    full_input: &str,
    options: RangeOptions,
) -> Result<Vec<Comparator>, SemverError> {
    if is_wildcard(token) {
        return Ok(Vec::new());
    }
    if let Some(rest) = token.strip_prefix('^') {
        return caret_range(rest, full_input, options);
    }
    if let Some(rest) = token.strip_prefix('~') {
        return tilde_range(rest, full_input, options);
    }
    let (op, version) = comparator_parts(token);
    if contains_wildcard(version) {
        return wildcard_range_with_op(op, version, full_input);
    }
    if is_partial_version(version) {
        return partial_range(op, version, full_input, options);
    }
    let version = parse_range_version(version, full_input, options)?;
    Ok(vec![Comparator {
        op,
        version,
        include_zero_suffix: false,
        include_prerelease_floor: false,
        include_prerelease_upper_bound: false,
    }])
}

fn comparator_parts(token: &str) -> (ComparatorOp, &str) {
    if let Some(rest) = token.strip_prefix(">=") {
        (ComparatorOp::GreaterThanOrEqual, rest)
    } else if let Some(rest) = token.strip_prefix("<=") {
        (ComparatorOp::LessThanOrEqual, rest)
    } else if let Some(rest) = token.strip_prefix('>') {
        (ComparatorOp::GreaterThan, rest)
    } else if let Some(rest) = token.strip_prefix('<') {
        (ComparatorOp::LessThan, rest)
    } else if let Some(rest) = token.strip_prefix('=') {
        (ComparatorOp::Exact, rest)
    } else {
        (ComparatorOp::Exact, token)
    }
}

fn caret_range(
    version: &str,
    full_input: &str,
    options: RangeOptions,
) -> Result<Vec<Comparator>, SemverError> {
    if is_wildcard(version) {
        return wildcard_range(version, full_input);
    }
    if contains_wildcard(version) {
        let Some((lower, _)) = wildcard_bounds(version, full_input)? else {
            return Ok(Vec::new());
        };
        let upper = if lower.major > 0 {
            Version::plain(lower.major + 1, 0, 0)
        } else if lower.minor > 0 {
            Version::plain(0, lower.minor + 1, 0)
        } else {
            Version::plain(1, 0, 0)
        };
        reject_oversized_version(&upper, full_input)?;
        return Ok(lower_upper_with_floor(lower, upper, true));
    }
    let lower = complete_partial_version(version, full_input, options)?;
    if numeric_part_count(version) == 1 && lower.major == 0 {
        return Ok(vec![Comparator {
            op: ComparatorOp::LessThan,
            version: Version::plain(1, 0, 0),
            include_zero_suffix: true,
            include_prerelease_floor: false,
            include_prerelease_upper_bound: false,
        }]);
    }
    let upper = if lower.major > 0 {
        Version::plain(lower.major + 1, 0, 0)
    } else if lower.minor > 0 {
        Version::plain(0, lower.minor + 1, 0)
    } else {
        Version::plain(0, 0, lower.patch + 1)
    };
    reject_oversized_version(&upper, full_input)?;
    Ok(lower_upper(lower, upper))
}

fn tilde_range(
    version: &str,
    full_input: &str,
    options: RangeOptions,
) -> Result<Vec<Comparator>, SemverError> {
    if contains_wildcard(version) || is_wildcard(version) {
        return wildcard_range(version, full_input);
    }
    let lower = complete_partial_version(version, full_input, options)?;
    let upper = match numeric_part_count(version) {
        0 | 1 => Version::plain(lower.major + 1, 0, 0),
        _ => Version::plain(lower.major, lower.minor + 1, 0),
    };
    Ok(lower_upper(lower, upper))
}

fn wildcard_range(version: &str, full_input: &str) -> Result<Vec<Comparator>, SemverError> {
    wildcard_range_with_op(ComparatorOp::Exact, version, full_input)
}

fn wildcard_range_with_op(
    op: ComparatorOp,
    version: &str,
    full_input: &str,
) -> Result<Vec<Comparator>, SemverError> {
    if is_wildcard(version) {
        return match op {
            ComparatorOp::Exact | ComparatorOp::GreaterThanOrEqual => Ok(Vec::new()),
            ComparatorOp::GreaterThan | ComparatorOp::LessThan | ComparatorOp::LessThanOrEqual => {
                Ok(vec![Comparator {
                    op: ComparatorOp::LessThan,
                    version: Version::plain(0, 0, 0),
                    include_zero_suffix: true,
                    include_prerelease_floor: false,
                    include_prerelease_upper_bound: false,
                }])
            }
        };
    }
    let Some((lower, upper)) = wildcard_bounds(version, full_input)? else {
        return Ok(Vec::new());
    };
    Ok(match op {
        ComparatorOp::Exact => lower_upper_with_floor(lower, upper, true),
        ComparatorOp::GreaterThanOrEqual => vec![Comparator {
            op,
            version: lower,
            include_zero_suffix: false,
            include_prerelease_floor: true,
            include_prerelease_upper_bound: false,
        }],
        ComparatorOp::GreaterThan => vec![Comparator {
            op: ComparatorOp::GreaterThanOrEqual,
            version: upper,
            include_zero_suffix: false,
            include_prerelease_floor: true,
            include_prerelease_upper_bound: false,
        }],
        ComparatorOp::LessThan => vec![Comparator {
            op,
            version: lower,
            include_zero_suffix: true,
            include_prerelease_floor: false,
            include_prerelease_upper_bound: false,
        }],
        ComparatorOp::LessThanOrEqual => vec![Comparator {
            op: ComparatorOp::LessThan,
            version: upper,
            include_zero_suffix: true,
            include_prerelease_floor: false,
            include_prerelease_upper_bound: false,
        }],
    })
}

fn wildcard_bounds(
    version: &str,
    full_input: &str,
) -> Result<Option<(Version, Version)>, SemverError> {
    let version = strip_range_metadata(version);
    let parts: Vec<&str> = version.split('.').collect();
    if parts.is_empty() || parts.len() > 3 {
        return Err(SemverError::InvalidRange(full_input.to_string()));
    }
    if is_wildcard(parts[0]) {
        return Ok(None);
    }
    let major = parse_number(parts[0], full_input)?;
    if parts.len() == 1 || is_wildcard(parts[1]) {
        return Ok(Some((
            Version::plain(major, 0, 0),
            Version::plain(major + 1, 0, 0),
        )));
    }
    let minor = parse_number(parts[1], full_input)?;
    if parts.len() == 2 || is_wildcard(parts[2]) {
        return Ok(Some((
            Version::plain(major, minor, 0),
            Version::plain(major, minor + 1, 0),
        )));
    }
    Err(SemverError::InvalidRange(full_input.to_string()))
}

fn lower_upper(lower: Version, upper: Version) -> Vec<Comparator> {
    lower_upper_with_floor(lower, upper, false)
}

fn lower_upper_with_floor(
    lower: Version,
    upper: Version,
    include_prerelease_floor: bool,
) -> Vec<Comparator> {
    vec![
        Comparator {
            op: ComparatorOp::GreaterThanOrEqual,
            version: lower,
            include_zero_suffix: false,
            include_prerelease_floor,
            include_prerelease_upper_bound: false,
        },
        Comparator {
            op: ComparatorOp::LessThan,
            version: upper,
            include_zero_suffix: true,
            include_prerelease_floor: false,
            include_prerelease_upper_bound: false,
        },
    ]
}

fn partial_range(
    op: ComparatorOp,
    version: &str,
    full_input: &str,
    options: RangeOptions,
) -> Result<Vec<Comparator>, SemverError> {
    let lower = complete_partial_version(version, full_input, options)?;
    match op {
        ComparatorOp::Exact => {
            let upper = match numeric_part_count(version) {
                0 => return Ok(Vec::new()),
                1 => Version::plain(lower.major + 1, 0, 0),
                2 => Version::plain(lower.major, lower.minor + 1, 0),
                _ => lower.clone(),
            };
            if upper == lower {
                Ok(vec![Comparator {
                    op: ComparatorOp::Exact,
                    version: lower,
                    include_zero_suffix: false,
                    include_prerelease_floor: false,
                    include_prerelease_upper_bound: false,
                }])
            } else {
                Ok(lower_upper_with_floor(lower, upper, true))
            }
        }
        ComparatorOp::GreaterThan => {
            let upper = match numeric_part_count(version) {
                0 => return Ok(Vec::new()),
                1 => Version::plain(lower.major + 1, 0, 0),
                2 => Version::plain(lower.major, lower.minor + 1, 0),
                _ => {
                    return Ok(vec![Comparator {
                        op,
                        version: lower,
                        include_zero_suffix: false,
                        include_prerelease_floor: false,
                        include_prerelease_upper_bound: false,
                    }]);
                }
            };
            Ok(vec![Comparator {
                op: ComparatorOp::GreaterThanOrEqual,
                version: upper,
                include_zero_suffix: false,
                include_prerelease_floor: true,
                include_prerelease_upper_bound: false,
            }])
        }
        ComparatorOp::GreaterThanOrEqual => Ok(vec![Comparator {
            op,
            version: lower,
            include_zero_suffix: false,
            include_prerelease_floor: true,
            include_prerelease_upper_bound: false,
        }]),
        ComparatorOp::LessThan => Ok(vec![Comparator {
            op,
            version: lower,
            include_zero_suffix: true,
            include_prerelease_floor: false,
            include_prerelease_upper_bound: false,
        }]),
        ComparatorOp::LessThanOrEqual => Ok(vec![Comparator {
            op,
            version: lower,
            include_zero_suffix: false,
            include_prerelease_floor: false,
            include_prerelease_upper_bound: false,
        }]),
    }
}

fn complete_partial_version(
    version: &str,
    full_input: &str,
    options: RangeOptions,
) -> Result<Version, SemverError> {
    let normalized;
    let version = if options.loose {
        normalized = normalize_loose_partial_version(version);
        normalized.as_deref().unwrap_or(version)
    } else {
        version
    };
    let version = version.strip_prefix('v').unwrap_or(version);
    let version = version
        .split_once('+')
        .map_or(version, |(version, _)| version);
    let (numbers, prerelease) = version
        .split_once('-')
        .map_or((version, None), |(numbers, prerelease)| {
            (numbers, Some(prerelease))
        });
    let mut parts = parse_numeric_parts(numbers, full_input)?;
    if parts.is_empty() || parts.len() > 3 {
        return Err(SemverError::InvalidRange(full_input.to_string()));
    }
    while parts.len() < 3 {
        parts.push(0);
    }
    let prerelease = parse_prerelease(prerelease, full_input)
        .map_err(|_| SemverError::InvalidRange(full_input.to_string()))?;
    Ok(Version {
        major: parts[0],
        minor: parts[1],
        patch: parts[2],
        prerelease,
        build: Vec::new(),
    })
}

fn parse_range_version(
    version: &str,
    full_input: &str,
    options: RangeOptions,
) -> Result<Version, SemverError> {
    let version = strip_range_build_metadata(version);
    Version::parse_with_options(
        version,
        VersionOptions {
            loose: options.loose,
        },
    )
    .map_err(|_| SemverError::InvalidRange(full_input.to_string()))
}

fn reject_oversized_version(version: &Version, full_input: &str) -> Result<(), SemverError> {
    if version.major > MAX_SAFE_COMPONENT
        || version.minor > MAX_SAFE_COMPONENT
        || version.patch > MAX_SAFE_COMPONENT
    {
        return Err(SemverError::InvalidRange(full_input.to_string()));
    }
    Ok(())
}

impl Version {
    fn plain(major: u64, minor: u64, patch: u64) -> Self {
        Self {
            major,
            minor,
            patch,
            prerelease: Vec::new(),
            build: Vec::new(),
        }
    }

    fn compare_main(&self, other: &Self) -> Ordering {
        self.major
            .cmp(&other.major)
            .then_with(|| self.minor.cmp(&other.minor))
            .then_with(|| self.patch.cmp(&other.patch))
    }

    fn has_same_main_version(&self, other: &Self) -> bool {
        self.major == other.major && self.minor == other.minor && self.patch == other.patch
    }

    fn next_patch(&self) -> Self {
        let mut version = self.clone();
        version.patch += 1;
        version.prerelease.clear();
        version.build.clear();
        version
    }

    fn next_prerelease(&self) -> Self {
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

impl Range {
    fn normalized(&self) -> String {
        self.normalized_with_options(RangeOptions::default())
    }

    fn normalized_with_options(&self, options: RangeOptions) -> String {
        if self.sets.iter().any(|set| set.comparators.is_empty()) {
            return "*".to_string();
        }
        let has_null_set = self.sets.iter().any(is_pure_null_set);
        let mut normalized_sets = Vec::new();
        for set in &self.sets {
            if has_null_set
                && !is_pure_null_set(set)
                && set.comparators.iter().any(is_null_comparator)
            {
                continue;
            }
            let normalized = set
                .comparators
                .iter()
                .map(|comparator| comparator.to_comparator_string_with_options(options))
                .collect::<Vec<_>>()
                .join(" ");
            if !normalized_sets.contains(&normalized) {
                normalized_sets.push(normalized);
            }
        }
        normalized_sets.join("||")
    }

    fn intersects(&self, other: &Self) -> bool {
        self.sets.iter().any(|left| {
            other
                .sets
                .iter()
                .any(|right| comparator_sets_intersect(left, right))
        })
    }

    fn subset_of(&self, other: &Self, options: RangeOptions) -> bool {
        self.sets.iter().all(|left| {
            let Some(left_interval) = interval_for_set(left) else {
                return true;
            };
            other.sets.iter().any(|right| {
                let Some(right_interval) = interval_for_set(right) else {
                    return false;
                };
                interval_contains_with_options(&right_interval, &left_interval, options)
                    && prerelease_subset_allowed(left, right, options)
            })
        })
    }

    fn outside(&self, version: &Version, direction: OutsideDirection) -> bool {
        if self.satisfies(version) {
            return false;
        }

        let mut saw_satisfiable_set = false;
        for set in &self.sets {
            let Some(interval) = interval_for_set(set) else {
                continue;
            };
            saw_satisfiable_set = true;
            if !version_is_outside_interval(version, &interval, direction) {
                return false;
            }
        }
        saw_satisfiable_set
    }
}

fn is_pure_null_set(set: &ComparatorSet) -> bool {
    set.comparators.len() == 1 && is_null_comparator(&set.comparators[0])
}

fn is_null_comparator(comparator: &Comparator) -> bool {
    comparator.op == ComparatorOp::LessThan
        && comparator.include_zero_suffix
        && comparator.version == Version::plain(0, 0, 0)
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum OutsideDirection {
    GreaterThan,
    LessThan,
}

#[derive(Debug, Clone)]
struct Bound {
    version: Version,
    inclusive: bool,
}

#[derive(Debug, Clone, Default)]
struct Interval {
    lower: Option<Bound>,
    upper: Option<Bound>,
}

fn comparator_sets_intersect(left: &ComparatorSet, right: &ComparatorSet) -> bool {
    let Some(left) = interval_for_set(left) else {
        return false;
    };
    let Some(right) = interval_for_set(right) else {
        return false;
    };
    intervals_intersect(&left, &right)
}

fn interval_for_set(set: &ComparatorSet) -> Option<Interval> {
    let mut interval = Interval::default();
    for comparator in &set.comparators {
        apply_comparator_to_interval(&mut interval, comparator);
        if !interval_is_satisfiable(&interval) {
            return None;
        }
    }
    Some(interval)
}

fn min_version_for_set(set: &ComparatorSet) -> Option<Version> {
    let mut selected: Option<Version> = None;
    for comparator in &set.comparators {
        let candidate = match comparator.op {
            ComparatorOp::Exact | ComparatorOp::GreaterThanOrEqual => {
                Some(comparator.version.clone())
            }
            ComparatorOp::GreaterThan => {
                if comparator.version.prerelease.is_empty() {
                    Some(comparator.version.next_patch())
                } else {
                    Some(comparator.version.next_prerelease())
                }
            }
            ComparatorOp::LessThan | ComparatorOp::LessThanOrEqual => None,
        };
        if let Some(candidate) = candidate {
            if selected
                .as_ref()
                .is_none_or(|selected| candidate > *selected)
            {
                selected = Some(candidate);
            }
        }
    }
    selected
}

fn apply_comparator_to_interval(interval: &mut Interval, comparator: &Comparator) {
    let bound_version = comparator.interval_bound_version();
    match comparator.op {
        ComparatorOp::Exact => {
            let bound = Bound {
                version: bound_version,
                inclusive: true,
            };
            replace_lower_if_stricter(interval, bound.clone());
            replace_upper_if_stricter(interval, bound);
        }
        ComparatorOp::GreaterThan => replace_lower_if_stricter(
            interval,
            Bound {
                version: bound_version,
                inclusive: false,
            },
        ),
        ComparatorOp::GreaterThanOrEqual => replace_lower_if_stricter(
            interval,
            Bound {
                version: bound_version,
                inclusive: true,
            },
        ),
        ComparatorOp::LessThan => replace_upper_if_stricter(
            interval,
            Bound {
                version: bound_version,
                inclusive: false,
            },
        ),
        ComparatorOp::LessThanOrEqual => replace_upper_if_stricter(
            interval,
            Bound {
                version: bound_version,
                inclusive: true,
            },
        ),
    }
}

fn replace_lower_if_stricter(interval: &mut Interval, candidate: Bound) {
    let replace = interval.lower.as_ref().is_none_or(|current| {
        candidate.version > current.version
            || (candidate.version == current.version && !candidate.inclusive && current.inclusive)
    });
    if replace {
        interval.lower = Some(candidate);
    }
}

fn replace_upper_if_stricter(interval: &mut Interval, candidate: Bound) {
    let replace = interval.upper.as_ref().is_none_or(|current| {
        candidate.version < current.version
            || (candidate.version == current.version && !candidate.inclusive && current.inclusive)
    });
    if replace {
        interval.upper = Some(candidate);
    }
}

fn interval_is_satisfiable(interval: &Interval) -> bool {
    match (&interval.lower, &interval.upper) {
        (Some(lower), Some(upper)) => {
            lower.version < upper.version
                || (lower.version == upper.version && lower.inclusive && upper.inclusive)
        }
        _ => true,
    }
}

fn intervals_intersect(left: &Interval, right: &Interval) -> bool {
    let lower = stricter_lower(left.lower.as_ref(), right.lower.as_ref());
    let upper = stricter_upper(left.upper.as_ref(), right.upper.as_ref());
    match (lower, upper) {
        (Some(lower), Some(upper)) => {
            lower.version < upper.version
                || (lower.version == upper.version && lower.inclusive && upper.inclusive)
        }
        _ => true,
    }
}

fn interval_contains(outer: &Interval, inner: &Interval) -> bool {
    lower_contains(outer.lower.as_ref(), inner.lower.as_ref())
        && upper_contains(outer.upper.as_ref(), inner.upper.as_ref())
}

fn interval_contains_with_options(
    outer: &Interval,
    inner: &Interval,
    options: RangeOptions,
) -> bool {
    let floor = if options.include_prerelease {
        Version {
            major: 0,
            minor: 0,
            patch: 0,
            prerelease: vec![PrereleaseIdentifier::Numeric(0)],
            build: Vec::new(),
        }
    } else {
        Version::plain(0, 0, 0)
    };
    let mut normalized_inner = inner.clone();
    replace_lower_if_stricter(
        &mut normalized_inner,
        Bound {
            version: floor,
            inclusive: true,
        },
    );
    let inner = &normalized_inner;
    interval_contains(outer, inner)
}

fn prerelease_subset_allowed(
    left: &ComparatorSet,
    right: &ComparatorSet,
    options: RangeOptions,
) -> bool {
    options.include_prerelease
        || prerelease_mains(left)
            .into_iter()
            .all(|main| set_allows_prerelease_main(right, main))
}

fn prerelease_mains(set: &ComparatorSet) -> Vec<(u64, u64, u64)> {
    let mut mains = Vec::new();
    for comparator in &set.comparators {
        if comparator.version.prerelease.is_empty() {
            continue;
        }
        let main = (
            comparator.version.major,
            comparator.version.minor,
            comparator.version.patch,
        );
        if !mains.contains(&main) {
            mains.push(main);
        }
    }
    mains
}

fn set_allows_prerelease_main(set: &ComparatorSet, main: (u64, u64, u64)) -> bool {
    set.comparators.iter().any(|comparator| {
        !comparator.version.prerelease.is_empty()
            && (
                comparator.version.major,
                comparator.version.minor,
                comparator.version.patch,
            ) == main
    })
}

fn lower_contains(outer: Option<&Bound>, inner: Option<&Bound>) -> bool {
    match (outer, inner) {
        (None, _) => true,
        (Some(_), None) => false,
        (Some(outer), Some(inner)) => {
            outer.version < inner.version
                || (outer.version == inner.version && (outer.inclusive || !inner.inclusive))
        }
    }
}

fn upper_contains(outer: Option<&Bound>, inner: Option<&Bound>) -> bool {
    match (outer, inner) {
        (None, _) => true,
        (Some(_), None) => false,
        (Some(outer), Some(inner)) => {
            outer.version > inner.version
                || (outer.version == inner.version && (outer.inclusive || !inner.inclusive))
        }
    }
}

fn version_is_outside_interval(
    version: &Version,
    interval: &Interval,
    direction: OutsideDirection,
) -> bool {
    match direction {
        OutsideDirection::GreaterThan => {
            let Some(upper) = &interval.upper else {
                return false;
            };
            version > &upper.version || (version == &upper.version && !upper.inclusive)
        }
        OutsideDirection::LessThan => {
            let Some(lower) = &interval.lower else {
                return false;
            };
            version < &lower.version || (version == &lower.version && !lower.inclusive)
        }
    }
}

fn normalize_version_input(input: &str, options: VersionOptions) -> Cow<'_, str> {
    let input = input.strip_prefix('v').unwrap_or(input);
    if !options.loose {
        return Cow::Borrowed(input);
    }

    let input = input.strip_prefix('=').unwrap_or(input).trim_start();
    let input = input.strip_prefix('v').unwrap_or(input);
    if Version::parse(input).is_ok() {
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

fn normalize_loose_partial_version(input: &str) -> Option<String> {
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

fn strip_build_metadata(version: String) -> String {
    version
        .split_once('+')
        .map_or(version.clone(), |(version, _)| version.to_string())
}

fn stricter_lower<'a>(left: Option<&'a Bound>, right: Option<&'a Bound>) -> Option<&'a Bound> {
    match (left, right) {
        (Some(left), Some(right)) => {
            if left.version > right.version {
                Some(left)
            } else if right.version > left.version {
                Some(right)
            } else if !left.inclusive {
                Some(left)
            } else {
                Some(right)
            }
        }
        (Some(bound), None) | (None, Some(bound)) => Some(bound),
        (None, None) => None,
    }
}

fn stricter_upper<'a>(left: Option<&'a Bound>, right: Option<&'a Bound>) -> Option<&'a Bound> {
    match (left, right) {
        (Some(left), Some(right)) => {
            if left.version < right.version {
                Some(left)
            } else if right.version < left.version {
                Some(right)
            } else if !left.inclusive {
                Some(left)
            } else {
                Some(right)
            }
        }
        (Some(bound), None) | (None, Some(bound)) => Some(bound),
        (None, None) => None,
    }
}

fn parse_numeric_parts(numbers: &str, input: &str) -> Result<Vec<u64>, SemverError> {
    let mut parts = Vec::new();
    for part in numbers.split('.') {
        if part.is_empty() || (part.len() > 1 && part.starts_with('0')) {
            return Err(SemverError::InvalidVersion(input.to_string()));
        }
        parts.push(
            parse_component(part).map_err(|_| SemverError::InvalidVersion(input.to_string()))?,
        );
    }
    Ok(parts)
}

fn parse_exact_numeric_parts(numbers: &str, input: &str) -> Result<[u64; 3], SemverError> {
    let mut parts = numbers.split('.');
    let major = parse_numeric_part(parts.next(), input)?;
    let minor = parse_numeric_part(parts.next(), input)?;
    let patch = parse_numeric_part(parts.next(), input)?;
    if parts.next().is_some() {
        return Err(SemverError::InvalidVersion(input.to_string()));
    }
    Ok([major, minor, patch])
}

fn parse_numeric_part(part: Option<&str>, input: &str) -> Result<u64, SemverError> {
    let Some(part) = part else {
        return Err(SemverError::InvalidVersion(input.to_string()));
    };
    if part.is_empty() || (part.len() > 1 && part.starts_with('0')) {
        return Err(SemverError::InvalidVersion(input.to_string()));
    }
    parse_component(part).map_err(|_| SemverError::InvalidVersion(input.to_string()))
}

fn parse_component(part: &str) -> Result<u64, SemverError> {
    let component = part
        .parse::<u64>()
        .map_err(|_| SemverError::InvalidVersion(part.to_string()))?;
    if component > MAX_SAFE_COMPONENT {
        return Err(SemverError::InvalidVersion(part.to_string()));
    }
    Ok(component)
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

fn is_partial_version(version: &str) -> bool {
    matches!(numeric_part_count(version), 1 | 2)
}

fn numeric_part_count(version: &str) -> usize {
    let numbers = version
        .split_once('-')
        .map_or(version, |(numbers, _)| numbers);
    numbers.split('.').count()
}

fn parse_prerelease(
    prerelease: Option<&str>,
    input: &str,
) -> Result<Vec<PrereleaseIdentifier>, SemverError> {
    let Some(prerelease) = prerelease else {
        return Ok(Vec::new());
    };
    if prerelease.is_empty() {
        return Err(SemverError::InvalidVersion(input.to_string()));
    }
    let mut identifiers = Vec::new();
    for part in prerelease.split('.') {
        if part.is_empty() || !part.chars().all(|c| c.is_ascii_alphanumeric() || c == '-') {
            return Err(SemverError::InvalidVersion(input.to_string()));
        }
        if part.chars().all(|c| c.is_ascii_digit()) {
            if part.len() > 1 && part.starts_with('0') {
                return Err(SemverError::InvalidVersion(input.to_string()));
            }
            identifiers.push(PrereleaseIdentifier::Numeric(
                parse_component(part)
                    .map_err(|_| SemverError::InvalidVersion(input.to_string()))?,
            ));
        } else {
            identifiers.push(PrereleaseIdentifier::Text(part.to_string()));
        }
    }
    Ok(identifiers)
}

fn parse_build(build: &str, input: &str) -> Result<Vec<String>, SemverError> {
    if build.is_empty() {
        return Err(SemverError::InvalidVersion(input.to_string()));
    }
    let mut identifiers = Vec::new();
    for part in build.split('.') {
        if part.is_empty() || !part.chars().all(|c| c.is_ascii_alphanumeric() || c == '-') {
            return Err(SemverError::InvalidVersion(input.to_string()));
        }
        identifiers.push(part.to_string());
    }
    Ok(identifiers)
}

fn compare_prerelease(left: &[PrereleaseIdentifier], right: &[PrereleaseIdentifier]) -> Ordering {
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

fn compare_build_versions(left: &Version, right: &Version) -> Ordering {
    left.cmp(right)
        .then_with(|| compare_build_identifiers(&left.build, &right.build))
}

fn compare_identifier_strings(left: &str, right: &str) -> Ordering {
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

fn parse_sort_versions_with_options<'a, I>(
    versions: I,
    options: VersionOptions,
) -> Result<Vec<(&'a str, Version)>, SemverError>
where
    I: IntoIterator<Item = &'a str>,
{
    let mut parsed = Vec::new();
    for version in versions {
        parsed.push((version, Version::parse_with_options(version, options)?));
    }
    Ok(parsed)
}

fn version_options_from_range(options: RangeOptions) -> VersionOptions {
    VersionOptions {
        loose: options.loose,
    }
}

fn contains_wildcard(value: &str) -> bool {
    value.split('.').any(is_wildcard_component)
}

fn is_wildcard(value: &str) -> bool {
    matches!(value, "*" | "x" | "X")
}

fn is_wildcard_component(value: &str) -> bool {
    is_wildcard(strip_range_metadata(value))
}

fn strip_range_metadata(value: &str) -> &str {
    let value = value.split_once('+').map_or(value, |(value, _)| value);
    value.split_once('-').map_or(value, |(value, _)| value)
}

fn strip_range_build_metadata(value: &str) -> &str {
    value.split_once('+').map_or(value, |(value, _)| value)
}

fn parse_number(value: &str, full_input: &str) -> Result<u64, SemverError> {
    let number = value
        .parse::<u64>()
        .map_err(|_| SemverError::InvalidRange(full_input.to_string()))?;
    if number > MAX_SAFE_COMPONENT {
        return Err(SemverError::InvalidRange(full_input.to_string()));
    }
    Ok(number)
}

#[cfg(test)]
mod tests {
    use super::{
        clean, cmp, cmp_with_options, coerce, coerce_number, coerce_rtl, coerce_with_options,
        compare, compare_build, compare_identifiers, compare_loose, eq, eq_with_options, gt,
        gt_with_options, gte, gte_with_options, gtr, gtr_with_options, inc, inc_with_identifier,
        inc_with_identifier_base, inc_with_options, lt, lt_with_options, lte, lte_with_options,
        ltr, ltr_with_options, major, major_with_options, max_satisfying, min_satisfying, minor,
        minor_with_options, neq, neq_with_options, outside, outside_with_options, patch,
        patch_with_options, prerelease, prerelease_with_options, rcompare, rcompare_identifiers,
        rsort, rsort_with_options, satisfies, satisfies_with_options, simplify_range,
        simplify_range_with_options, sort, sort_with_options, subset, subset_with_options, valid,
        valid_range, valid_range_with_options, CoerceOptions, RangeOptions, Version,
        VersionOptions,
    };
    use super::{max_satisfying_with_options, min_satisfying_with_options};
    use serde::Deserialize;
    use std::cmp::Ordering;

    #[derive(Deserialize)]
    struct NodeSemverSubset {
        valid_versions: Vec<String>,
        valid_loose_versions: Vec<(String, Option<String>)>,
        clean_versions: Vec<(String, Option<String>)>,
        invalid_versions: Vec<String>,
        comparisons: Vec<(String, String)>,
        compare_loose: Vec<(String, String)>,
        comparison_predicate_loose: Vec<(String, String)>,
        equality_predicate_loose: Vec<(String, String)>,
        version_part_loose: Vec<VersionPartCase>,
        prerelease_loose: Vec<PrereleaseCase>,
        identifiers: Vec<(String, String)>,
        inc: Vec<(String, String, Option<String>)>,
        inc_loose: Vec<(String, String, Option<String>)>,
        inc_identifier: Vec<IncIdentifierCase>,
        coerce: Vec<(String, Option<String>)>,
        coerce_non_string_numbers: Vec<(u64, Option<String>)>,
        coerce_rtl: Vec<(String, Option<String>)>,
        coerce_include_prerelease: Vec<(String, Option<String>)>,
        coerce_rtl_include_prerelease: Vec<(String, Option<String>)>,
        compare_build: Vec<CompareBuildCase>,
        rcompare: Vec<ReverseCompareCase>,
        sort_build: SortCase,
        cmp: Vec<(String, String, String, bool)>,
        diff: Vec<(String, String, Option<String>)>,
        truncate: Vec<(String, String, Option<String>)>,
        satisfies: Vec<(String, String)>,
        satisfies_false: Vec<(String, String)>,
        satisfies_prerelease: Vec<(String, String, bool)>,
        satisfies_include_prerelease: Vec<(String, String, bool)>,
        satisfies_loose: Vec<(String, String, bool)>,
        max_satisfying: Vec<MaxSatisfyingCase>,
        max_satisfying_include_prerelease: Vec<MaxSatisfyingCase>,
        max_satisfying_loose: Vec<MaxSatisfyingCase>,
        min_satisfying: Vec<MinSatisfyingCase>,
        min_satisfying_include_prerelease: Vec<MinSatisfyingCase>,
        min_satisfying_loose: Vec<MinSatisfyingCase>,
        intersects: Vec<(String, String, bool)>,
        subset: Vec<(String, String, bool)>,
        subset_include_prerelease: Vec<(String, String, bool)>,
        simplify_range: Vec<SimplifyRangeCase>,
        simplify_range_include_prerelease: Vec<SimplifyRangeCase>,
        outside: Vec<(String, String, String, bool)>,
        outside_include_prerelease: Vec<(String, String, String, bool)>,
        outside_loose: Vec<(String, String, String, bool)>,
        gtr: Vec<(String, String, bool)>,
        gtr_include_prerelease: Vec<(String, String, bool)>,
        gtr_loose: Vec<(String, String, bool)>,
        ltr: Vec<(String, String, bool)>,
        ltr_include_prerelease: Vec<(String, String, bool)>,
        ltr_loose: Vec<(String, String, bool)>,
        min_version: Vec<(String, Option<String>)>,
        to_comparators: Vec<(String, Vec<Vec<String>>)>,
        valid_range: Vec<(String, Option<String>)>,
        valid_range_include_prerelease: Vec<(String, Option<String>)>,
        valid_range_loose: Vec<(String, Option<String>)>,
    }

    #[derive(Deserialize)]
    struct MaxSatisfyingCase {
        versions: Vec<String>,
        range: String,
        expected: String,
    }

    #[derive(Deserialize)]
    struct MinSatisfyingCase {
        versions: Vec<String>,
        range: String,
        expected: String,
    }

    #[derive(Deserialize)]
    struct SimplifyRangeCase {
        versions: Vec<String>,
        range: String,
        expected: String,
    }

    #[derive(Deserialize)]
    struct VersionPartCase {
        version: String,
        major: u64,
        minor: u64,
        patch: u64,
    }

    #[derive(Deserialize)]
    struct PrereleaseCase {
        version: String,
        expected: Option<Vec<String>>,
    }

    #[derive(Deserialize)]
    struct CompareBuildCase {
        left: String,
        right: String,
        expected: i8,
    }

    #[derive(Deserialize)]
    struct ReverseCompareCase {
        left: String,
        right: String,
        expected: i8,
    }

    #[derive(Deserialize)]
    struct SortCase {
        versions: Vec<String>,
        sorted: Vec<String>,
        rsorted: Vec<String>,
    }

    #[derive(Deserialize)]
    struct IncIdentifierCase {
        version: String,
        release_type: String,
        identifier: String,
        identifier_base: Option<u64>,
        expected: Option<String>,
    }

    fn node_semver_subset() -> NodeSemverSubset {
        let fixture =
            include_str!("../../tests/fixtures/semver/node-semver/compatibility-subset.json");
        serde_json::from_str(fixture).expect("node-semver compatibility subset fixture is valid")
    }

    #[test]
    fn compares_versions_with_prerelease_ordering() {
        assert!(Version::parse("1.0.0").unwrap() > Version::parse("1.0.0-rc.1").unwrap());
        assert!(Version::parse("1.0.0-beta.2").unwrap() > Version::parse("1.0.0-beta.1").unwrap());
        assert_eq!(
            Version::parse("1.0.0+build.1").unwrap(),
            Version::parse("1.0.0").unwrap()
        );
        assert_eq!(compare("1.0.0", "1.0.1").unwrap(), Ordering::Less);
        assert_eq!(rcompare("1.0.0", "1.0.1").unwrap(), Ordering::Greater);
        assert_eq!(valid("v1.2.3+build.1"), Some("1.2.3+build.1".to_string()));
        assert_eq!(clean(" 1.2.3 "), Some("1.2.3".to_string()));
        assert_eq!(
            compare_build("1.0.0+build.2", "1.0.0+build.1").unwrap(),
            Ordering::Greater
        );
    }

    #[test]
    fn exposes_node_semver_comparison_predicates_and_parts() {
        assert!(eq("1.2.3+build.1", "1.2.3+build.2").unwrap());
        assert!(neq("1.2.3", "1.2.4").unwrap());
        assert!(gt("1.2.4", "1.2.3").unwrap());
        assert!(gte("1.2.3", "1.2.3").unwrap());
        assert!(lt("1.2.3-alpha", "1.2.3").unwrap());
        assert!(lte("1.2.3", "1.2.3").unwrap());
        assert_eq!(major("2.1.3").unwrap(), 2);
        assert_eq!(minor("2.1.3").unwrap(), 1);
        assert_eq!(patch("2.1.3").unwrap(), 3);
        assert_eq!(
            prerelease("1.2.3-alpha.1").unwrap(),
            Some(vec!["alpha".to_string(), "1".to_string()])
        );
        assert_eq!(prerelease("1.2.3").unwrap(), None);
    }

    #[test]
    fn sorts_versions_in_semver_order() {
        let versions = ["1.2.3", "1.2.3-alpha", "2.0.0", "1.3.0"];
        assert_eq!(
            sort(versions).unwrap(),
            vec!["1.2.3-alpha", "1.2.3", "1.3.0", "2.0.0"]
        );
        assert_eq!(
            rsort(versions).unwrap(),
            vec!["2.0.0", "1.3.0", "1.2.3", "1.2.3-alpha"]
        );
    }

    #[test]
    fn passes_derived_node_semver_compare_build_subset() {
        for case in node_semver_subset().compare_build {
            let expected = match case.expected {
                -1 => Ordering::Less,
                0 => Ordering::Equal,
                1 => Ordering::Greater,
                _ => unreachable!("fixture uses node-semver compareBuild ordering"),
            };
            assert_eq!(
                compare_build(&case.left, &case.right).unwrap(),
                expected,
                "compare_build({}, {})",
                case.left,
                case.right
            );
        }
    }

    #[test]
    fn passes_derived_node_semver_rcompare_subset() {
        for case in node_semver_subset().rcompare {
            let expected = match case.expected {
                -1 => Ordering::Less,
                0 => Ordering::Equal,
                1 => Ordering::Greater,
                _ => unreachable!("fixture uses node-semver rcompare ordering"),
            };
            assert_eq!(
                rcompare(&case.left, &case.right).unwrap(),
                expected,
                "rcompare({}, {})",
                case.left,
                case.right
            );
        }
    }

    #[test]
    fn passes_derived_node_semver_sort_build_subset() {
        let case = node_semver_subset().sort_build;
        let versions = case.versions.iter().map(String::as_str).collect::<Vec<_>>();
        assert_eq!(sort(versions.iter().copied()).unwrap(), case.sorted);
        assert_eq!(rsort(versions.iter().copied()).unwrap(), case.rsorted);
        assert_eq!(
            sort_with_options(versions.iter().copied(), VersionOptions::default()).unwrap(),
            case.sorted
        );
        assert_eq!(
            rsort_with_options(versions.iter().copied(), VersionOptions::default()).unwrap(),
            case.rsorted
        );
    }

    #[test]
    fn supports_m1_range_forms() {
        assert!(satisfies("1.2.3", "1.2.3").unwrap());
        assert!(!satisfies("1.2.4", "1.2.3").unwrap());
        assert!(satisfies("1.9.9", "^1.2.3").unwrap());
        assert!(!satisfies("2.0.0", "^1.2.3").unwrap());
        assert!(satisfies("0.2.9", "^0.2.0").unwrap());
        assert!(!satisfies("0.3.0", "^0.2.0").unwrap());
        assert!(satisfies("1.2.9", "~1.2.3").unwrap());
        assert!(!satisfies("1.3.0", "~1.2.3").unwrap());
        assert!(satisfies("3.0.0", "*").unwrap());
        assert!(satisfies("1.9.0", "1.x").unwrap());
        assert!(!satisfies("2.0.0", "1.x").unwrap());
        assert!(satisfies("1.2.9", "1.2.x").unwrap());
        assert!(satisfies("1.5.0", ">=1.0.0 <2.0.0").unwrap());
    }

    #[test]
    fn selects_highest_and_lowest_satisfying_versions() {
        let versions = ["1.2.3", "1.9.9", "2.0.0"];
        assert_eq!(max_satisfying(versions, "^1.2.3").unwrap(), Some("1.9.9"));
        assert_eq!(min_satisfying(versions, "^1.2.3").unwrap(), Some("1.2.3"));
        assert_eq!(max_satisfying(versions, ">=3.0.0").unwrap(), None);
    }

    #[test]
    fn rejects_invalid_ranges() {
        assert!(satisfies("1.0.0", "=>1.0.0").is_err());
        assert!(satisfies("1.0.0", "1..2").is_err());
    }

    #[test]
    fn passes_derived_node_semver_valid_version_subset() {
        for version in node_semver_subset().valid_versions {
            assert!(valid(&version).is_some(), "{version} should be valid");
        }
    }

    #[test]
    fn passes_derived_node_semver_valid_loose_version_subset() {
        let options = VersionOptions { loose: true };
        for (version, expected) in node_semver_subset().valid_loose_versions {
            assert_eq!(
                super::valid_with_options(&version, options),
                expected,
                "valid({version}, loose)"
            );
        }
    }

    #[test]
    fn passes_derived_node_semver_clean_version_subset() {
        for (version, expected) in node_semver_subset().clean_versions {
            assert_eq!(clean(&version), expected, "clean({version})");
        }
    }

    #[test]
    fn passes_derived_node_semver_invalid_version_subset() {
        for version in node_semver_subset().invalid_versions {
            assert!(valid(&version).is_none(), "{version} should be invalid");
        }
    }

    #[test]
    fn passes_derived_node_semver_comparison_subset() {
        for (greater, lesser) in node_semver_subset().comparisons {
            assert_eq!(
                compare(&greater, &lesser).unwrap(),
                Ordering::Greater,
                "{greater} should be greater than {lesser}"
            );
        }
    }

    #[test]
    fn passes_derived_node_semver_compare_loose_subset() {
        for (loose, strict) in node_semver_subset().compare_loose {
            assert_eq!(
                compare_loose(&loose, &strict).unwrap(),
                Ordering::Equal,
                "compare_loose({loose}, {strict})"
            );
            assert!(
                compare(&loose, &strict).is_err(),
                "{loose} should need loose mode"
            );
        }
    }

    #[test]
    fn passes_derived_node_semver_loose_comparison_predicate_subset() {
        let options = VersionOptions { loose: true };
        for (greater, lesser) in node_semver_subset().comparison_predicate_loose {
            assert!(gt_with_options(&greater, &lesser, options).unwrap());
            assert!(gte_with_options(&greater, &lesser, options).unwrap());
            assert!(!eq_with_options(&greater, &lesser, options).unwrap());
            assert!(neq_with_options(&greater, &lesser, options).unwrap());
            assert!(lt_with_options(&lesser, &greater, options).unwrap());
            assert!(lte_with_options(&lesser, &greater, options).unwrap());
            assert!(cmp_with_options(&greater, ">", &lesser, options).unwrap());
            assert!(cmp_with_options(&lesser, "<", &greater, options).unwrap());
        }
    }

    #[test]
    fn passes_derived_node_semver_loose_equality_predicate_subset() {
        let options = VersionOptions { loose: true };
        for (left, right) in node_semver_subset().equality_predicate_loose {
            assert!(eq_with_options(&left, &right, options).unwrap());
            assert!(!neq_with_options(&left, &right, options).unwrap());
            assert!(!gt_with_options(&left, &right, options).unwrap());
            assert!(gte_with_options(&left, &right, options).unwrap());
            assert!(!lt_with_options(&left, &right, options).unwrap());
            assert!(lte_with_options(&left, &right, options).unwrap());
            assert!(cmp_with_options(&left, "==", &right, options).unwrap());
            assert!(!cmp_with_options(&left, "!=", &right, options).unwrap());
        }
    }

    #[test]
    fn passes_derived_node_semver_identifier_subset() {
        for (left, right) in node_semver_subset().identifiers {
            assert_eq!(
                compare_identifiers(&left, &right),
                Ordering::Less,
                "compare_identifiers({left}, {right})"
            );
            assert_eq!(
                rcompare_identifiers(&left, &right),
                Ordering::Greater,
                "rcompare_identifiers({left}, {right})"
            );
        }
        assert_eq!(compare_identifiers("0", "0"), Ordering::Equal);
        assert_eq!(rcompare_identifiers("0", "0"), Ordering::Equal);
        assert_eq!(compare_identifiers("01", "1"), Ordering::Equal);
    }

    #[test]
    fn passes_derived_node_semver_loose_version_part_subset() {
        let options = VersionOptions { loose: true };
        for case in node_semver_subset().version_part_loose {
            assert_eq!(
                major_with_options(&case.version, options).unwrap(),
                case.major
            );
            assert_eq!(
                minor_with_options(&case.version, options).unwrap(),
                case.minor
            );
            assert_eq!(
                patch_with_options(&case.version, options).unwrap(),
                case.patch
            );
        }
    }

    #[test]
    fn passes_derived_node_semver_loose_prerelease_subset() {
        let options = VersionOptions { loose: true };
        for case in node_semver_subset().prerelease_loose {
            assert_eq!(
                prerelease_with_options(&case.version, options).unwrap(),
                case.expected,
                "prerelease({}, loose)",
                case.version
            );
        }
    }

    #[test]
    fn passes_derived_node_semver_inc_subset() {
        for (version, release_type, expected) in node_semver_subset().inc {
            assert_eq!(
                inc(&version, &release_type),
                expected,
                "inc({version}, {release_type})"
            );
        }
    }

    #[test]
    fn passes_derived_node_semver_inc_loose_subset() {
        let options = VersionOptions { loose: true };
        for (version, release_type, expected) in node_semver_subset().inc_loose {
            assert_eq!(
                inc_with_options(&version, &release_type, options),
                expected,
                "inc({version}, {release_type}, loose)"
            );
        }
    }

    #[test]
    fn passes_derived_node_semver_inc_identifier_subset() {
        for case in node_semver_subset().inc_identifier {
            let actual = match case.identifier_base {
                Some(0) => inc_with_identifier(&case.version, &case.release_type, &case.identifier),
                base => inc_with_identifier_base(
                    &case.version,
                    &case.release_type,
                    &case.identifier,
                    base,
                ),
            };
            assert_eq!(
                actual, case.expected,
                "inc({}, {}, {}, {:?})",
                case.version, case.release_type, case.identifier, case.identifier_base
            );
        }
    }

    #[test]
    fn passes_derived_node_semver_coerce_subset() {
        for (input, expected) in node_semver_subset().coerce {
            assert_eq!(coerce(&input), expected, "coerce({input})");
        }
    }

    #[test]
    fn passes_derived_node_semver_coerce_non_string_number_subset() {
        for (input, expected) in node_semver_subset().coerce_non_string_numbers {
            assert_eq!(coerce_number(input), expected, "coerce({input})");
        }
    }

    #[test]
    fn passes_derived_node_semver_coerce_rtl_subset() {
        for (input, expected) in node_semver_subset().coerce_rtl {
            assert_eq!(coerce_rtl(&input), expected, "coerce_rtl({input})");
        }
    }

    #[test]
    fn passes_derived_node_semver_coerce_include_prerelease_subset() {
        let options = CoerceOptions {
            rtl: false,
            include_prerelease: true,
        };
        for (input, expected) in node_semver_subset().coerce_include_prerelease {
            assert_eq!(
                coerce_with_options(&input, options),
                expected,
                "coerce({input}, include_prerelease)"
            );
        }
    }

    #[test]
    fn passes_derived_node_semver_coerce_rtl_include_prerelease_subset() {
        let options = CoerceOptions {
            rtl: true,
            include_prerelease: true,
        };
        for (input, expected) in node_semver_subset().coerce_rtl_include_prerelease {
            assert_eq!(
                coerce_with_options(&input, options),
                expected,
                "coerce({input}, rtl, include_prerelease)"
            );
        }
    }

    #[test]
    fn passes_derived_node_semver_cmp_subset() {
        for (left, op, right, expected) in node_semver_subset().cmp {
            assert_eq!(
                cmp(&left, &op, &right).unwrap(),
                expected,
                "cmp({left}, {op}, {right})"
            );
        }
        assert!(cmp("1.2.3", "a frog", "4.5.6").is_err());
    }

    #[test]
    fn passes_derived_node_semver_diff_subset() {
        for (left, right, expected) in node_semver_subset().diff {
            assert_eq!(
                super::diff(&left, &right).unwrap(),
                expected.as_deref(),
                "diff({left}, {right})"
            );
        }
    }

    #[test]
    fn passes_derived_node_semver_truncate_subset() {
        for (version, release_type, expected) in node_semver_subset().truncate {
            assert_eq!(
                super::truncate(&version, &release_type),
                expected,
                "truncate({version}, {release_type})"
            );
        }
    }

    #[test]
    fn passes_derived_node_semver_satisfies_subset() {
        for (range, version) in node_semver_subset().satisfies {
            assert!(
                satisfies(&version, &range).unwrap(),
                "{version} should satisfy {range}"
            );
        }
    }

    #[test]
    fn passes_derived_node_semver_satisfies_false_subset() {
        for (range, version) in node_semver_subset().satisfies_false {
            assert!(
                !satisfies(&version, &range).unwrap(),
                "{version} should not satisfy {range}"
            );
        }
    }

    #[test]
    fn passes_derived_node_semver_satisfies_prerelease_subset() {
        for (range, version, expected) in node_semver_subset().satisfies_prerelease {
            assert_eq!(
                satisfies(&version, &range).unwrap(),
                expected,
                "satisfies({version}, {range})"
            );
        }
    }

    #[test]
    fn passes_derived_node_semver_satisfies_include_prerelease_subset() {
        let options = RangeOptions {
            include_prerelease: true,
            loose: false,
        };
        for (range, version, expected) in node_semver_subset().satisfies_include_prerelease {
            assert_eq!(
                satisfies_with_options(&version, &range, options).unwrap(),
                expected,
                "satisfies({version}, {range}, include_prerelease)"
            );
        }
    }

    #[test]
    fn passes_derived_node_semver_satisfies_loose_subset() {
        let options = RangeOptions {
            include_prerelease: false,
            loose: true,
        };
        for (range, version, expected) in node_semver_subset().satisfies_loose {
            assert_eq!(
                satisfies_with_options(&version, &range, options).unwrap(),
                expected,
                "satisfies({version}, {range}, loose)"
            );
        }
    }

    #[test]
    fn passes_derived_node_semver_max_satisfying_subset() {
        for case in node_semver_subset().max_satisfying {
            let versions = case.versions.iter().map(String::as_str);
            assert_eq!(
                max_satisfying(versions, &case.range).unwrap(),
                Some(case.expected.as_str()),
                "max satisfying failed for {}",
                case.range
            );
        }
    }

    #[test]
    fn passes_derived_node_semver_max_satisfying_include_prerelease_subset() {
        let options = RangeOptions {
            include_prerelease: true,
            loose: false,
        };
        for case in node_semver_subset().max_satisfying_include_prerelease {
            let versions = case.versions.iter().map(String::as_str);
            assert_eq!(
                max_satisfying_with_options(versions, &case.range, options).unwrap(),
                Some(case.expected.as_str()),
                "max satisfying include prerelease failed for {}",
                case.range
            );
        }
    }

    #[test]
    fn passes_derived_node_semver_max_satisfying_loose_subset() {
        let options = RangeOptions {
            include_prerelease: false,
            loose: true,
        };
        for case in node_semver_subset().max_satisfying_loose {
            let versions = case.versions.iter().map(String::as_str);
            assert_eq!(
                max_satisfying_with_options(versions, &case.range, options).unwrap(),
                Some(case.expected.as_str()),
                "max satisfying loose failed for {}",
                case.range
            );
        }
    }

    #[test]
    fn passes_derived_node_semver_min_satisfying_subset() {
        for case in node_semver_subset().min_satisfying {
            let versions = case.versions.iter().map(String::as_str);
            assert_eq!(
                min_satisfying(versions, &case.range).unwrap(),
                Some(case.expected.as_str()),
                "min satisfying failed for {}",
                case.range
            );
        }
    }

    #[test]
    fn passes_derived_node_semver_min_satisfying_loose_subset() {
        let options = RangeOptions {
            include_prerelease: false,
            loose: true,
        };
        for case in node_semver_subset().min_satisfying_loose {
            let versions = case.versions.iter().map(String::as_str);
            assert_eq!(
                min_satisfying_with_options(versions, &case.range, options).unwrap(),
                Some(case.expected.as_str()),
                "min satisfying loose failed for {}",
                case.range
            );
        }
    }

    #[test]
    fn passes_derived_node_semver_min_satisfying_include_prerelease_subset() {
        let options = RangeOptions {
            include_prerelease: true,
            loose: false,
        };
        for case in node_semver_subset().min_satisfying_include_prerelease {
            let versions = case.versions.iter().map(String::as_str);
            assert_eq!(
                min_satisfying_with_options(versions, &case.range, options).unwrap(),
                Some(case.expected.as_str()),
                "min satisfying include prerelease failed for {}",
                case.range
            );
        }
    }

    #[test]
    fn passes_derived_node_semver_intersects_subset() {
        for (left, right, expected) in node_semver_subset().intersects {
            assert_eq!(
                super::intersects(&left, &right).unwrap(),
                expected,
                "intersects({left}, {right})"
            );
            assert_eq!(
                super::intersects(&right, &left).unwrap(),
                expected,
                "intersects({right}, {left})"
            );
        }
    }

    #[test]
    fn passes_derived_node_semver_subset_subset() {
        for (sub, dom, expected) in node_semver_subset().subset {
            assert_eq!(
                subset(&sub, &dom).unwrap(),
                expected,
                "subset({sub}, {dom})"
            );
        }
    }

    #[test]
    fn passes_derived_node_semver_subset_include_prerelease_subset() {
        let options = RangeOptions {
            include_prerelease: true,
            loose: false,
        };
        for (sub, dom, expected) in node_semver_subset().subset_include_prerelease {
            assert_eq!(
                subset_with_options(&sub, &dom, options).unwrap(),
                expected,
                "subset({sub}, {dom}, include_prerelease)"
            );
        }
    }

    #[test]
    fn passes_derived_node_semver_simplify_range_subset() {
        for case in node_semver_subset().simplify_range {
            let versions = case.versions.iter().map(String::as_str);
            assert_eq!(
                simplify_range(versions, &case.range).unwrap(),
                case.expected,
                "simplify_range({})",
                case.range
            );
        }
    }

    #[test]
    fn passes_derived_node_semver_simplify_range_include_prerelease_subset() {
        let options = RangeOptions {
            include_prerelease: true,
            loose: false,
        };
        for case in node_semver_subset().simplify_range_include_prerelease {
            let versions = case.versions.iter().map(String::as_str);
            assert_eq!(
                simplify_range_with_options(versions, &case.range, options).unwrap(),
                case.expected,
                "simplify_range({}, include_prerelease)",
                case.range
            );
        }
    }

    #[test]
    fn passes_derived_node_semver_outside_subset() {
        for (range, version, hilo, expected) in node_semver_subset().outside {
            assert_eq!(
                outside(&version, &range, &hilo).unwrap(),
                expected,
                "outside({version}, {range}, {hilo})"
            );
        }
    }

    #[test]
    fn passes_derived_node_semver_outside_include_prerelease_subset() {
        let options = RangeOptions {
            include_prerelease: true,
            loose: false,
        };
        for (range, version, hilo, expected) in node_semver_subset().outside_include_prerelease {
            assert_eq!(
                outside_with_options(&version, &range, &hilo, options).unwrap(),
                expected,
                "outside({version}, {range}, {hilo}, include_prerelease)"
            );
        }
    }

    #[test]
    fn passes_derived_node_semver_outside_loose_subset() {
        let options = RangeOptions {
            include_prerelease: false,
            loose: true,
        };
        for (range, version, hilo, expected) in node_semver_subset().outside_loose {
            assert_eq!(
                outside_with_options(&version, &range, &hilo, options).unwrap(),
                expected,
                "outside({version}, {range}, {hilo}, loose)"
            );
        }
    }

    #[test]
    fn passes_derived_node_semver_gtr_subset() {
        for (range, version, expected) in node_semver_subset().gtr {
            assert_eq!(
                gtr(&version, &range).unwrap(),
                expected,
                "gtr({version}, {range})"
            );
        }
    }

    #[test]
    fn passes_derived_node_semver_gtr_include_prerelease_subset() {
        let options = RangeOptions {
            include_prerelease: true,
            loose: false,
        };
        for (range, version, expected) in node_semver_subset().gtr_include_prerelease {
            assert_eq!(
                gtr_with_options(&version, &range, options).unwrap(),
                expected,
                "gtr({version}, {range}, include_prerelease)"
            );
        }
    }

    #[test]
    fn passes_derived_node_semver_gtr_loose_subset() {
        let options = RangeOptions {
            include_prerelease: false,
            loose: true,
        };
        for (range, version, expected) in node_semver_subset().gtr_loose {
            assert_eq!(
                gtr_with_options(&version, &range, options).unwrap(),
                expected,
                "gtr({version}, {range}, loose)"
            );
        }
    }

    #[test]
    fn passes_derived_node_semver_ltr_subset() {
        for (range, version, expected) in node_semver_subset().ltr {
            assert_eq!(
                ltr(&version, &range).unwrap(),
                expected,
                "ltr({version}, {range})"
            );
        }
    }

    #[test]
    fn passes_derived_node_semver_ltr_include_prerelease_subset() {
        let options = RangeOptions {
            include_prerelease: true,
            loose: false,
        };
        for (range, version, expected) in node_semver_subset().ltr_include_prerelease {
            assert_eq!(
                ltr_with_options(&version, &range, options).unwrap(),
                expected,
                "ltr({version}, {range}, include_prerelease)"
            );
        }
    }

    #[test]
    fn passes_derived_node_semver_ltr_loose_subset() {
        let options = RangeOptions {
            include_prerelease: false,
            loose: true,
        };
        for (range, version, expected) in node_semver_subset().ltr_loose {
            assert_eq!(
                ltr_with_options(&version, &range, options).unwrap(),
                expected,
                "ltr({version}, {range}, loose)"
            );
        }
    }

    #[test]
    fn passes_derived_node_semver_min_version_subset() {
        for (range, expected) in node_semver_subset().min_version {
            assert_eq!(
                super::min_version(&range).unwrap(),
                expected,
                "min_version({range})"
            );
        }
    }

    #[test]
    fn passes_derived_node_semver_to_comparators_subset() {
        for (range, expected) in node_semver_subset().to_comparators {
            assert_eq!(
                super::to_comparators(&range).unwrap(),
                expected,
                "to_comparators({range})"
            );
        }
    }

    #[test]
    fn passes_derived_node_semver_valid_range_subset() {
        for (range, expected) in node_semver_subset().valid_range {
            assert_eq!(valid_range(&range), expected, "valid_range({range})");
        }
    }

    #[test]
    fn passes_derived_node_semver_valid_range_include_prerelease_subset() {
        let options = RangeOptions {
            include_prerelease: true,
            loose: false,
        };
        for (range, expected) in node_semver_subset().valid_range_include_prerelease {
            assert_eq!(
                valid_range_with_options(&range, options),
                expected,
                "valid_range({range}, include_prerelease)"
            );
        }
    }

    #[test]
    fn passes_derived_node_semver_valid_range_loose_subset() {
        let options = RangeOptions {
            include_prerelease: false,
            loose: true,
        };
        for (range, expected) in node_semver_subset().valid_range_loose {
            assert_eq!(
                valid_range_with_options(&range, options),
                expected,
                "valid_range({range}, loose)"
            );
        }
    }

    #[test]
    fn passes_derived_node_semver_valid_range_long_build_metadata_subset() {
        let long_a = "a".repeat(251);
        let long_b = "b".repeat(251);
        let loose_options = RangeOptions {
            include_prerelease: false,
            loose: true,
        };
        let strict_options = RangeOptions::default();
        let cases = [
            (
                format!("4.17.0+{long_a}"),
                "4.17.0",
                loose_options,
                "loose exact long build",
            ),
            (
                format!("1.2.3+{long_a} - 2.0.0"),
                ">=1.2.3 <=2.0.0",
                strict_options,
                "hyphen long build",
            ),
            (
                format!("> 1.2.3+{long_a}"),
                ">1.2.3",
                strict_options,
                "strict comparator long build",
            ),
            (
                format!(">= 1.2.3+{long_a}"),
                ">=1.2.3",
                loose_options,
                "loose comparator long build",
            ),
            (
                format!("~1.2.3+{long_a}"),
                ">=1.2.3 <1.3.0-0",
                strict_options,
                "tilde long build",
            ),
            (
                format!("^1.2.3+{long_a}"),
                ">=1.2.3 <2.0.0-0",
                strict_options,
                "caret long build",
            ),
            (
                format!("v1.0+{}x6", "a".repeat(249)),
                ">=1.0.0 <1.1.0-0",
                strict_options,
                "partial v-prefixed long build",
            ),
            (
                format!("1.2.3+{long_a} || 2.0.0+{long_b}"),
                "1.2.3||2.0.0",
                loose_options,
                "loose union long build",
            ),
        ];

        for (range, expected, options, label) in cases {
            assert_eq!(
                valid_range_with_options(&range, options),
                Some(expected.to_string()),
                "{label}"
            );
        }
    }
}
