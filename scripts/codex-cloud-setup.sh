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

if [ "${RPM_CODEX_CLOUD_TRUSTED_PATH+x}" = x ]; then
  trusted_path="${RPM_CODEX_CLOUD_TRUSTED_PATH}"
else
  trusted_path="${original_home}/.cargo/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
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

setup_home="$(/usr/bin/mktemp -d /tmp/rpm-codex-cloud-home.XXXXXX)"
cleanup() {
  /bin/rm -rf -- "${setup_home}"
}
trap cleanup EXIT

cargo_home="${original_home}/.cargo"
rustup_home="${original_home}/.rustup"

run_clean() {
  /usr/bin/env -i \
    HOME="${setup_home}" \
    PATH="${trusted_path}" \
    CARGO_HOME="${cargo_home}" \
    RUSTUP_HOME="${rustup_home}" \
    RUSTUP_TOOLCHAIN=stable \
    GIT_CONFIG_GLOBAL=/dev/null \
    GIT_CONFIG_SYSTEM=/dev/null \
    GIT_CONFIG_NOSYSTEM=1 \
    GIT_TERMINAL_PROMPT=0 \
    "$@"
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

installed_components="$(run_clean "${rustup_command}" component list --toolchain stable --installed)"
if ! has_component rustfmt "${installed_components}"; then
  run_clean "${rustup_command}" component add --toolchain stable rustfmt
fi
if ! has_component clippy "${installed_components}"; then
  run_clean "${rustup_command}" component add --toolchain stable clippy
fi

just_command="$(find_optional_command just)"
if [ -z "${just_command}" ]; then
  run_clean "${cargo_command}" install just --locked
fi

rustfmt_command="$(find_command rustfmt)"
clippy_command="$(find_command cargo-clippy)"
just_command="$(find_command just)"
find_command jq >/dev/null
find_command node >/dev/null
find_command python3 >/dev/null

run_clean "${cargo_command}" fetch --quiet --locked
run_clean "${cargo_command}" check --quiet --offline --locked --all-targets

printf 'codex-cloud-setup: ready (%s)\n' "${repo_root}"
