use regex::Regex;

pub fn parse_library_name(lib: String) -> (String, String) {
    let regex = Regex::new(r"^(?P<package_name>@?[^@]*)(@(?P<version>.+))?$").unwrap();

    if let Some(captures) = regex.captures(&lib) {
        let package_name = captures.name("package_name").unwrap().as_str().to_owned();
        let version = captures
            .name("version")
            .map(|m| m.as_str())
            .unwrap_or_else(|| "")
            .to_owned();
        // version ex) >=1.0.1 < 3
        let version_regex = Regex::new(r"^(?P<version>[^<>=]+)").unwrap();
        let version = version_regex
            .captures(&version)
            .map(|m| m.name("version").unwrap().as_str().to_owned())
            .unwrap_or_else(|| "".to_owned());

        return (package_name, version);
    }

    println!("lib error with {}", lib);
    panic!("error: parse library name error");
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
}
