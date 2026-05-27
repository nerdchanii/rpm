use crate::package_manifest::PackageManifest;
use std::{
    env,
    ffi::OsString,
    fs,
    io::{Error, ErrorKind},
    path::Path,
    process::Command,
};

pub async fn run(script_key: String) -> Result<i32, std::io::Error> {
    let package = PackageManifest::read_default()?;
    run_script(&script_key, &package, Path::new("."))
}

fn run_script(
    script_key: &str,
    package: &PackageManifest,
    project_root: &Path,
) -> Result<i32, std::io::Error> {
    let scripts = package.get_scripts();
    let script = scripts.get(script_key).ok_or_else(|| {
        Error::new(
            ErrorKind::NotFound,
            format!("script not found: {script_key}"),
        )
    })?;

    println!("Running script: {}", script);

    let mut command = shell_command(script);
    command.current_dir(project_root);
    command.env("PATH", script_path(project_root)?);
    let status = command.status().map_err(|error| {
        Error::new(
            error.kind(),
            format!("failed to run script `{script_key}`: {error}"),
        )
    })?;

    Ok(status.code().unwrap_or(1))
}

#[cfg(unix)]
fn shell_command(script: &str) -> Command {
    let mut command = Command::new("/bin/sh");
    command.arg("-c").arg(script);
    command
}

#[cfg(windows)]
fn shell_command(script: &str) -> Command {
    let mut command = Command::new("cmd");
    command.arg("/C").arg(script);
    command
}

fn script_path(project_root: &Path) -> Result<OsString, std::io::Error> {
    let mut paths = vec![fs::canonicalize(project_root)?
        .join("node_modules")
        .join(".bin")];
    if let Some(path) = env::var_os("PATH") {
        paths.extend(env::split_paths(&path));
    }

    env::join_paths(paths).map_err(|error| Error::new(ErrorKind::InvalidInput, error))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::{
        fs,
        os::unix::fs::PermissionsExt,
        path::PathBuf,
        sync::atomic::{AtomicU64, Ordering},
        time::{SystemTime, UNIX_EPOCH},
    };

    static TEMP_PROJECT_ID: AtomicU64 = AtomicU64::new(0);

    struct TempRunProject {
        root: PathBuf,
    }

    impl TempRunProject {
        fn new() -> Self {
            let nanos = SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .map(|duration| duration.as_nanos())
                .unwrap_or(0);
            let counter = TEMP_PROJECT_ID.fetch_add(1, Ordering::SeqCst);
            let root = env::temp_dir().join(format!("rpm-run-{}-{nanos}", std::process::id()));
            let root = root.with_extension(counter.to_string());
            fs::create_dir_all(&root).unwrap();
            Self { root }
        }

        fn write_manifest(&self, scripts: &[(&str, &str)]) -> PackageManifest {
            let scripts = scripts
                .iter()
                .map(|(key, value)| format!("\"{key}\": \"{value}\""))
                .collect::<Vec<_>>()
                .join(", ");
            fs::write(
                self.root.join("package.json"),
                format!("{{\"scripts\": {{{scripts}}}}}"),
            )
            .unwrap();
            PackageManifest::read_from_path(self.root.join("package.json")).unwrap()
        }
    }

    impl Drop for TempRunProject {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.root);
        }
    }

    #[test]
    fn missing_script_does_not_mutate_node_modules() {
        let temp = TempRunProject::new();
        let package = temp.write_manifest(&[]);
        let existing_file = temp.root.join("node_modules").join("keep.txt");
        fs::create_dir_all(existing_file.parent().unwrap()).unwrap();
        fs::write(&existing_file, "existing").unwrap();

        let error = run_script("missing", &package, &temp.root).unwrap_err();

        assert_eq!(error.kind(), ErrorKind::NotFound);
        assert_eq!(fs::read_to_string(existing_file).unwrap(), "existing");
    }

    #[test]
    fn script_uses_shell_semantics() {
        let temp = TempRunProject::new();
        let package =
            temp.write_manifest(&[("build", "echo one > out.txt && echo two >> out.txt")]);

        let status = run_script("build", &package, &temp.root).unwrap();

        assert_eq!(status, 0);
        assert_eq!(
            fs::read_to_string(temp.root.join("out.txt")).unwrap(),
            "one\ntwo\n"
        );
    }

    #[test]
    fn script_path_includes_node_modules_bin() {
        let temp = TempRunProject::new();
        let bin = temp
            .root
            .join("node_modules")
            .join(".bin")
            .join("fixture-bin");
        fs::create_dir_all(bin.parent().unwrap()).unwrap();
        fs::write(&bin, "#!/bin/sh\necho bin-ok > bin.txt\n").unwrap();
        let mut permissions = fs::metadata(&bin).unwrap().permissions();
        permissions.set_mode(0o755);
        fs::set_permissions(&bin, permissions).unwrap();
        let package = temp.write_manifest(&[("bin", "fixture-bin")]);

        let status = run_script("bin", &package, &temp.root).unwrap();

        assert_eq!(status, 0);
        assert_eq!(
            fs::read_to_string(temp.root.join("bin.txt")).unwrap(),
            "bin-ok\n"
        );
    }

    #[test]
    fn script_status_is_preserved() {
        let temp = TempRunProject::new();
        let package = temp.write_manifest(&[("fail", "exit 7")]);

        let status = run_script("fail", &package, &temp.root).unwrap();

        assert_eq!(status, 7);
    }

    #[test]
    fn missing_binary_returns_shell_status() {
        let temp = TempRunProject::new();
        let package = temp.write_manifest(&[("missing-bin", "definitely-not-rpm-fixture-bin")]);

        let status = run_script("missing-bin", &package, &temp.root).unwrap();

        assert_ne!(status, 0);
    }

    #[test]
    fn package_bin_named_sh_does_not_replace_shell() {
        let temp = TempRunProject::new();
        let fake_sh = temp.root.join("node_modules").join(".bin").join("sh");
        fs::create_dir_all(fake_sh.parent().unwrap()).unwrap();
        fs::write(&fake_sh, "#!/bin/sh\nexit 42\n").unwrap();
        let mut permissions = fs::metadata(&fake_sh).unwrap().permissions();
        permissions.set_mode(0o755);
        fs::set_permissions(&fake_sh, permissions).unwrap();
        let package = temp.write_manifest(&[("shell", "echo shell-ok > shell.txt")]);

        let status = run_script("shell", &package, &temp.root).unwrap();

        assert_eq!(status, 0);
        assert_eq!(
            fs::read_to_string(temp.root.join("shell.txt")).unwrap(),
            "shell-ok\n"
        );
    }

    #[test]
    fn script_path_stays_valid_after_cd() {
        let temp = TempRunProject::new();
        let bin = temp
            .root
            .join("node_modules")
            .join(".bin")
            .join("fixture-bin");
        fs::create_dir_all(bin.parent().unwrap()).unwrap();
        fs::create_dir_all(temp.root.join("workspace")).unwrap();
        fs::write(&bin, "#!/bin/sh\necho cd-ok > ../cd.txt\n").unwrap();
        let mut permissions = fs::metadata(&bin).unwrap().permissions();
        permissions.set_mode(0o755);
        fs::set_permissions(&bin, permissions).unwrap();
        let package = temp.write_manifest(&[("cd-bin", "cd workspace && fixture-bin")]);

        let status = run_script("cd-bin", &package, &temp.root).unwrap();

        assert_eq!(status, 0);
        assert_eq!(
            fs::read_to_string(temp.root.join("cd.txt")).unwrap(),
            "cd-ok\n"
        );
    }
}
