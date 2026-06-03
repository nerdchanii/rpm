use thiserror::Error;

#[derive(Debug, Error, Clone, PartialEq, Eq)]
/// Error returned by semver parsing, comparison, and selection operations.
pub enum SemverError {
    /// The version input is invalid.
    #[error("invalid version {0}")]
    InvalidVersion(String),
    /// The range input is invalid.
    #[error("invalid range {0}")]
    InvalidRange(String),
    /// The comparison operator is invalid.
    #[error("invalid operator {0}")]
    InvalidOperator(String),
    /// No candidate version satisfies the requested range.
    #[error("unsatisfied range {range}")]
    UnsatisfiedRange { range: String },
}
