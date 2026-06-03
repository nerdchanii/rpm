pub(crate) mod coerce;
pub(crate) mod compare;
mod construct;
mod display;
pub(crate) mod increment;
pub(crate) mod normalize;
mod ordering;
pub(crate) mod parse;

mod types;

pub use types::Version;
pub(crate) use types::{PrereleaseIdentifier, MAX_SAFE_COMPONENT, MAX_VERSION_LENGTH};
