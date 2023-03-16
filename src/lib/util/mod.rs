use regex::Regex;

pub fn parse_library_name(lib: String) -> (String, String) {
    println!("lib: {}", lib);
    let regex =
        Regex::new(r"^(?P<package_name>@?[^@]*)(@\^?(?P<version>\d+\.\d+\.\d+))?$").unwrap();
    if let Some(captures) = regex.captures(&lib) {
        let package_name = captures.name("package_name").unwrap().as_str().to_owned();
        let version = captures
            .name("version")
            .map_or("", |m| m.as_str())
            .to_owned();
        return (package_name, version);
    }
    panic!("error: parse library name error");
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
        assert_eq!(version, "1.0.0");
    }
}
