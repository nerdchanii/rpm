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

trusted_path_root_for() {
  local requested_path="$1"
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
    case "${requested_path}" in
      "${entry}"|"${entry}"/*)
        printf '%s\n' "${entry}"
        return 0
        ;;
    esac
    [ -n "${path_value}" ] || break
  done
  die "executable is outside the trusted PATH roots: ${requested_path}"
}

file_metadata() {
  local path="$1"
  local metadata

  if metadata="$(/usr/bin/stat -c '%a %u' -- "${path}" 2>/dev/null)"; then
    printf '%s\n' "${metadata}"
  elif metadata="$(/usr/bin/stat -f '%Lp %u' "${path}" 2>/dev/null)"; then
    printf '%s\n' "${metadata}"
  else
    die "cannot inspect executable ownership and mode: ${path}"
  fi
}

validate_owner_and_mode() {
  local label="$1"
  local path="$2"
  local metadata
  local mode
  local owner

  metadata="$(file_metadata "${path}")"
  mode="${metadata%% *}"
  owner="${metadata#* }"
  case "${path}" in
    /bin/*|/usr/bin/*|/sbin/*|/usr/sbin/*|/usr/local/bin/*|/usr/local/sbin/*)
      [ "${owner}" = 0 ] || die "${label} is not owned by the platform owner: ${path}"
      ;;
    *)
      [ "${owner}" = "${EUID}" ] || die "${label} is not owned by the setup user: ${path}"
      ;;
  esac
  if (( 8#${mode} & 022 )); then
    die "${label} is writable by a group or other user: ${path}"
  fi
}

validate_executable_path() {
  local label="$1"
  local executable_path="$2"
  local trusted_root

  reject_unsafe_path "${label}" "${executable_path}"
  case "${executable_path}" in
    *:*|*$'\n'*) die "${label} contains an unsafe separator: ${executable_path}" ;;
  esac
  trusted_root="$(trusted_path_root_for "${executable_path}")"
  reject_symlink_components "${label}" "${trusted_root}" "${executable_path}"
  [ -d "${trusted_root}" ] || die "trusted PATH root is not a directory: ${trusted_root}"
  validate_owner_and_mode "trusted PATH root" "${trusted_root}"
  [ -f "${executable_path}" ] && [ ! -L "${executable_path}" ] && \
    [ -x "${executable_path}" ] || \
    die "${label} must be an executable regular file: ${executable_path}"

  validate_owner_and_mode "${label}" "${executable_path}"
}

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
    /*) validate_executable_path "${command_name}" "${command_path}" ;;
    *) die "${command_name} resolved outside the trusted PATH: ${command_path}" ;;
  esac
  printf '%s\n' "${command_path}"
}

find_optional_command() {
  local command_name="$1"
  local command_path

  command_path="$(command -v "${command_name}" 2>/dev/null || true)"
  if [ -n "${command_path}" ]; then
    case "${command_path}" in
      /*) validate_executable_path "${command_name}" "${command_path}" ;;
      *) die "${command_name} resolved outside the trusted PATH: ${command_path}" ;;
    esac
    printf '%s\n' "${command_path}"
  fi
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

online_transport_env=()
# Cloud owner contract: only these platform-managed transport variables may
# cross the clean environment boundary, and only for online setup commands.
trusted_ca_roots=(/etc/ssl /etc/pki/tls /usr/local/share/ca-certificates)

canonicalize_ca_transport() {
  local variable="$1"
  local value="$2"
  local canonical_value
  local root
  local canonical_root
  local is_directory=0

  case "${variable}" in
    SSL_CERT_DIR) is_directory=1 ;;
  esac
  reject_unsafe_path "${variable}" "${value}"
  if [ "${is_directory}" -eq 1 ]; then
    [ -d "${value}" ] && [ ! -L "${value}" ] || \
      die "${variable} must be a regular trusted CA directory: ${value}"
  else
    [ -f "${value}" ] && [ ! -L "${value}" ] || \
      die "${variable} must be a regular trusted CA file: ${value}"
  fi
  canonical_value="$(canonicalize_path "${variable}" "${value}")"

  for root in "${trusted_ca_roots[@]}"; do
    [ -d "${root}" ] && [ ! -L "${root}" ] || continue
    canonical_root="$(canonicalize_path "trusted CA root" "${root}")"
    case "${canonical_value}" in
      "${canonical_root}"|"${canonical_root}"/*)
        case "${value}" in
          "${root}"|"${root}"/*)
            reject_symlink_components "${variable}" "${root}" "${value}"
            ;;
          *)
            reject_symlink_components "${variable}" "${canonical_root}" "${canonical_value}"
            ;;
        esac
        printf '%s\n' "${canonical_value}"
        return 0
        ;;
    esac
  done
  die "${variable} is outside the trusted CA roots: ${value}"
}

capture_online_transport() {
  local variable
  local value

  for variable in \
    HTTP_PROXY HTTPS_PROXY ALL_PROXY NO_PROXY \
    http_proxy https_proxy all_proxy no_proxy \
    SSL_CERT_FILE SSL_CERT_DIR CURL_CA_BUNDLE CARGO_HTTP_CAINFO
  do
    if [ "${!variable+x}" != x ]; then
      continue
    fi
    value="${!variable}"
    [ -n "${value}" ] || continue
    case "${variable}" in
      HTTP_PROXY|HTTPS_PROXY|ALL_PROXY|http_proxy|https_proxy|all_proxy)
        case "${value}" in
          http://*|https://*|socks5://*|socks5h://*) ;;
          *) die "unsupported ${variable} transport URL" ;;
        esac
        case "${value}" in
          *@*) die "${variable} must not contain proxy userinfo" ;;
        esac
        ;;
      NO_PROXY|no_proxy)
        case "${value}" in
          ,*|*,|*,,*|*[!A-Za-z0-9._,:\[\]-]*)
            die "unsafe ${variable} value" ;;
        esac
        ;;
      *)
        value="$(canonicalize_ca_transport "${variable}" "${value}")"
        ;;
    esac
    case "${value}" in
      *$'\n'*) die "${variable} must not contain a newline" ;;
    esac
    online_transport_env+=("${variable}=${value}")
  done
}
capture_online_transport

run_clean_env() {
  local toolchain="$1"
  local rustc_command="$2"
  local transport_mode="$3"
  shift 3
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

  case "${transport_mode}" in
    online) clean_env+=("${online_transport_env[@]}") ;;
    offline) ;;
    *) die "unknown setup transport mode: ${transport_mode}" ;;
  esac
  if [ -n "${toolchain}" ]; then
    clean_env+=("RUSTUP_TOOLCHAIN=${toolchain}")
  fi
  if [ -n "${rustc_command}" ]; then
    clean_env+=("RUSTC=${rustc_command}")
  fi
  /usr/bin/env -i "${clean_env[@]}" "$@"
}

run_clean() {
  run_clean_env "${stable_toolchain}" '' offline "$@"
}

run_clean_online() {
  run_clean_env "${stable_toolchain}" '' online "$@"
}

run_clean_exact_online() {
  run_clean_env '' "${stable_rustc_command}" online "$@"
}

run_clean_exact_offline() {
  run_clean_env '' "${stable_rustc_command}" offline "$@"
}

resolve_installed_stable_toolchain() {
  local installed_toolchains
  local line
  local candidate
  local remainder
  local canonical_toolchain_path
  local expected_toolchain_path
  local stable_count=0
  local active_default_count=0
  local selected_toolchain=
  local selected_toolchain_path=

  installed_toolchains="$(run_clean_env '' '' offline "${rustup_command}" toolchain list --verbose)"
  while IFS= read -r line; do
    candidate="${line%% *}"
    case "${candidate}" in
      stable) die 'rustup returned a tracking stable channel entry' ;;
      stable-*)
        case "${candidate}" in
          *[!A-Za-z0-9._-]*) die "rustup returned an invalid stable toolchain name: ${candidate}" ;;
          *) ;;
        esac
        stable_count=$((stable_count + 1))
        remainder="${line#"${candidate}"}"
        case "${remainder}" in
          ' (active, default) '*|' (default, active) '*|' (active) '*|' (default) '*)
            active_default_count=$((active_default_count + 1))
            selected_toolchain="${candidate}"
            selected_toolchain_path="${remainder##* }"
            ;;
        esac
        ;;
    esac
  done <<<"${installed_toolchains}"
  [ "${stable_count}" -eq 1 ] && [ "${active_default_count}" -eq 1 ] || \
    die 'rustup must expose exactly one active/default stable host toolchain'
  [ -n "${selected_toolchain_path}" ] || \
    die 'rustup active/default stable toolchain has no installation path'
  reject_unsafe_path 'stable toolchain path' "${selected_toolchain_path}"
  reject_symlink_components 'stable toolchain path' "${canonical_rustup_home}" \
    "${selected_toolchain_path}"
  expected_toolchain_path="${canonical_rustup_home}/toolchains/${selected_toolchain}"
  canonical_toolchain_path="$(canonicalize_path 'stable toolchain path' "${selected_toolchain_path}")"
  [ "${canonical_toolchain_path}" = "${expected_toolchain_path}" ] || \
    die 'rustup stable toolchain path does not match its active host name'
  [ -d "${canonical_toolchain_path}" ] && [ ! -L "${canonical_toolchain_path}" ] || \
    die 'active/default stable toolchain root is unsafe'
  printf '%s\n' "${selected_toolchain}"
}

stable_toolchain="$(resolve_installed_stable_toolchain)"

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

  binary_path="$(run_clean "${rustup_command}" which --toolchain "${stable_toolchain}" "${binary_name}")"
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

installed_components="$(run_clean "${rustup_command}" component list --toolchain "${stable_toolchain}" --installed)"
if ! has_component rustfmt "${installed_components}"; then
  run_clean_online "${rustup_command}" component add --toolchain "${stable_toolchain}" rustfmt
fi
if ! has_component clippy "${installed_components}"; then
  run_clean_online "${rustup_command}" component add --toolchain "${stable_toolchain}" clippy
fi

stable_cargo_command="$(resolve_stable_binary cargo)"
stable_rustc_command="$(resolve_stable_binary rustc)"
stable_cargo_toolchain_root="$(validate_stable_binary cargo "${stable_cargo_command}")"
stable_rustc_toolchain_root="$(validate_stable_binary rustc "${stable_rustc_command}")"
[ "${stable_cargo_toolchain_root}" = "${stable_rustc_toolchain_root}" ] || \
  die "stable cargo and rustc resolve to different toolchains"
expected_stable_toolchain_root="${canonical_rustup_home}/toolchains/${stable_toolchain}"
[ "${stable_cargo_toolchain_root}" = "${expected_stable_toolchain_root}" ] || \
  die "stable cargo resolved to an unexpected toolchain: ${stable_cargo_toolchain_root}"
[ "${stable_rustc_toolchain_root}" = "${expected_stable_toolchain_root}" ] || \
  die "stable rustc resolved to an unexpected toolchain: ${stable_rustc_toolchain_root}"

if [ -z "${just_command}" ]; then
  run_clean_exact_online "${stable_cargo_command}" install just --locked
fi

rustfmt_command="$(find_command rustfmt)"
clippy_command="$(find_command cargo-clippy)"
just_command="$(find_command just)"
find_command jq >/dev/null
find_command node >/dev/null
find_command python3 >/dev/null

run_clean_exact_online "${stable_cargo_command}" fetch --quiet --locked
run_clean_exact_offline "${stable_cargo_command}" check --quiet --offline --locked --all-targets

printf 'codex-cloud-setup: ready (%s)\n' "${repo_root}"
