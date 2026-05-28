pub fn parse_library_name(lib: String) -> (String, String) {
    if lib.starts_with('@') {
        let without_scope_marker = &lib[1..];
        let Some(slash_index) = without_scope_marker.find('/') else {
            println!("lib error with {}", lib);
            panic!("error: parse library name error");
        };
        let package_end = slash_index + 2;
        let scoped_tail = &lib[package_end..];
        if let Some(version_index) = scoped_tail.find('@') {
            let split_index = package_end + version_index;
            return (lib[..split_index].to_string(), lib[split_index + 1..].to_string());
        }
        return (lib, String::new());
    }

    if let Some((package_name, version)) = lib.split_once('@') {
        return (package_name.to_string(), version.to_string());
    }

    (lib, String::new())
}

#[cfg(test)]
pub(crate) mod test_support {
    use std::{
        fs, io,
        path::{Path, PathBuf},
        time::{SystemTime, UNIX_EPOCH},
    };

    /// Shared helpers for hermetic tests. Keep all fixture reads explicit and
    /// copy mutable inputs into unique temp directories before editing them.
    pub(crate) fn fixture_path(parts: &[&str]) -> PathBuf {
        let mut path = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join("tests")
            .join("fixtures");
        for part in parts {
            path.push(part);
        }
        path
    }

    pub(crate) struct TempProject {
        root: PathBuf,
    }

    impl TempProject {
        pub(crate) fn new(prefix: &str) -> io::Result<Self> {
            let unique_id = SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap()
                .as_nanos();
            let root = std::env::temp_dir().join(format!("rpm-{prefix}-{unique_id}"));
            fs::create_dir_all(&root)?;
            Ok(Self { root })
        }

        pub(crate) fn copy_fixture<P: AsRef<Path>, Q: AsRef<Path>>(
            &self,
            fixture: P,
            destination: Q,
        ) -> io::Result<PathBuf> {
            let destination = self.root.join(destination.as_ref());
            if let Some(parent) = destination.parent() {
                fs::create_dir_all(parent)?;
            }
            fs::copy(fixture.as_ref(), &destination)?;
            Ok(destination)
        }

        pub(crate) fn project_root(&self) -> &Path {
            &self.root
        }
    }

    impl Drop for TempProject {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.root);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_lib_version() {
        let lib = "socket-store@0.0.1";
        let (lib_name, version) = parse_library_name(lib.to_owned());
        assert_eq!(lib_name, "socket-store");
        assert_eq!(version, "0.0.1");
        assert_ne!(version, "0.0.2");
    }
    #[test]
    fn parse_lib_without_version() {
        let lib = "socket-store";
        let (lib_name, version) = parse_library_name(lib.to_owned());
        assert_eq!(lib_name, "socket-store");
        assert_eq!(version, "");
    }

    #[test]
    fn parse_lib_startwith_specific_word() {
        let lib = "@abcd/socket-store";
        let (lib_name, version) = parse_library_name(lib.to_owned());
        assert_eq!(lib_name, "@abcd/socket-store");
        assert_eq!(version, "");
    }
    #[test]
    fn parse_lib_startwith_specific_() {
        let lib = "@abcd/socket-store@1.0.0"; // include a version number
        let (lib_name, version) = parse_library_name(lib.to_owned());
        assert_eq!(lib_name, "@abcd/socket-store");
        assert_eq!(version, "1.0.0");
    }
    #[test]
    fn pasre_lib_version_start_with_specific_word() {
        let lib = "@abcd/socket-store@^1.0.0"; // include a version number
        let (lib_name, version) = parse_library_name(lib.to_owned());
        assert_eq!(lib_name, "@abcd/socket-store");
        assert_eq!(version, "^1.0.0");
    }
    #[test]
    fn parse_test() {
        let lib = "ipaddr.js@1.9.1";
        let (lib_name, version) = parse_library_name(lib.to_owned());
        assert_eq!(lib_name, "ipaddr.js");
        assert_eq!(version, "1.9.1");
    }

    #[test]
    fn parse_lib_preserves_comparator_range() {
        let lib = "@scope/pkg@>=1.0.0 <2.0.0";
        let (lib_name, version) = parse_library_name(lib.to_owned());
        assert_eq!(lib_name, "@scope/pkg");
        assert_eq!(version, ">=1.0.0 <2.0.0");
    }
}
