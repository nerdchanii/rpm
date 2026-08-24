#!/bin/bash -p
set -euo pipefail

die() {
  printf 'codex-cloud-setup: %s\n' "$*" >&2
  exit 1
}

script_dir="${BASH_SOURCE[0]%/*}"
if [ "${script_dir}" = "${BASH_SOURCE[0]}" ]; then
  script_dir=.
fi
script_dir="$(cd -- "${script_dir}" && pwd -P)"

original_home="${HOME:-}"
[ -n "${original_home}" ] || die 'HOME is required'
case "${original_home}" in
  /*) ;;
  *) die 'HOME must be an absolute path' ;;
esac
case "${original_home}" in
  *:*|*$'\n'*) die 'HOME must not contain colon or newline' ;;
esac

select_canonicalizer() {
  local candidate

  for candidate in /usr/bin/realpath /bin/realpath; do
    if [ -f "${candidate}" ] && [ -x "${candidate}" ]; then
      printf '%s\n' "${candidate}"
      return 0
    fi
  done
  die 'a trusted realpath canonicalizer is required'
}

canonicalizer="$(select_canonicalizer)"

canonicalize_path() {
  local label="$1"
  local path="$2"
  local canonical_path

  canonical_path="$("${canonicalizer}" -- "${path}")" || \
    die "cannot canonicalize ${label}: ${path}"
  [ -n "${canonical_path}" ] || die "canonicalizer returned no ${label} path"
  case "${canonical_path}" in
    *$'\n'*) die "canonicalizer returned an invalid ${label} path" ;;
  esac
  printf '%s\n' "${canonical_path}"
}

reject_unsafe_path() {
  local label="$1"
  local path="$2"
  local remainder
  local component

  case "${path}" in
    /*) ;;
    *) die "${label} must be an absolute path: ${path}" ;;
  esac

  remainder="${path#/}"
  while [ -n "${remainder}" ]; do
    case "${remainder}" in
      */*)
        component="${remainder%%/*}"
        remainder="${remainder#*/}"
        ;;
      *)
        component="${remainder}"
        remainder=
        ;;
    esac
    case "${component}" in
      .|..) die "${label} contains a traversal component: ${component}" ;;
    esac
  done
}

reject_symlink_components() {
  local label="$1"
  local root="$2"
  local path="$3"
  local remainder
  local component
  local current="${root}"

  case "${path}" in
    "${root}") remainder= ;;
    "${root}"/*) remainder="${path#"${root}"/}" ;;
    *) die "${label} is outside its trusted root: ${path}" ;;
  esac
  [ ! -L "${current}" ] || die "${label} contains a symlink path component: ${current}"

  while [ -n "${remainder}" ]; do
    case "${remainder}" in
      */*)
        component="${remainder%%/*}"
        remainder="${remainder#*/}"
        ;;
      *)
        component="${remainder}"
        remainder=
        ;;
    esac
    current="${current}/${component}"
    [ ! -L "${current}" ] || die "${label} contains a symlink path component: ${current}"
  done
}

canonical_nvm_bin=
if [ "${NVM_BIN+x}" = x ]; then
  nvm_bin="${NVM_BIN}"
  [ -n "${nvm_bin}" ] || die 'NVM_BIN must not be empty'
  case "${nvm_bin}" in
    /*) ;;
    *) die 'NVM_BIN must be an absolute path' ;;
  esac
  case "${nvm_bin}" in
    *:*|*$'\n'*) die 'NVM_BIN must not contain colon or newline' ;;
  esac
  nvm_root="${original_home}/.nvm/versions/node/"
  canonical_home="$(cd -- "${original_home}" && pwd -P)" || die 'cannot canonicalize HOME'
  canonical_nvm_root="${canonical_home}/.nvm/versions/node/"
  case "${nvm_bin}" in
    "${nvm_root}"*/bin) ;;
    *) die 'NVM_BIN must be under HOME/.nvm/versions/node/<version>/bin' ;;
  esac
  nvm_version="${nvm_bin#"${nvm_root}"}"
  nvm_version="${nvm_version%/bin}"
  case "${nvm_version}" in
    ''|*/*) die 'NVM_BIN must name one NVM version directory' ;;
  esac
  [ -d "${nvm_bin}" ] || die "NVM_BIN directory does not exist: ${nvm_bin}"
  canonical_nvm_bin="$(cd -- "${nvm_bin}" && pwd -P)" || die 'cannot canonicalize NVM_BIN'
  case "${canonical_nvm_bin}" in
    "${canonical_nvm_root}"*/bin) ;;
    *) die 'NVM_BIN resolves outside HOME/.nvm/versions/node/<version>/bin' ;;
  esac
  canonical_version="${canonical_nvm_bin#"${canonical_nvm_root}"}"
  canonical_version="${canonical_version%/bin}"
  case "${canonical_version}" in
    ''|*/*) die 'NVM_BIN resolves to an invalid NVM version directory' ;;
  esac
fi

if [ "${RPM_CODEX_CLOUD_TRUSTED_PATH+x}" = x ]; then
  trusted_path="${RPM_CODEX_CLOUD_TRUSTED_PATH}"
else
  trusted_path="${original_home}/.cargo/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
  if [ -n "${canonical_nvm_bin}" ]; then
    trusted_path="${canonical_nvm_bin}:${trusted_path}"
  fi
fi

validate_trusted_path() {
  local path_value="$1"
  local entry

  [ -n "${path_value}" ] || die 'trusted PATH must not be empty'
  case "${path_value}" in
    *::*|:*|*:)
      die 'trusted PATH must not contain empty entries'
      ;;
  esac
  while [ -n "${path_value}" ]; do
    case "${path_value}" in
      *:*)
        entry="${path_value%%:*}"
        path_value="${path_value#*:}"
        ;;
      *)
        entry="${path_value}"
        path_value=
        ;;
    esac
    case "${entry}" in
      /*) ;;
      *) die "trusted PATH entry must be absolute: ${entry}" ;;
    esac
  done
}

validate_trusted_path "${trusted_path}"
export PATH="${trusted_path}"

has_trusted_path_entry() {
  local expected="$1"
  local path_value="${trusted_path}"
  local entry

  while :; do
    case "${path_value}" in
      *:*)
        entry="${path_value%%:*}"
        path_value="${path_value#*:}"
        ;;
      *)
        entry="${path_value}"
        path_value=
        ;;
    esac
    [ "${entry}" = "${expected}" ] && return 0
    [ -n "${path_value}" ] || break
  done
  return 1
}

find_command() {
  local command_name="$1"
  local command_path

  command_path="$(command -v "${command_name}" 2>/dev/null || true)"
  [ -n "${command_path}" ] || die "${command_name} is required on the trusted PATH"
  case "${command_path}" in
    /*) printf '%s\n' "${command_path}" ;;
    *) die "${command_name} resolved outside the trusted PATH: ${command_path}" ;;
  esac
}

find_optional_command() {
  command -v "$1" 2>/dev/null || true
}

git_command="$(find_command git)"
cargo_command="$(find_command cargo)"
rustup_command="$(find_command rustup)"

cargo_home="${original_home}/.cargo"
cargo_bin="${cargo_home}/bin"
just_command="$(find_optional_command just)"
if [ -z "${just_command}" ]; then
  has_trusted_path_entry "${cargo_bin}" || die "just is missing and trusted PATH must include ${cargo_bin} before tool installation"
fi

setup_home="$(/usr/bin/mktemp -d /tmp/rpm-codex-cloud-home.XXXXXX)"
cleanup() {
  /bin/rm -rf -- "${setup_home}"
}
trap cleanup EXIT

rustup_home="${original_home}/.rustup"
reject_unsafe_path RUSTUP_HOME "${rustup_home}"
reject_symlink_components RUSTUP_HOME "${rustup_home}" "${rustup_home}"
canonical_rustup_home="$(canonicalize_path RUSTUP_HOME "${rustup_home}")"
[ -d "${canonical_rustup_home}" ] || die "RUSTUP_HOME is not a directory: ${rustup_home}"
[ ! -L "${canonical_rustup_home}" ] || die "canonical RUSTUP_HOME must not be a symlink: ${canonical_rustup_home}"

run_clean_env() {
  local toolchain="$1"
  local rustc_command="$2"
  shift 2
  local -a clean_env=(
    "HOME=${setup_home}"
    "PATH=${trusted_path}"
    "CARGO_HOME=${cargo_home}"
    "RUSTUP_HOME=${canonical_rustup_home}"
    GIT_CONFIG_GLOBAL=/dev/null
    GIT_CONFIG_SYSTEM=/dev/null
    GIT_CONFIG_NOSYSTEM=1
    GIT_TERMINAL_PROMPT=0
  )

  if [ -n "${toolchain}" ]; then
    clean_env+=("RUSTUP_TOOLCHAIN=${toolchain}")
  fi
  if [ -n "${rustc_command}" ]; then
    clean_env+=("RUSTC=${rustc_command}")
  fi
  /usr/bin/env -i "${clean_env[@]}" "$@"
}

run_clean() {
  run_clean_env stable '' "$@"
}

run_clean_exact() {
  run_clean_env '' "${stable_rustc_command}" "$@"
}

check_cargo_control_file() {
  local path="$1"
  if [ -e "${path}" ] || [ -L "${path}" ]; then
    die "refusing Cargo configuration or credentials for public setup: ${path}"
  fi
}

check_cargo_controls() {
  local directory="${repo_root}"
  local candidate

  while :; do
    check_cargo_control_file "${directory}/.cargo/config"
    check_cargo_control_file "${directory}/.cargo/config.toml"
    [ "${directory}" = / ] && break
    directory="${directory%/*}"
    [ -n "${directory}" ] || directory=/
  done

  for candidate in \
    "${cargo_home}/config" \
    "${cargo_home}/config.toml" \
    "${cargo_home}/credentials" \
    "${cargo_home}/credentials.toml"
  do
    check_cargo_control_file "${candidate}"
  done
}

repo_root_candidate="$(cd -- "${script_dir}/.." && pwd -P)"
repo_root="$(run_clean "${git_command}" -C "${repo_root_candidate}" rev-parse --show-toplevel)"
[ -n "${repo_root}" ] || die 'Git did not return a repository root'
cd -- "${repo_root}"
check_cargo_controls

has_component() {
  local component="$1"
  local installed="$2"
  local line

  while IFS= read -r line; do
    case "${line}" in
      "${component}-"*' (installed)'|"${component}-"*) return 0 ;;
    esac
  done <<<"${installed}"
  return 1
}

resolve_stable_binary() {
  local binary_name="$1"
  local binary_path
  local canonical_binary_path

  binary_path="$(run_clean "${rustup_command}" which --toolchain stable "${binary_name}")"
  [ -n "${binary_path}" ] || die "rustup did not return the stable ${binary_name} path"
  reject_unsafe_path "stable ${binary_name}" "${binary_path}"
  reject_symlink_components "stable ${binary_name}" "${canonical_rustup_home}" "${binary_path}"
  case "${binary_path}" in
    "${canonical_rustup_home}"/toolchains/*/bin/"${binary_name}") ;;
    *) die "stable ${binary_name} resolved outside RUSTUP_HOME: ${binary_path}" ;;
  esac
  canonical_binary_path="$(canonicalize_path "stable ${binary_name}" "${binary_path}")"
  printf '%s\n' "${canonical_binary_path}"
}

validate_stable_binary() {
  local binary_name="$1"
  local binary_path="$2"
  local relative_path
  local toolchain_name
  local toolchain_root
  local toolchain_bin

  case "${binary_path}" in
    "${canonical_rustup_home}"/toolchains/*/bin/"${binary_name}") ;;
    *) die "stable ${binary_name} is outside canonical RUSTUP_HOME: ${binary_path}" ;;
  esac
  relative_path="${binary_path#"${canonical_rustup_home}"/toolchains/}"
  toolchain_name="${relative_path%/bin/${binary_name}}"
  case "${toolchain_name}" in
    ''|*/*) die "stable ${binary_name} has an invalid toolchain directory: ${binary_path}" ;;
  esac
  toolchain_root="${canonical_rustup_home}/toolchains/${toolchain_name}"
  toolchain_bin="${toolchain_root}/bin"
  [ "${binary_path}" = "${toolchain_bin}/${binary_name}" ] || \
    die "stable ${binary_name} is not the exact toolchain binary: ${binary_path}"
  [ -d "${toolchain_root}" ] && [ ! -L "${toolchain_root}" ] || \
    die "stable ${binary_name} toolchain root is unsafe: ${toolchain_root}"
  [ -d "${toolchain_bin}" ] && [ ! -L "${toolchain_bin}" ] || \
    die "stable ${binary_name} toolchain bin is unsafe: ${toolchain_bin}"
  [ -f "${binary_path}" ] && [ ! -L "${binary_path}" ] && [ -x "${binary_path}" ] || \
    die "stable ${binary_name} must be an executable regular file: ${binary_path}"
  printf '%s\n' "${toolchain_root}"
}

installed_components="$(run_clean "${rustup_command}" component list --toolchain stable --installed)"
if ! has_component rustfmt "${installed_components}"; then
  run_clean "${rustup_command}" component add --toolchain stable rustfmt
fi
if ! has_component clippy "${installed_components}"; then
  run_clean "${rustup_command}" component add --toolchain stable clippy
fi

stable_cargo_command="$(resolve_stable_binary cargo)"
stable_rustc_command="$(resolve_stable_binary rustc)"
stable_cargo_toolchain_root="$(validate_stable_binary cargo "${stable_cargo_command}")"
stable_rustc_toolchain_root="$(validate_stable_binary rustc "${stable_rustc_command}")"
[ "${stable_cargo_toolchain_root}" = "${stable_rustc_toolchain_root}" ] || \
  die "stable cargo and rustc resolve to different toolchains"

if [ -z "${just_command}" ]; then
  run_clean_exact "${stable_cargo_command}" install just --locked
fi

rustfmt_command="$(find_command rustfmt)"
clippy_command="$(find_command cargo-clippy)"
just_command="$(find_command just)"
find_command jq >/dev/null
find_command node >/dev/null
find_command python3 >/dev/null

run_clean_exact "${stable_cargo_command}" fetch --quiet --locked
run_clean_exact "${stable_cargo_command}" check --quiet --offline --locked --all-targets

printf 'codex-cloud-setup: ready (%s)\n' "${repo_root}"
