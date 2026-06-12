pub(crate) mod compare;
pub(crate) mod increment;
pub(crate) mod range;
pub(crate) mod select;

pub use crate::core::resolver::semver::version::coerce::{
    coerce, coerce_number, coerce_number_with_options, coerce_rtl, coerce_with_options,
};
pub use compare::*;
pub use increment::*;
pub use range::*;
pub use select::*;
