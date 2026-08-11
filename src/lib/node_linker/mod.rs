use std::{
    fs::{self, File},
    io::{Error, ErrorKind, Write},
    os::unix::fs::symlink,
    path::{Component, Path, PathBuf},
    thread::sleep,
    time::{SystemTime, UNIX_EPOCH},
};

use crate::{
    common::constraint::CACHE_DIR,
    lockfile::constraint::LOCK_FILE_PATH,
    lockfile::{Dependency, LockFile},
    package_manifest::{BinField, PackageManifest},
    registry::tarball_cache_file_name,
};
use flate2::read::GzDecoder;
use tar::Archive;

mod scripts;

#[derive(Debug)]
pub struct NodeModules {
    pub path: PathBuf,
}

pub(crate) struct PreparedNodeModules {
    target: PathBuf,
    staging: Option<PathBuf>,
}

impl PreparedNodeModules {
    pub(crate) fn publish(mut self) -> Result<NodeModules, std::io::Error> {
        let Some(staging) = self.staging.take() else {
            return Ok(NodeModules::new(self.target.clone()));
        };
        if let Err(error) = replace_node_modules(&self.target, &staging) {
            let _ = fs::remove_dir_all(&staging);
            return Err(error);
        }
        Ok(NodeModules::new(self.target.clone()))
    }
}

impl Drop for PreparedNodeModules {
    fn drop(&mut self) {
        if let Some(staging) = &self.staging {
            let _ = fs::remove_dir_all(staging);
        }
    }
}

impl NodeModules {
    pub fn new(path: PathBuf) -> Self {
        Self { path }
    }

    pub fn read_package(package_name: &str) -> Result<PackageManifest, std::io::Error> {
        let node_module = PathBuf::from("node_modules");
        let path = node_module.join(package_name).join("package.json");
        PackageManifest::read_from_path(path)
    }

    pub fn get_path(&self) -> PathBuf {
        self.path.clone()
    }

    pub fn get_destination(&mut self, name: String) -> PathBuf {
        self.path.join(name)
    }

    pub fn init() -> Result<Self, std::io::Error> {
        let root_manifest = PackageManifest::read_default()?;
        Self::init_from_paths("node_modules", LOCK_FILE_PATH, CACHE_DIR, &root_manifest)
    }

    pub(crate) fn init_from_paths<P, Q, R>(
        node_modules_path: P,
        lockfile_path: Q,
        cache_dir: R,
        root_manifest: &PackageManifest,
    ) -> Result<Self, std::io::Error>
    where
        P: AsRef<Path>,
        Q: AsRef<Path>,
        R: AsRef<Path>,
    {
        let lock_file = LockFile::load_from_path(lockfile_path)
            .map_err(|error| phase_error("resolve", error))?;
        Self::init_from_lockfile(node_modules_path, &lock_file, cache_dir, root_manifest)
    }

    pub(crate) fn init_from_lockfile<P, R>(
        node_modules_path: P,
        lock_file: &LockFile,
        cache_dir: R,
        root_manifest: &PackageManifest,
    ) -> Result<Self, std::io::Error>
    where
        P: AsRef<Path>,
        R: AsRef<Path>,
    {
        Self::prepare_from_lockfile(node_modules_path, lock_file, cache_dir, root_manifest)?
            .publish()
    }

    pub(crate) fn prepare_from_lockfile<P, R>(
        node_modules_path: P,
        lock_file: &LockFile,
        cache_dir: R,
        root_manifest: &PackageManifest,
    ) -> Result<PreparedNodeModules, std::io::Error>
    where
        P: AsRef<Path>,
        R: AsRef<Path>,
    {
        let dir = node_modules_path.as_ref();
        let staging_dir = staging_path(dir);
        if staging_dir.exists() {
            fs::remove_dir_all(&staging_dir).map_err(|error| phase_error("write", error))?;
        }
        fs::create_dir_all(&staging_dir).map_err(|error| phase_error("write", error))?;

        let packages = lock_file.get_packages();
        let project_root = dir
            .parent()
            .filter(|path| !path.as_os_str().is_empty())
            .unwrap_or_else(|| Path::new("."));

        // The `scripts` phase runs between `link` and `write`
        // (`docs/specs/core/install/scripts/SPEC.md`). A hook failure returns
        // an error here so `replace_node_modules` is never reached: the staged
        // tree is discarded below and the previous `node_modules` stays in
        // place, preserving the recovery contract.
        let result = if packages.is_empty() {
            let result = scripts::run_lifecycle_scripts(
                project_root,
                &staging_dir,
                &packages,
                root_manifest,
            )
            .map_err(|error| phase_error("scripts", error));
            if result.is_ok() {
                fs::remove_dir_all(&staging_dir)
                    .map(|_| None)
                    .map_err(|error| phase_error("write", error))
            } else {
                result.map(|_| None)
            }
        } else {
            Self::build_staged(&staging_dir, lock_file, cache_dir)
                .and_then(|_| {
                    scripts::run_lifecycle_scripts(
                        project_root,
                        &staging_dir,
                        &packages,
                        root_manifest,
                    )
                    .map_err(|error| phase_error("scripts", error))
                })
                .map(|_| Some(staging_dir.clone()))
        };

        if result.is_err() {
            let _ = fs::remove_dir_all(&staging_dir);
        }

        result.map(|staging| PreparedNodeModules {
            target: dir.to_path_buf(),
            staging,
        })
    }

    fn build_staged<P, R>(
        staging_dir: P,
        lock_file: &LockFile,
        cache_dir: R,
    ) -> Result<Self, std::io::Error>
    where
        P: AsRef<Path>,
        R: AsRef<Path>,
    {
        let mut modules = Self::new(staging_dir.as_ref().to_path_buf());
        let packages = lock_file.get_packages();
        if packages.is_empty() {
            return Err(phase_error(
                "resolve",
                Error::new(ErrorKind::InvalidData, "lockfile has no packages to link"),
            ));
        }
        let cache_resolver = NodeResolver::new(cache_dir.as_ref().to_path_buf());
        cache_resolver
            .resolve_deps(&mut modules, &packages)
            .map_err(|error| phase_error("extract", error))?;
        modules
            .linking(&packages)
            .map_err(|error| phase_error("link", error))?;
        modules
            .link_bins(&packages)
            .map_err(|error| phase_error("link", error))?;
        Ok(modules)
    }

    // symbolic_linking
    pub fn linking(&self, deps: &[(&String, &Dependency)]) -> Result<(), std::io::Error> {
        for (key, dependency) in deps {
            print!("linking: {} ", key);
            std::io::stdout().flush()?;
            sleep(std::time::Duration::from_millis(1));
            print!("\r\x1B[K");
            let name = package_name_from_lock_key(key)?;
            let root = self.get_path();
            for dep_name in dependency.get_dependencies_name() {
                validate_package_name(&dep_name, &dep_name)?;
                let destination = root.join(name).join("node_modules").join(&dep_name);
                let dest_node_modules = destination.parent().ok_or_else(|| {
                    Error::new(
                        ErrorKind::InvalidInput,
                        format!("dependency destination has no parent: {destination:?}"),
                    )
                })?;
                fs::metadata(root.join(&dep_name))?;
                let link_path = dependency_link_target(name, &dep_name);
                if !dest_node_modules.exists() {
                    fs::create_dir_all(dest_node_modules)?;
                }

                if !destination.exists() {
                    symlink(link_path, destination)?;
                }
            }
        }
        Ok(())
    }

    /// Generate `node_modules/.bin` links for every resolved package that
    /// declares a `bin` field. The link layout and confinement rules are owned
    /// by `docs/specs/core/linker/SPEC.md`; the `bin` field shape is owned by
    /// `docs/specs/core/manifest/SPEC.md`. Only resolved packages with an
    /// installed directory under `node_modules/` receive `.bin` links; the root
    /// project has no installed directory and is skipped.
    pub fn link_bins(&self, deps: &[(&String, &Dependency)]) -> Result<(), std::io::Error> {
        let root = self.get_path();
        let bin_dir = root.join(".bin");
        for (key, _dependency) in deps {
            let package_dir_name = package_name_from_lock_key(key)?;
            let package_dir = root.join(package_dir_name);
            let manifest_path = package_dir.join("package.json");
            // A missing package.json is treated as a package with no bin field:
            // the extraction step owns reporting missing packages, and a package
            // legitimately may have no manifest-side bin declaration.
            let manifest = match PackageManifest::read_from_path(&manifest_path) {
                Ok(manifest) => manifest,
                Err(error) if error.kind() == ErrorKind::NotFound => continue,
                Err(error) => return Err(error),
            };
            let Some(bin_field) = manifest.get_bin() else {
                continue;
            };
            let entries = resolve_bin_entries(package_dir_name, bin_field)?;
            if entries.is_empty() {
                continue;
            }
            if !bin_dir.exists() {
                fs::create_dir_all(&bin_dir)?;
            }
            for (binary_name, target_file) in entries {
                let resolved_target = package_dir.join(&target_file);
                let canonical_target = resolve_bin_target(&package_dir, &target_file)?;
                if !canonical_target.exists() {
                    return Err(Error::new(
                        ErrorKind::NotFound,
                        format!(
                            "bin target {target_file} for package {package_dir_name} does not exist at {}",
                            resolved_target.display()
                        ),
                    ));
                }
                let link_path = bin_link_target(package_dir_name, &target_file);
                let destination = bin_dir.join(&binary_name);
                if destination.exists() || destination.is_symlink() {
                    fs::remove_file(&destination)?;
                }
                symlink(&link_path, &destination)?;
            }
        }
        Ok(())
    }
}

fn phase_error(phase: &str, error: std::io::Error) -> std::io::Error {
    Error::new(error.kind(), format!("{phase} failed: {error}"))
}

fn staging_path(node_modules_path: &Path) -> PathBuf {
    let parent = node_modules_path
        .parent()
        .filter(|path| !path.as_os_str().is_empty())
        .unwrap_or_else(|| Path::new("."));
    parent.join(format!(".node_modules.rpm-staging-{}", unique_suffix()))
}

fn backup_path(node_modules_path: &Path) -> PathBuf {
    let parent = node_modules_path
        .parent()
        .filter(|path| !path.as_os_str().is_empty())
        .unwrap_or_else(|| Path::new("."));
    parent.join(format!(".node_modules.rpm-backup-{}", unique_suffix()))
}

fn unique_suffix() -> String {
    let nanos = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|duration| duration.as_nanos())
        .unwrap_or(0);
    format!("{}-{nanos}", std::process::id())
}

fn replace_node_modules(target: &Path, staging_dir: &Path) -> Result<(), std::io::Error> {
    let backup_dir = backup_path(target);
    if backup_dir.exists() {
        fs::remove_dir_all(&backup_dir).map_err(|error| phase_error("write", error))?;
    }

    if target.exists() {
        fs::rename(target, &backup_dir).map_err(|error| phase_error("write", error))?;
    }

    match fs::rename(staging_dir, target) {
        Ok(()) => {
            if backup_dir.exists() {
                fs::remove_dir_all(&backup_dir).map_err(|error| phase_error("write", error))?;
            }
            Ok(())
        }
        Err(error) => {
            if backup_dir.exists() {
                let _ = fs::rename(&backup_dir, target);
            }
            Err(phase_error("write", error))
        }
    }
}

fn dependency_link_target(parent_name: &str, dependency_name: &str) -> PathBuf {
    let up_levels = Path::new(parent_name).components().count()
        + Path::new(dependency_name).components().count();
    let mut target = PathBuf::new();
    for _ in 0..up_levels {
        target.push("..");
    }
    target.join(dependency_name)
}

/// Compute the symlink target for a `.bin` link, relative to the
/// `node_modules/.bin/` directory. For a package installed at
/// `node_modules/<package-dir>` and a target file `<target-file>` inside it,
/// the link is `../<package-dir>/<target-file>`. Both `.bin` and the package
/// directory are direct children of `node_modules`, so a single `..` reaches
/// the package directory from `.bin`. Scoped package directories keep their
/// `@scope/` component verbatim.
fn bin_link_target(package_dir_name: &str, target_file: &str) -> PathBuf {
    use std::path::Component;
    // Collapse redundant `.` components in the target so `./cli.js` and
    // `cli.js` produce the same link path; `..` has already been rejected by
    // the traversal guard before this function runs.
    let mut cleaned = PathBuf::new();
    for component in Path::new(target_file).components() {
        if let Component::Normal(part) = component {
            cleaned.push(part);
        }
    }
    PathBuf::from("..").join(package_dir_name).join(cleaned)
}

/// Resolve a `bin` field into `(binary_name, target_file)` pairs following npm
/// semantics owned by `docs/specs/core/linker/SPEC.md`:
///
/// - Unscoped package, string form: one binary named after the package.
/// - Unscoped package, object form: one binary per map key.
/// - Scoped package (`@scope/name`), string form: one binary named after the
///   unscoped name (`name`, with the `@scope/` prefix dropped).
/// - Scoped package, object form: one binary per map key, used verbatim.
///
/// Binary names must be a single path component: not empty, not absolute, and
/// containing no separator (`/` or `\`) or parent-reference (`..`). A violating
/// name is a link input error.
fn resolve_bin_entries(
    package_dir_name: &str,
    bin_field: &BinField,
) -> Result<Vec<(String, String)>, std::io::Error> {
    match bin_field {
        BinField::String(target_file) => {
            let binary_name = unscoped_binary_name(package_dir_name);
            validate_binary_name(&binary_name)?;
            validate_target_not_empty(&binary_name, target_file)?;
            Ok(vec![(binary_name, target_file.clone())])
        }
        BinField::Object(map) => {
            let mut entries = Vec::new();
            for (binary_name, target_file) in map {
                validate_binary_name(binary_name)?;
                validate_target_not_empty(binary_name, target_file)?;
                entries.push((binary_name.clone(), target_file.clone()));
            }
            Ok(entries)
        }
    }
}

/// Drop the `@scope/` prefix from a scoped package directory name to produce
/// the binary name for string-form `bin`. An unscoped name is returned as-is.
fn unscoped_binary_name(package_dir_name: &str) -> String {
    match package_dir_name.split_once('/') {
        Some((scope, name)) if scope.starts_with('@') => name.to_string(),
        _ => package_dir_name.to_string(),
    }
}

/// Reject a binary name that is not a single path component: empty, absolute,
/// separator-containing, or parent-referencing. Package-controlled metadata
/// must not place a `.bin` entry outside `node_modules/.bin/`.
fn validate_binary_name(binary_name: &str) -> Result<(), std::io::Error> {
    if binary_name.is_empty() {
        return Err(Error::new(
            ErrorKind::InvalidInput,
            "bin binary name must not be empty",
        ));
    }
    if binary_name == ".." || binary_name.contains('/') || binary_name.contains('\\') {
        return Err(Error::new(
            ErrorKind::InvalidInput,
            format!("bin binary name must be a single path component: {binary_name}"),
        ));
    }
    // An absolute name on Unix starts with `/`; on Windows a verbatim `\\`
    // prefix or a drive root (for example `C:`) would also be absolute. The
    // separator check above already rejects backslash-led names; this catches
    // the Unix-absolute case explicitly.
    if Path::new(binary_name).is_absolute() {
        return Err(Error::new(
            ErrorKind::InvalidInput,
            format!("bin binary name must not be absolute: {binary_name}"),
        ));
    }
    Ok(())
}

fn validate_target_not_empty(binary_name: &str, target_file: &str) -> Result<(), std::io::Error> {
    if target_file.trim().is_empty() {
        return Err(Error::new(
            ErrorKind::InvalidInput,
            format!("bin target for {binary_name} must not be empty"),
        ));
    }
    Ok(())
}

/// Resolve a `bin` target file inside the package directory and reject a target
/// that, after symlink and `..` normalization, escapes the package root. The
/// returned path is the canonical target location the linker will verify
/// exists; it is not used verbatim as the link target (links store the relative
/// path declared by the package).
///
/// The traversal guard follows symlinks so an in-package symlink that resolves
/// outside the package root is also rejected, matching
/// `docs/specs/core/linker/SPEC.md`.
fn resolve_bin_target(package_dir: &Path, target_file: &str) -> Result<PathBuf, std::io::Error> {
    // Reject an absolute target outright: it cannot be expressed as a path
    // inside the package directory.
    if Path::new(target_file).is_absolute() {
        return Err(Error::new(
            ErrorKind::InvalidInput,
            format!("bin target {target_file} must be relative to the package directory"),
        ));
    }
    // Canonicalize the package directory so the starts_with comparison uses the
    // same prefix the target's canonical form resolves to. On macOS, for
    // example, `/var/folders/...` canonicalizes to `/private/var/folders/...`,
    // and comparing a canonical target against the raw package directory would
    // always fail.
    let canonical_package = fs::canonicalize(package_dir)?;
    let normalized = normalize_within_root(&canonical_package, target_file);
    if !normalized.starts_with(&canonical_package) {
        return Err(Error::new(
            ErrorKind::InvalidInput,
            format!(
                "bin target {target_file} escapes package directory {}",
                package_dir.display()
            ),
        ));
    }
    // If the target exists, canonicalize it (following symlinks) and re-check
    // the ancestor relationship so an in-package symlink that points outside
    // the package root is rejected too. A missing target returns the lexically
    // normalized path; the caller decides whether missingness is a failure.
    let target_path = package_dir.join(target_file);
    match fs::canonicalize(&target_path) {
        Ok(canonical) => {
            if !canonical.starts_with(&canonical_package) {
                return Err(Error::new(
                    ErrorKind::InvalidInput,
                    format!(
                        "bin target {target_file} resolves outside package directory {}",
                        package_dir.display()
                    ),
                ));
            }
            Ok(canonical)
        }
        Err(error) if error.kind() == ErrorKind::NotFound => Ok(normalized),
        Err(error) => Err(error),
    }
}

/// Lexically normalize a relative `target_file` joined onto `root`, collapsing
/// `.` and `..` components without touching the filesystem. A target that
/// climbs above `root` yields a path that no longer `starts_with(root)` so the
/// caller can reject it; this catches escapes (for example `../outside.js`)
/// even when the referenced file does not exist.
fn normalize_within_root(root: &Path, target_file: &str) -> PathBuf {
    use std::path::Component;
    let mut result = root.to_path_buf();
    let mut escaped = false;
    for component in Path::new(target_file).components() {
        if escaped {
            break;
        }
        match component {
            Component::CurDir => {}
            Component::ParentDir => {
                // Pop only while the result is strictly below the root. A `..`
                // at or above the root means the target escapes; stop and mark
                // it so the caller's starts_with(root) check fails.
                if result.parent().is_some() && result != root {
                    result.pop();
                } else {
                    escaped = true;
                }
            }
            Component::Normal(part) => result.push(part),
            Component::RootDir | Component::Prefix(_) => {
                // Absolute targets are rejected by the caller before reaching
                // here; reset the buffer defensively so they still fail the
                // starts_with(root) check.
                escaped = true;
            }
        }
    }
    if escaped {
        // Return a path that provably does not start with root.
        PathBuf::from("/__rpm_bin_escape__")
    } else {
        result
    }
}

fn package_name_from_lock_key(key: &str) -> Result<&str, std::io::Error> {
    let name = key
        .rsplit_once('@')
        .map(|(name, _version)| name)
        .filter(|name| !name.is_empty())
        .ok_or_else(|| Error::new(ErrorKind::InvalidData, format!("invalid lock key: {key}")))?;
    validate_package_name(name, key)?;
    Ok(name)
}

fn validate_package_name(name: &str, key: &str) -> Result<(), std::io::Error> {
    let parts = name.split('/').collect::<Vec<_>>();
    let valid_shape = match parts.as_slice() {
        [unscoped] => !unscoped.is_empty() && !unscoped.starts_with('@'),
        [scope, package] => scope.starts_with('@') && scope.len() > 1 && !package.is_empty(),
        _ => false,
    };
    if !valid_shape
        || name.contains('\\')
        || Path::new(name).is_absolute()
        || Path::new(name).components().any(|component| {
            matches!(
                component,
                Component::CurDir
                    | Component::ParentDir
                    | Component::RootDir
                    | Component::Prefix(_)
            )
        })
    {
        return Err(Error::new(
            ErrorKind::InvalidData,
            format!("invalid package name in lock key: {key}"),
        ));
    }
    Ok(())
}

struct NodeResolver {
    cache_dir: PathBuf,
}

impl NodeResolver {
    fn new(cache_dir: PathBuf) -> Self {
        Self { cache_dir }
    }

    fn resolve_deps(
        &self,
        node_module: &mut NodeModules,
        dependencies: &Vec<(&String, &Dependency)>,
    ) -> Result<(), std::io::Error> {
        for (key, dependency) in dependencies {
            print!("resolving: {} ", key);
            std::io::stdout().flush()?;
            sleep(std::time::Duration::from_millis(1));
            print!("\r\x1B[K");

            self.resolve_tgz(node_module, key.to_string(), dependency.to_owned())?;

            // .expect(format!("resolve tgz error {}", key).as_str());
        }
        Ok(())
    }

    fn resolve_tgz(
        &self,
        node_module: &mut NodeModules,
        key: String,
        dependency: &Dependency,
    ) -> Result<(), std::io::Error> {
        let name = package_name_from_lock_key(&key)?;
        let cached_version = dependency.get_version();
        let tgz_path = self
            .cache_dir
            .join(tarball_cache_file_name(name, &cached_version));
        let tgz = File::open(tgz_path)?;
        let gz = GzDecoder::new(tgz);
        let mut archive = Archive::new(gz);

        let destination = node_module.get_destination(name.to_string());

        if !destination.exists() {
            archive.unpack(&destination)?;
        };
        let pkg_path = destination.join("package");

        if pkg_path.exists() {
            for entry in pkg_path.read_dir()? {
                let entry = entry?;

                fs::rename(entry.path(), destination.join(entry.file_name()))?;
            }
        }
        if destination.read_dir()?.count() == 1 {
            // 만약 파일을 resolve했을때, nodemodules/pkg/pkg 이렇게 되어있는 경우
            // node_module/pkg을 pkg로 옮겨준다.
            for entry in destination
                .join(name.rsplit('/').next().ok_or_else(|| {
                    Error::new(
                        ErrorKind::InvalidData,
                        format!("invalid package name: {name}"),
                    )
                })?)
                .read_dir()?
            {
                let entry = entry?;

                fs::rename(entry.path(), destination.join(entry.file_name()))?;
            }
        }

        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use flate2::{write::GzEncoder, Compression};
    use std::{
        fs,
        time::{SystemTime, UNIX_EPOCH},
    };
    use tar::{Builder, Header};

    struct TempNodeModules {
        path: PathBuf,
    }

    impl TempNodeModules {
        fn new() -> Self {
            let nanos = SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .map(|duration| duration.as_nanos())
                .unwrap_or(0);
            let path = std::env::temp_dir()
                .join(format!("rpm-node-linker-{}-{nanos}", std::process::id()));
            fs::create_dir_all(path.join("node_modules")).unwrap();
            Self { path }
        }

        fn node_modules(&self) -> PathBuf {
            self.path.join("node_modules")
        }

        fn cache_dir(&self) -> PathBuf {
            self.path.join("cache")
        }

        fn lockfile_path(&self) -> PathBuf {
            self.path.join("rpm.lock")
        }
    }

    impl Drop for TempNodeModules {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.path);
        }
    }

    fn dependency(version: &str, dependencies: &[&str]) -> Dependency {
        Dependency::new(
            version.to_string(),
            Some(dependencies.iter().map(|dep| dep.to_string()).collect()),
        )
    }

    fn write_lockfile(path: &Path, package: &str, dependencies: &[&str]) {
        let dependencies = dependencies
            .iter()
            .map(|dependency| format!("\"{dependency}\""))
            .collect::<Vec<_>>()
            .join(", ");
        fs::write(
            path,
            format!(
                "lockfile_version = 1\nname = \"fixture-app\"\nversion = \"0.1.0\"\n\n[\"{package}@1.0.0\"]\nversion = \"1.0.0\"\ndependencies = [{dependencies}]\n"
            ),
        )
        .unwrap();
    }

    fn write_package_tgz(cache_dir: &Path, package: &str, version: &str) {
        fs::create_dir_all(cache_dir).unwrap();
        let tarball_name = format!("{}@{}.tgz", package.replace("/", "-"), version);
        let tarball = fs::File::create(cache_dir.join(tarball_name)).unwrap();
        let encoder = GzEncoder::new(tarball, Compression::default());
        let mut builder = Builder::new(encoder);
        let package_json = br#"{"name":"fixture"}"#;
        let mut header = Header::new_gnu();
        header.set_path("package/package.json").unwrap();
        header.set_size(package_json.len() as u64);
        header.set_cksum();
        builder.append(&header, &package_json[..]).unwrap();
        builder.finish().unwrap();
        builder.into_inner().unwrap().finish().unwrap();
    }

    /// Write a minimal root manifest with no lifecycle scripts at the temp
    /// project root so `init_from_paths` can read it for the lifecycle
    /// `scripts` phase without forcing every recovery test to opt in.
    fn root_manifest(temp: &TempNodeModules) -> PackageManifest {
        let path = temp.path.join("package.json");
        fs::write(&path, r#"{"name":"fixture-app","version":"0.1.0"}"#).unwrap();
        PackageManifest::read_from_path(path).unwrap()
    }

    #[test]
    fn linking_points_dependency_to_actual_package() {
        let temp = TempNodeModules::new();
        let root = temp.node_modules();
        fs::create_dir_all(root.join("a")).unwrap();
        fs::create_dir_all(root.join("b")).unwrap();
        let node_modules = NodeModules::new(root.clone());
        let parent_key = "a@1.0.0".to_string();
        let parent = dependency("1.0.0", &["b@1.0.0"]);

        node_modules.linking(&[(&parent_key, &parent)]).unwrap();

        let link = fs::read_link(root.join("a").join("node_modules").join("b")).unwrap();
        assert_eq!(link, PathBuf::from("../../b"));
    }

    #[test]
    fn linking_preserves_scoped_dependency_path() {
        let temp = TempNodeModules::new();
        let root = temp.node_modules();
        fs::create_dir_all(root.join("a")).unwrap();
        fs::create_dir_all(root.join("@scope").join("b")).unwrap();
        let node_modules = NodeModules::new(root.clone());
        let parent_key = "a@1.0.0".to_string();
        let parent = dependency("1.0.0", &["@scope/b@^1.0.0"]);

        node_modules.linking(&[(&parent_key, &parent)]).unwrap();

        let link =
            fs::read_link(root.join("a").join("node_modules").join("@scope").join("b")).unwrap();
        assert_eq!(link, PathBuf::from("../../../@scope/b"));
    }

    #[test]
    fn linking_returns_error_when_dependency_target_is_missing() {
        let temp = TempNodeModules::new();
        let root = temp.node_modules();
        fs::create_dir_all(root.join("a")).unwrap();
        let node_modules = NodeModules::new(root);
        let parent_key = "a@1.0.0".to_string();
        let parent = dependency("1.0.0", &["missing@1.0.0"]);

        let error = node_modules.linking(&[(&parent_key, &parent)]).unwrap_err();

        assert_eq!(error.kind(), ErrorKind::NotFound);
    }

    #[test]
    fn linking_rejects_dependency_path_traversal() {
        let temp = TempNodeModules::new();
        let root = temp.node_modules();
        fs::create_dir_all(root.join("a")).unwrap();
        let node_modules = NodeModules::new(root);
        let parent_key = "a@1.0.0".to_string();
        let parent = dependency("1.0.0", &["../../outside@1.0.0"]);

        let error = node_modules.linking(&[(&parent_key, &parent)]).unwrap_err();

        assert_eq!(error.kind(), ErrorKind::InvalidData);
    }

    #[test]
    fn package_name_from_lock_key_handles_scoped_names() {
        assert_eq!(
            package_name_from_lock_key("@scope/pkg@1.2.3").unwrap(),
            "@scope/pkg"
        );
    }

    #[test]
    fn package_name_from_lock_key_rejects_path_traversal() {
        assert!(package_name_from_lock_key("../../outside@1.0.0").is_err());
        assert!(package_name_from_lock_key("a/../outside@1.0.0").is_err());
    }

    #[test]
    fn init_keeps_existing_node_modules_when_extract_fails() {
        let temp = TempNodeModules::new();
        let existing_file = temp.node_modules().join("keep.txt");
        fs::write(&existing_file, "existing").unwrap();
        write_lockfile(&temp.lockfile_path(), "a", &[]);
        let root = root_manifest(&temp);

        let error = NodeModules::init_from_paths(
            temp.node_modules(),
            temp.lockfile_path(),
            temp.cache_dir(),
            &root,
        )
        .unwrap_err();

        assert!(error.to_string().contains("extract failed"));
        assert_eq!(fs::read_to_string(existing_file).unwrap(), "existing");
    }

    #[test]
    fn init_keeps_existing_node_modules_when_lockfile_is_empty() {
        let temp = TempNodeModules::new();
        let existing_file = temp.node_modules().join("keep.txt");
        fs::write(&existing_file, "existing").unwrap();
        fs::write(temp.lockfile_path(), "").unwrap();
        let root = root_manifest(&temp);

        NodeModules::init_from_paths(
            temp.node_modules(),
            temp.lockfile_path(),
            temp.cache_dir(),
            &root,
        )
        .unwrap();

        assert_eq!(fs::read_to_string(existing_file).unwrap(), "existing");
    }

    #[test]
    fn init_keeps_existing_node_modules_when_link_fails() {
        let temp = TempNodeModules::new();
        let existing_file = temp.node_modules().join("keep.txt");
        fs::write(&existing_file, "existing").unwrap();
        write_lockfile(&temp.lockfile_path(), "a", &["missing@1.0.0"]);
        write_package_tgz(&temp.cache_dir(), "a", "1.0.0");
        let root = root_manifest(&temp);

        let error = NodeModules::init_from_paths(
            temp.node_modules(),
            temp.lockfile_path(),
            temp.cache_dir(),
            &root,
        )
        .unwrap_err();

        assert!(error.to_string().contains("link failed"));
        assert_eq!(fs::read_to_string(existing_file).unwrap(), "existing");
    }

    #[test]
    fn init_keeps_dependency_links_valid_after_replacement() {
        let temp = TempNodeModules::new();
        fs::write(
            temp.lockfile_path(),
            "lockfile_version = 1\nname = \"fixture-app\"\nversion = \"0.1.0\"\n\n[\"a@1.0.0\"]\nversion = \"1.0.0\"\ndependencies = [\"b@1.0.0\"]\n\n[\"b@1.0.0\"]\nversion = \"1.0.0\"\ndependencies = []\n",
        )
        .unwrap();
        write_package_tgz(&temp.cache_dir(), "a", "1.0.0");
        write_package_tgz(&temp.cache_dir(), "b", "1.0.0");
        let root = root_manifest(&temp);

        NodeModules::init_from_paths(
            temp.node_modules(),
            temp.lockfile_path(),
            temp.cache_dir(),
            &root,
        )
        .unwrap();

        let link =
            fs::read_link(temp.node_modules().join("a").join("node_modules").join("b")).unwrap();
        assert_eq!(link, PathBuf::from("../../b"));
    }

    // --- .bin link generation tests ---
    //
    // The cases below mirror `docs/specs/core/linker/SPEC.md` Test Fixtures for
    // `.bin` generation: unscoped/scoped string and object forms, absent `bin`,
    // missing target, traversal-escaping target, and object-form keys that are
    // not a single path component.

    /// Write a `package.json` with a `bin` field under
    /// `node_modules/<package-dir>/` and create the declared target files.
    /// Returns the package directory path so tests can assert link layout.
    fn install_bin_package(
        root: &Path,
        package_dir: &str,
        package_json_body: &str,
        target_files: &[&str],
    ) {
        let dir = root.join(package_dir);
        fs::create_dir_all(&dir).unwrap();
        for target in target_files {
            if let Some(parent) = dir.join(target).parent() {
                fs::create_dir_all(parent).unwrap();
            }
            fs::write(dir.join(target), "#!/usr/bin/env node\n").unwrap();
        }
        fs::write(dir.join("package.json"), package_json_body).unwrap();
    }

    #[test]
    fn link_bins_creates_single_link_for_unscoped_string_form() {
        let temp = TempNodeModules::new();
        let root = temp.node_modules();
        install_bin_package(
            &root,
            "my-cli",
            r#"{"name":"my-cli","version":"1.0.0","bin":"./cli.js"}"#,
            &["cli.js"],
        );
        let node_modules = NodeModules::new(root.clone());
        let key = "my-cli@1.0.0".to_string();
        let dep = dependency("1.0.0", &[]);

        node_modules.link_bins(&[(&key, &dep)]).unwrap();

        let link = fs::read_link(root.join(".bin").join("my-cli")).unwrap();
        assert_eq!(link, PathBuf::from("../my-cli/cli.js"));
    }

    #[test]
    fn link_bins_creates_one_link_per_key_for_unscoped_object_form() {
        let temp = TempNodeModules::new();
        let root = temp.node_modules();
        install_bin_package(
            &root,
            "multi-bin",
            r#"{"name":"multi-bin","version":"1.0.0","bin":{"my-cli":"./cli.js","helper":"./bin/helper.js"}}"#,
            &["cli.js", "bin/helper.js"],
        );
        let node_modules = NodeModules::new(root.clone());
        let key = "multi-bin@1.0.0".to_string();
        let dep = dependency("1.0.0", &[]);

        node_modules.link_bins(&[(&key, &dep)]).unwrap();

        let cli = fs::read_link(root.join(".bin").join("my-cli")).unwrap();
        assert_eq!(cli, PathBuf::from("../multi-bin/cli.js"));
        let helper = fs::read_link(root.join(".bin").join("helper")).unwrap();
        assert_eq!(helper, PathBuf::from("../multi-bin/bin/helper.js"));
    }

    #[test]
    fn link_bins_drops_scope_for_scoped_string_form() {
        let temp = TempNodeModules::new();
        let root = temp.node_modules();
        install_bin_package(
            &root,
            "@scope/tool",
            r#"{"name":"@scope/tool","version":"1.0.0","bin":"./cli.js"}"#,
            &["cli.js"],
        );
        let node_modules = NodeModules::new(root.clone());
        let key = "@scope/tool@1.0.0".to_string();
        let dep = dependency("1.0.0", &[]);

        node_modules.link_bins(&[(&key, &dep)]).unwrap();

        // Scoped string form: binary named after the unscoped name `tool`.
        let link = fs::read_link(root.join(".bin").join("tool")).unwrap();
        assert_eq!(link, PathBuf::from("../@scope/tool/cli.js"));
        assert!(!root.join(".bin").join("@scope").exists());
    }

    #[test]
    fn link_bins_uses_object_keys_verbatim_for_scoped_object_form() {
        let temp = TempNodeModules::new();
        let root = temp.node_modules();
        install_bin_package(
            &root,
            "@scope/tool",
            r#"{"name":"@scope/tool","version":"1.0.0","bin":{"run-tool":"./cli.js"}}"#,
            &["cli.js"],
        );
        let node_modules = NodeModules::new(root.clone());
        let key = "@scope/tool@1.0.0".to_string();
        let dep = dependency("1.0.0", &[]);

        node_modules.link_bins(&[(&key, &dep)]).unwrap();

        let link = fs::read_link(root.join(".bin").join("run-tool")).unwrap();
        assert_eq!(link, PathBuf::from("../@scope/tool/cli.js"));
    }

    #[test]
    fn link_bins_skips_packages_without_bin_field() {
        let temp = TempNodeModules::new();
        let root = temp.node_modules();
        install_bin_package(
            &root,
            "no-bin",
            r#"{"name":"no-bin","version":"1.0.0"}"#,
            &[],
        );
        let node_modules = NodeModules::new(root.clone());
        let key = "no-bin@1.0.0".to_string();
        let dep = dependency("1.0.0", &[]);

        node_modules.link_bins(&[(&key, &dep)]).unwrap();

        assert!(!root.join(".bin").exists());
    }

    #[test]
    fn link_bins_fails_when_target_file_is_absent() {
        let temp = TempNodeModules::new();
        let root = temp.node_modules();
        // package.json declares a bin target but the file is never created.
        install_bin_package(
            &root,
            "missing-target",
            r#"{"name":"missing-target","version":"1.0.0","bin":"./cli.js"}"#,
            &[],
        );
        let node_modules = NodeModules::new(root.clone());
        let key = "missing-target@1.0.0".to_string();
        let dep = dependency("1.0.0", &[]);

        let error = node_modules.link_bins(&[(&key, &dep)]).unwrap_err();

        assert_eq!(error.kind(), ErrorKind::NotFound);
        assert!(error.to_string().contains("does not exist"));
        // No dangling link is written.
        assert!(!root.join(".bin").join("missing-target").exists());
    }

    #[test]
    fn link_bins_fails_when_target_traverses_outside_package() {
        let temp = TempNodeModules::new();
        let root = temp.node_modules();
        // The declared target climbs out of the package directory.
        install_bin_package(
            &root,
            "escaping-target",
            r#"{"name":"escaping-target","version":"1.0.0","bin":"../outside.js"}"#,
            &[],
        );
        let node_modules = NodeModules::new(root.clone());
        let key = "escaping-target@1.0.0".to_string();
        let dep = dependency("1.0.0", &[]);

        let error = node_modules.link_bins(&[(&key, &dep)]).unwrap_err();

        assert_eq!(error.kind(), ErrorKind::InvalidInput);
        assert!(error.to_string().contains("escapes package directory"));
    }

    #[test]
    fn link_bins_rejects_object_form_key_that_is_not_single_component() {
        let temp = TempNodeModules::new();
        let root = temp.node_modules();
        install_bin_package(
            &root,
            "bad-key",
            r#"{"name":"bad-key","version":"1.0.0","bin":{"../../etc/foo":"./cli.js"}}"#,
            &["cli.js"],
        );
        let node_modules = NodeModules::new(root.clone());
        let key = "bad-key@1.0.0".to_string();
        let dep = dependency("1.0.0", &[]);

        let error = node_modules.link_bins(&[(&key, &dep)]).unwrap_err();

        assert_eq!(error.kind(), ErrorKind::InvalidInput);
        assert!(error.to_string().contains("single path component"));
        assert!(!root.join(".bin").join("..").exists());
    }
}
