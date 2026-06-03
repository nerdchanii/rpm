use std::fmt;

use super::{PrereleaseIdentifier, Version};

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
