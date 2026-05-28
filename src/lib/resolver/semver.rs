use std::{
    cmp::Reverse,
    io::{Error, ErrorKind},
};

use node_semver::{Range, Version};

use crate::registry::Registry;

pub(crate) fn select_version(metadata: &Registry, requested: &str) -> std::io::Result<String> {
    let requested = requested.trim();

    if requested.is_empty() || requested == "latest" {
        return metadata.latest_tag_version().cloned().ok_or_else(|| {
            Error::new(
                ErrorKind::InvalidData,
                format!("missing latest dist-tag for {}", metadata.name),
            )
        });
    }

    let range: Range = requested.parse().map_err(|error| {
        Error::new(
            ErrorKind::InvalidInput,
            format!("invalid semver range {requested} for {}: {error}", metadata.name),
        )
    })?;

    let versions = metadata
        .available_versions()
        .into_iter()
        .filter(|version| !is_prerelease(version))
        .map(|version| {
            version
                .parse::<Version>()
                .map(|parsed| (version.to_string(), parsed))
                .map_err(|error| {
                    Error::new(
                        ErrorKind::InvalidData,
                        format!(
                            "invalid version {version} in metadata for {}: {error}",
                            metadata.name
                        ),
                    )
                })
        })
        .collect::<Result<Vec<_>, _>>()?;

    let mut matches = versions
        .into_iter()
        .filter(|(_, version)| version.satisfies(&range))
        .collect::<Vec<_>>();
    matches.sort_by_key(|(_, version)| Reverse(version.clone()));

    matches
        .into_iter()
        .map(|(version, _)| version)
        .next()
        .ok_or_else(|| {
            Error::new(
                ErrorKind::InvalidInput,
                format!(
                    "no version in {} satisfies requested range {requested}",
                    metadata.name
                ),
            )
        })
}

fn is_prerelease(version: &str) -> bool {
    version.contains('-')
}

#[cfg(test)]
mod tests {
    use super::select_version;
    use crate::{registry::load_fixture_registry, util::test_support::fixture_path};

    #[test]
    fn selects_supported_m1_semver_ranges_from_fixtures() {
        let fixture_root = fixture_path(&["install-projects", "semver-baseline", "registry"]);
        let cases = [
            ("@rpm-fixture/exact", "1.2.3", "1.2.3"),
            ("@rpm-fixture/caret", "^1.2.3", "1.9.9"),
            ("@rpm-fixture/caret-zero", "^0.2.0", "0.2.9"),
            ("@rpm-fixture/tilde", "~1.2.3", "1.2.9"),
            ("@rpm-fixture/wildcard", "*", "3.0.0"),
            ("@rpm-fixture/wildcard-major", "1.x", "1.9.0"),
            ("@rpm-fixture/wildcard-minor", "1.2.x", "1.2.9"),
            ("@rpm-fixture/comparator", ">=1.0.0 <2.0.0", "1.5.0"),
        ];

        for (package, requested, expected) in cases {
            let metadata = load_fixture_registry(&fixture_root, package).unwrap();
            let selected = select_version(&metadata, requested).unwrap();
            assert_eq!(selected, expected, "{package} should select {expected}");
        }
    }

    #[test]
    fn rejects_invalid_or_unsatisfied_ranges() {
        let invalid_root = fixture_path(&["install-projects", "semver-invalid-range", "registry"]);
        let invalid_metadata =
            load_fixture_registry(&invalid_root, "@rpm-fixture/invalid-range").unwrap();
        let invalid_error = select_version(&invalid_metadata, "not-a-range").unwrap_err();
        assert!(invalid_error.to_string().contains("invalid semver range"));

        let unsatisfied_root =
            fixture_path(&["install-projects", "semver-unsatisfied", "registry"]);
        let unsatisfied_metadata =
            load_fixture_registry(&unsatisfied_root, "@rpm-fixture/unsatisfied").unwrap();
        let unsatisfied_error =
            select_version(&unsatisfied_metadata, ">=9.0.0 <10.0.0").unwrap_err();
        assert!(unsatisfied_error.to_string().contains("no version"));
    }
}
