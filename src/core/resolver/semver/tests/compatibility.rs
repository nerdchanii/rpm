use crate::core::resolver::semver::{
    clean, cmp, cmp_with_options, coerce, coerce_number, coerce_rtl, coerce_with_options, compare,
    compare_build, compare_identifiers, compare_loose, eq, eq_with_options, gt, gt_with_options,
    gte, gte_with_options, gtr, gtr_with_options, inc, inc_with_identifier,
    inc_with_identifier_base, inc_with_options, lt, lt_with_options, lte, lte_with_options, ltr,
    ltr_with_options, major, major_with_options, max_satisfying, min_satisfying, minor,
    minor_with_options, neq, neq_with_options, outside, outside_with_options, patch,
    patch_with_options, prerelease, prerelease_with_options, rcompare, rcompare_identifiers, rsort,
    rsort_with_options, satisfies, satisfies_with_options, simplify_range,
    simplify_range_with_options, sort, sort_with_options, subset, subset_with_options, valid,
    valid_range, valid_range_with_options, CoerceOptions, Range, RangeOptions, Version,
    VersionOptions,
};
use crate::core::resolver::semver::{max_satisfying_with_options, min_satisfying_with_options};
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
        include_str!("../../../../../tests/fixtures/semver/node-semver/compatibility-subset.json");
    serde_json::from_str(fixture).expect("node-semver compatibility subset fixture is valid")
}

#[test]
fn compares_versions_with_prerelease_ordering() {
    assert!("1.0.0".parse::<Version>().unwrap() > "1.0.0-rc.1".parse::<Version>().unwrap());
    assert!(
        "1.0.0-beta.2".parse::<Version>().unwrap() > "1.0.0-beta.1".parse::<Version>().unwrap()
    );
    assert_eq!(
        "1.0.0+build.1".parse::<Version>().unwrap(),
        "1.0.0".parse::<Version>().unwrap()
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
fn exposes_rust_typed_parse_api() {
    let parsed_version = "1.2.3-alpha.1+build.5".parse::<Version>().unwrap();
    assert_eq!(parsed_version.to_string(), "1.2.3-alpha.1+build.5");

    let parsed_range = "^1.2.3".parse::<Range>().unwrap();
    assert!(parsed_range.satisfies(&"1.9.9".parse::<Version>().unwrap()));
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
            crate::core::resolver::semver::valid_with_options(&version, options),
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
            base => {
                inc_with_identifier_base(&case.version, &case.release_type, &case.identifier, base)
            }
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
            crate::core::resolver::semver::diff(&left, &right).unwrap(),
            expected.as_deref(),
            "diff({left}, {right})"
        );
    }
}

#[test]
fn passes_derived_node_semver_truncate_subset() {
    for (version, release_type, expected) in node_semver_subset().truncate {
        assert_eq!(
            crate::core::resolver::semver::truncate(&version, &release_type),
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
            crate::core::resolver::semver::intersects(&left, &right).unwrap(),
            expected,
            "intersects({left}, {right})"
        );
        assert_eq!(
            crate::core::resolver::semver::intersects(&right, &left).unwrap(),
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
            crate::core::resolver::semver::min_version(&range).unwrap(),
            expected,
            "min_version({range})"
        );
    }
}

#[test]
fn passes_derived_node_semver_to_comparators_subset() {
    for (range, expected) in node_semver_subset().to_comparators {
        assert_eq!(
            crate::core::resolver::semver::to_comparators(&range).unwrap(),
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
