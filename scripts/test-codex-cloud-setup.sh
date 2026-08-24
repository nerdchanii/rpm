#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
trusted_temp_root=/tmp
temp_dir="$(/usr/bin/mktemp -d "${trusted_temp_root}/rpm-codex-cloud-setup.XXXXXX")"
trap 'rm -rf -- "${temp_dir}"' EXIT

fixture_ca_input=
for candidate in /etc/ssl/cert.pem /etc/ssl/certs/ca-certificates.crt \
  /etc/pki/tls/certs/ca-bundle.crt; do
  if [ -f "${candidate}" ] && [ ! -L "${candidate}" ]; then
    fixture_ca_input="${candidate}"
    break
  fi
done
[ -n "${fixture_ca_input}" ] || {
  printf 'no platform CA fixture file is available\n' >&2
  exit 1
}
fixture_canonicalizer=
for candidate in /usr/bin/realpath /bin/realpath /usr/local/bin/realpath \
  /opt/homebrew/bin/realpath; do
  if [ -f "${candidate}" ] && [ -x "${candidate}" ]; then
    fixture_canonicalizer="${candidate}"
    break
  fi
done
[ -n "${fixture_canonicalizer}" ] || {
  printf 'no trusted realpath canonicalizer is available\n' >&2
  exit 1
}
fixture_ca_file="$("${fixture_canonicalizer}" -- "${fixture_ca_input}")"
fixture_ca_dir=
for candidate in /etc/ssl/certs /etc/pki/tls/certs \
  /usr/local/share/ca-certificates; do
  if [ -d "${candidate}" ] && [ ! -L "${candidate}" ]; then
    fixture_ca_dir="$("${fixture_canonicalizer}" -- "${candidate}")"
    break
  fi
done
[ -n "${fixture_ca_dir}" ] || fixture_ca_dir="${fixture_ca_file%/*}"

run_tmpdir_regression() {
  local regression_root
  local marker_name
  local marker_path
  local malicious_tmpdir
  local output_file
  local status

  regression_root="$(/usr/bin/mktemp -d "${trusted_temp_root}/rpm-codex-cloud-setup-regression.XXXXXX")"
  marker_name="rpm-codex-cloud-setup-marker-${RANDOM}-${RANDOM}"
  marker_path="${regression_root}/${marker_name}"
  malicious_tmpdir="${regression_root}/tmp'; echo \$(printf x >${marker_path}); #"
  mkdir -p -- "${malicious_tmpdir%/*}"
  printf 'TMPDIR must be ignored by the fixture harness\n' >"${malicious_tmpdir}"
  output_file="${regression_root}/output"
  set +e
  TMPDIR="${malicious_tmpdir}" RPM_CLOUD_TEST_TMPDIR_REGRESSION=1 \
    "${script_dir}/$(basename -- "${BASH_SOURCE[0]}")" >"${output_file}" 2>&1
  status="$?"
  set -e
  if [ "${status}" -ne 0 ]; then
    cat "${output_file}" >&2
    rm -rf -- "${regression_root}"
    exit 1
  fi
  if [ -e "${marker_path}" ]; then
    printf 'malicious TMPDIR executed a fake shim payload: %s\n' "${marker_path}" >&2
    rm -f -- "${marker_path}"
    rm -rf -- "${regression_root}"
    exit 1
  fi
  rm -rf -- "${regression_root}"
}

assert_contains() {
  local actual="$1"
  local expected="$2"
  [[ "${actual}" == *"${expected}"* ]] || {
    printf 'expected output to contain: %s\nactual output:\n%s\n' \
      "${expected}" "${actual}" >&2
    exit 1
  }
}

assert_not_contains() {
  local actual="$1"
  local unexpected="$2"
  [[ "${actual}" != *"${unexpected}"* ]] || {
    printf 'expected output not to contain: %s\nactual output:\n%s\n' \
      "${unexpected}" "${actual}" >&2
    exit 1
  }
}

make_fake_environment() {
  local case_dir="$1"
  local mode="$2"
  local omit_command="${3:-}"
  local trusted_bin="${case_dir}/trusted/bin"
  local repo_dir="${case_dir}/repo"
  local home_dir="${case_dir}/home"
  local canonical_rustup_home
  local toolchain_name=stable-x86_64-unknown-linux-gnu
  local stable_toolchain_bin
  local stable_canonical_toolchain_bin
  local other_toolchain_bin="${home_dir}/.rustup/toolchains/other-fixture/bin"
  local other_canonical_toolchain_bin="${home_dir}/.rustup/toolchains/other-fixture/bin"
  local ambient_tmp="${case_dir}/ambient-tmp"
  local log_file="${case_dir}/commands"
  local recipe_log="${case_dir}/recipes"
  local command_name

  if [ "${mode}" = versioned-toolchain ]; then
    toolchain_name=1.89.0-x86_64-unknown-linux-gnu
  fi
  stable_toolchain_bin="${home_dir}/.rustup/toolchains/${toolchain_name}/bin"

  mkdir -p "${trusted_bin}" "${repo_dir}" "${home_dir}/.cargo/bin" \
    "${stable_toolchain_bin}"
  canonical_rustup_home="$(cd -- "${home_dir}/.rustup" && pwd -P)"
  stable_canonical_toolchain_bin="$(cd -- "${stable_toolchain_bin}" && pwd -P)"
  if [ "${mode}" = different-toolchain ] || [ "${mode}" = unselected-toolchain ]; then
    mkdir -p "${other_toolchain_bin}"
    other_canonical_toolchain_bin="$(cd -- "${other_toolchain_bin}" && pwd -P)"
  fi
  mkdir -p "${case_dir}/shadow/bin"
  : >"${log_file}"
  : >"${recipe_log}"

  cat >"${trusted_bin}/git" <<EOF
#!/bin/bash
set -euo pipefail
original_home='${home_dir}'
canonical_rustup_home='${canonical_rustup_home}'
for variable in HTTP_PROXY HTTPS_PROXY http_proxy https_proxy ALL_PROXY all_proxy NO_PROXY no_proxy CARGO_HOME RUSTUP_HOME \
  CARGO_REGISTRIES_CRATES_IO_INDEX CARGO_HTTP_PROXY CARGO_NET_OFFLINE \
  CARGO_SOURCE_CRATES_IO_REPLACE_WITH CARGO_SOURCE_FOO_REPLACE_WITH \
  CARGO_REGISTRY_TOKEN RUSTUP_DIST_SERVER RUSTUP_UPDATE_ROOT RUSTC_WRAPPER \
  RUSTFLAGS RPM_CLOUD_TEST_SECRET NVM_BIN RPM_CODEX_CLOUD_TRUSTED_PATH \
  RUSTDOCFLAGS RUSTC_WORKSPACE_WRAPPER SSL_CERT_FILE SSL_CERT_DIR \
  CURL_CA_BUNDLE CARGO_HTTP_CAINFO
do
  case "\${variable}" in
    CARGO_HOME|RUSTUP_HOME|RUSTUP_TOOLCHAIN) ;;
    *) [ -z "\${!variable+x}" ] || { printf 'git-env-leak=%s\\n' "\${variable}" >&2; exit 90; } ;;
  esac
done
[ "\${CARGO_HOME}" = "\${original_home}/.cargo" ] || exit 91
[ "\${RUSTUP_HOME}" = "\${canonical_rustup_home}" ] || exit 92
[ "\${RUSTUP_TOOLCHAIN}" = '${toolchain_name}' ] || exit 93
[ "\${HOME}" != "\${original_home}" ] || exit 94
case "\${HOME}" in '${ambient_tmp}'*) exit 95 ;; esac
[ "\${GIT_CONFIG_GLOBAL}" = /dev/null ] || exit 96
[ "\${GIT_CONFIG_SYSTEM}" = /dev/null ] || exit 97
[ "\${GIT_CONFIG_NOSYSTEM}" = 1 ] || exit 98
[ "\${GIT_TERMINAL_PROMPT}" = 0 ] || exit 99
printf '%s\n' "\${PATH}" >'${case_dir}/observed-trusted-path'
if [ "\${1:-}" = -C ] && [ "\${3:-}" = rev-parse ] && [ "\${4:-}" = --show-toplevel ]; then
  printf '%s\\n' '${repo_dir}'
  exit 0
fi
exit 64
EOF

  cat >"${trusted_bin}/rustup" <<EOF
#!/bin/bash
set -euo pipefail
log_file='${log_file}'
mode='${mode}'
original_home='${home_dir}'
canonical_rustup_home='${canonical_rustup_home}'
for variable in CARGO_REGISTRIES_CRATES_IO_INDEX CARGO_HTTP_PROXY CARGO_NET_OFFLINE \
  CARGO_SOURCE_CRATES_IO_REPLACE_WITH CARGO_SOURCE_FOO_REPLACE_WITH CARGO_REGISTRY_TOKEN RUSTUP_DIST_SERVER \
  RUSTUP_UPDATE_ROOT RUSTC_WRAPPER CARGO_BUILD_RUSTC_WRAPPER RUSTFLAGS \
  RPM_CLOUD_TEST_SECRET NVM_BIN RPM_CODEX_CLOUD_TRUSTED_PATH RUSTDOCFLAGS RUSTC_WORKSPACE_WRAPPER
do
  [ -z "\${!variable+x}" ] || { printf 'env-leak=%s\\n' "\${variable}" >>"\${log_file}"; exit 90; }
done
assert_no_transport() {
  local variable
  for variable in HTTP_PROXY HTTPS_PROXY ALL_PROXY NO_PROXY \
    http_proxy https_proxy all_proxy no_proxy SSL_CERT_FILE SSL_CERT_DIR \
    CURL_CA_BUNDLE CARGO_HTTP_CAINFO
  do
    [ -z "\${!variable+x}" ] || { printf 'transport-leak=%s\\n' "\${variable}" >>"\${log_file}"; exit 100; }
  done
}
assert_online_transport() {
  [ "\${HTTP_PROXY:-}" = http://ambient.invalid ] || exit 101
  [ "\${HTTPS_PROXY:-}" = https://ambient.invalid ] || exit 102
  [ "\${ALL_PROXY:-}" = http://ambient.invalid ] || exit 103
  [ "\${NO_PROXY:-}" = ambient.invalid ] || exit 104
  [ "\${http_proxy:-}" = http://ambient.invalid ] || exit 105
  [ "\${https_proxy:-}" = https://ambient.invalid ] || exit 106
  [ "\${all_proxy:-}" = http://ambient.invalid ] || exit 107
  [ "\${no_proxy:-}" = ambient.invalid ] || exit 108
  [ "\${SSL_CERT_FILE:-}" = '${fixture_ca_file}' ] || exit 109
  [ "\${SSL_CERT_DIR:-}" = '${fixture_ca_dir}' ] || exit 110
  [ "\${CURL_CA_BUNDLE:-}" = '${fixture_ca_file}' ] || exit 111
  [ "\${CARGO_HTTP_CAINFO:-}" = '${fixture_ca_file}' ] || exit 112
}
if [ "\${1:-}" = component ] && [ "\${2:-}" = add ]; then
  assert_online_transport
else
  assert_no_transport
fi
[ "\${CARGO_HOME}" = "\${original_home}/.cargo" ] || exit 91
[ "\${RUSTUP_HOME}" = "\${canonical_rustup_home}" ] || exit 92
if [ "\${1:-}" = toolchain ] && [ "\${2:-}" = list ]; then
  [ -z "\${RUSTUP_TOOLCHAIN+x}" ] || exit 93
else
  [ "\${RUSTUP_TOOLCHAIN}" = '${toolchain_name}' ] || exit 93
fi
[ "\${HOME}" != "\${original_home}" ] || exit 94
case "\${HOME}" in '${ambient_tmp}'*) exit 95 ;; esac
[ "\${GIT_CONFIG_GLOBAL}" = /dev/null ] || exit 96
[ "\${GIT_CONFIG_SYSTEM}" = /dev/null ] || exit 97
[ "\${GIT_CONFIG_NOSYSTEM}" = 1 ] || exit 98
[ "\${GIT_TERMINAL_PROMPT}" = 0 ] || exit 99
printf 'rustup %s\\n' "\$*" >>"\${log_file}"
if [ "\${1:-}" = toolchain ] && [ "\${2:-}" = list ] && \
  [ "\${3:-}" = --verbose ]; then
  case "\${mode}" in
    tracking-stable)
      printf 'stable (default) %s\\n' '${canonical_rustup_home}/toolchains/${toolchain_name}'
      ;;
    multiple-stable)
      printf 'stable-x86_64-unknown-linux-gnu (active, default) %s\\n' '${canonical_rustup_home}/toolchains/${toolchain_name}'
      printf 'stable-aarch64-unknown-linux-gnu (default) %s\\n' '${canonical_rustup_home}/toolchains/${toolchain_name}'
      ;;
    custom-stable)
      printf 'stable-custom (active, default) %s\\n' '${canonical_rustup_home}/toolchains/stable-custom'
      ;;
    host-mismatch)
      printf 'stable-aarch64-unknown-linux-gnu (active, default) %s\\n' '${canonical_rustup_home}/toolchains/${toolchain_name}'
      ;;
    *)
      printf '%s (active, default) %s\\n' '${toolchain_name}' '${canonical_rustup_home}/toolchains/${toolchain_name}'
      ;;
  esac
  exit 0
fi
if [ "\${1:-}" = which ] && [ "\${2:-}" = --toolchain ] && \\
  [ "\${3:-}" = '${toolchain_name}' ] && [ "\${4:-}" = cargo ]; then
  case "\${mode}" in
    dotdot) printf '%s\\n' '${stable_canonical_toolchain_bin}/../bin/cargo' ;;
    unselected-toolchain) printf '%s\\n' '${other_canonical_toolchain_bin}/cargo' ;;
    *) printf '%s\\n' '${stable_canonical_toolchain_bin}/cargo' ;;
  esac
  exit 0
fi
if [ "\${1:-}" = which ] && [ "\${2:-}" = --toolchain ] && \\
  [ "\${3:-}" = '${toolchain_name}' ] && [ "\${4:-}" = rustc ]; then
  case "\${mode}" in
    rustc-missing) exit 0 ;;
    rustc-failure) printf 'fake rustc lookup failed\\n' >&2; exit 77 ;;
    different-toolchain) printf '%s\\n' '${canonical_rustup_home}/toolchains/other-fixture/bin/rustc' ;;
    unselected-toolchain) printf '%s\\n' '${other_canonical_toolchain_bin}/rustc' ;;
    *) printf '%s\\n' '${stable_canonical_toolchain_bin}/rustc' ;;
  esac
  exit 0
fi
if [ "\${1:-}" = component ] && [ "\${2:-}" = list ]; then
  if [ "\${mode}" = warm ] || [ "\${mode}" = rustup-proxies ] || \
    [ "\${mode}" = versioned-toolchain ] || [ "\${mode}" = missing-just ] || \
    [ "\${mode}" = fetch-failure ]; then
    printf 'rustfmt-x86_64-unknown-linux-gnu\\nclippy-x86_64-unknown-linux-gnu\\n'
  fi
  exit 0
fi
if [ "\${1:-}" = component ] && [ "\${2:-}" = add ] && [ "\${mode}" = fresh ]; then
  bin_dir="\${PATH%%:*}"
  case "\${*: -1}" in
    rustfmt) printf '#!/bin/bash\\nexit 0\\n' >"\${bin_dir}/rustfmt"; /bin/chmod +x "\${bin_dir}/rustfmt" ;;
    clippy) printf '#!/bin/bash\\nexit 0\\n' >"\${bin_dir}/cargo-clippy"; /bin/chmod +x "\${bin_dir}/cargo-clippy" ;;
  esac
fi
EOF

  cat >"${trusted_bin}/cargo" <<EOF
#!/bin/bash
set -euo pipefail
log_file='${log_file}'
printf 'cargo-proxy %s\\n' "\$*" >>"\${log_file}"
printf 'rustup-proxy-network-attempt\\n' >>"\${log_file}"
exit 88
EOF

cat >"${stable_toolchain_bin}/cargo" <<EOF
#!/bin/bash
set -euo pipefail
log_file='${log_file}'
mode='${mode}'
original_home='${home_dir}'
canonical_rustup_home='${canonical_rustup_home}'
for variable in CARGO_HOME RUSTUP_HOME CARGO_REGISTRIES_CRATES_IO_INDEX \
  CARGO_HTTP_PROXY CARGO_NET_OFFLINE CARGO_SOURCE_CRATES_IO_REPLACE_WITH \
  CARGO_SOURCE_FOO_REPLACE_WITH CARGO_REGISTRY_TOKEN \
  RUSTUP_DIST_SERVER RUSTUP_UPDATE_ROOT RUSTC_WRAPPER CARGO_BUILD_RUSTC_WRAPPER \
  RUSTFLAGS RPM_CLOUD_TEST_SECRET NVM_BIN RPM_CODEX_CLOUD_TRUSTED_PATH \
  RUSTDOCFLAGS RUSTC_WORKSPACE_WRAPPER
do
  case "\${variable}" in
    CARGO_HOME|RUSTUP_HOME) ;;
    *) [ -z "\${!variable+x}" ] || { printf 'env-leak=%s\\n' "\${variable}" >>"\${log_file}"; exit 90; } ;;
  esac
done
assert_no_transport() {
  local variable
  for variable in HTTP_PROXY HTTPS_PROXY ALL_PROXY NO_PROXY \
    http_proxy https_proxy all_proxy no_proxy SSL_CERT_FILE SSL_CERT_DIR \
    CURL_CA_BUNDLE CARGO_HTTP_CAINFO
  do
    [ -z "\${!variable+x}" ] || { printf 'transport-leak=%s\\n' "\${variable}" >>"\${log_file}"; exit 100; }
  done
}
assert_online_transport() {
  [ "\${HTTP_PROXY:-}" = http://ambient.invalid ] || exit 101
  [ "\${HTTPS_PROXY:-}" = https://ambient.invalid ] || exit 102
  [ "\${ALL_PROXY:-}" = http://ambient.invalid ] || exit 103
  [ "\${NO_PROXY:-}" = ambient.invalid ] || exit 104
  [ "\${http_proxy:-}" = http://ambient.invalid ] || exit 105
  [ "\${https_proxy:-}" = https://ambient.invalid ] || exit 106
  [ "\${all_proxy:-}" = http://ambient.invalid ] || exit 107
  [ "\${no_proxy:-}" = ambient.invalid ] || exit 108
  [ "\${SSL_CERT_FILE:-}" = '${fixture_ca_file}' ] || exit 109
  [ "\${SSL_CERT_DIR:-}" = '${fixture_ca_dir}' ] || exit 110
  [ "\${CURL_CA_BUNDLE:-}" = '${fixture_ca_file}' ] || exit 111
  [ "\${CARGO_HTTP_CAINFO:-}" = '${fixture_ca_file}' ] || exit 112
}
case "\${1:-}" in
  install|fetch) assert_online_transport ;;
  check) assert_no_transport ;;
  *) assert_no_transport ;;
esac
[ "\${CARGO_HOME}" = "\${original_home}/.cargo" ] || exit 91
[ "\${RUSTUP_HOME}" = "\${canonical_rustup_home}" ] || exit 92
[ -z "\${RUSTUP_TOOLCHAIN+x}" ] || { printf 'rustup-toolchain-leak\\n' >>"\${log_file}"; exit 93; }
[ "\${RUSTC}" = '${stable_canonical_toolchain_bin}/rustc' ] || exit 94
[ "\${HOME}" != "\${original_home}" ] || exit 95
case "\${HOME}" in '${ambient_tmp}'*) exit 96 ;; esac
[ "\${GIT_CONFIG_GLOBAL}" = /dev/null ] || exit 97
[ "\${GIT_CONFIG_SYSTEM}" = /dev/null ] || exit 98
[ "\${GIT_TERMINAL_PROMPT}" = 0 ] || exit 99
printf 'cargo %s\\n' "\$*" >>"\${log_file}"
printf 'env=scrubbed\\n' >>"\${log_file}"
case "\${1:-}" in
  install)
    if [ "\${mode}" = fresh ]; then
      printf '%s\\n' '#!/bin/bash' 'set -euo pipefail' \
        "printf 'just %s\\n' \"\\\$*\" >>'${recipe_log}'" \
        'case "\${1:-}" in' '  check|test|validate) exit 0 ;;' \
        '  *) exit 64 ;;' 'esac' >"\${CARGO_HOME}/bin/just"
      /bin/chmod +x "\${CARGO_HOME}/bin/just"
    fi
    ;;
  fetch)
    if [ "\${mode}" = fetch-failure ]; then exit 42; fi
    ;;
  check) ;;
esac
EOF

  printf '#!/bin/bash\\nexit 0\\n' >"${stable_toolchain_bin}/rustc"
  chmod +x "${stable_toolchain_bin}/cargo" "${stable_toolchain_bin}/rustc"

  if [ "${mode}" = different-toolchain ] || [ "${mode}" = unselected-toolchain ]; then
    mkdir -p "${other_toolchain_bin}"
    printf '#!/bin/bash\\nexit 0\\n' >"${other_toolchain_bin}/rustc"
    chmod +x "${other_toolchain_bin}/rustc"
  fi
  if [ "${mode}" = unselected-toolchain ]; then
    cp "${stable_toolchain_bin}/cargo" "${other_toolchain_bin}/cargo"
    chmod +x "${other_toolchain_bin}/cargo"
  fi
  if [ "${mode}" = external-symlink ]; then
    mkdir -p "${case_dir}/external"
    printf '#!/bin/bash\\nexit 0\\n' >"${case_dir}/external/cargo"
    chmod +x "${case_dir}/external/cargo"
    rm -f "${stable_toolchain_bin}/cargo"
    ln -s "${case_dir}/external/cargo" "${stable_toolchain_bin}/cargo"
  fi
  if [ "${mode}" = parent-symlink ]; then
    parent_toolchain_dir="${case_dir}/external/${toolchain_name}"
    mkdir -p "${parent_toolchain_dir}/bin"
    mv "${stable_toolchain_bin}/cargo" "${parent_toolchain_dir}/bin/cargo"
    mv "${stable_toolchain_bin}/rustc" "${parent_toolchain_dir}/bin/rustc"
    rmdir "${stable_toolchain_bin}" "${home_dir}/.rustup/toolchains/${toolchain_name}"
    ln -s "${parent_toolchain_dir}" "${home_dir}/.rustup/toolchains/${toolchain_name}"
  fi

  for command_name in jq node python3; do
    [ "${command_name}" = "${omit_command}" ] && continue
    printf '#!/bin/bash\nexit 0\n' >"${trusted_bin}/${command_name}"
  done

  if [ "${mode}" = warm ] || [ "${mode}" = rustup-proxies ] || \
    [ "${mode}" = versioned-toolchain ] || [ "${mode}" = missing-just ] || \
    [ "${mode}" = fetch-failure ]; then
    for command_name in rustfmt cargo-clippy; do
      printf '#!/bin/bash\nexit 0\n' >"${trusted_bin}/${command_name}"
    done
  fi
  if [ "${mode}" = warm ] || [ "${mode}" = rustup-proxies ] || \
    [ "${mode}" = versioned-toolchain ] || [ "${mode}" = fetch-failure ]; then
    printf '#!/bin/bash\nexit 0\n' >"${trusted_bin}/just"
  fi

  if [ "${mode}" = rustup-proxies ]; then
    cp "${trusted_bin}/rustup" "${home_dir}/.cargo/bin/rustup"
    chmod +x "${home_dir}/.cargo/bin/rustup"
    ln -s rustup "${home_dir}/.cargo/bin/cargo"
    ln -s rustup "${home_dir}/.cargo/bin/rustfmt"
    ln -s rustup "${home_dir}/.cargo/bin/cargo-clippy"
  fi

  if [ "${omit_command}" = rustup ]; then
    rm -f "${trusted_bin}/rustup"
  fi
  chmod +x "${trusted_bin}"/*
}

make_shadow_environment() {
  local case_dir="$1"
  printf '#!/bin/bash\nexit 96\n' >"${case_dir}/shadow/bin/bash"
  printf '#!/bin/bash\nexit 97\n' >"${case_dir}/shadow/bin/cargo"
  chmod +x "${case_dir}/shadow/bin/bash" "${case_dir}/shadow/bin/cargo"
}

run_setup() {
  local case_dir="$1"
  local trusted_path="$2"
  local ambient_path="$3"
  local output_file="$4"
  local status_file="$5"
  local home_override="${6:-${case_dir}/home}"
  local nvm_bin_override="${7:-}"
  local transport_override="${8:-}"
  local -a env_args

  mkdir -p "${case_dir}/outside" "${case_dir}/ambient-tmp"
  printf 'printf leaked-bash-env >>%q\n' "${case_dir}/commands" >"${case_dir}/bash-env"
  set +e
  env_args=(
    "PATH=${ambient_path}"
    "HOME=${home_override}"
    HTTP_PROXY=http://ambient.invalid
    HTTPS_PROXY=https://ambient.invalid
    http_proxy=http://ambient.invalid
    https_proxy=https://ambient.invalid
    ALL_PROXY=http://ambient.invalid
    all_proxy=http://ambient.invalid
    NO_PROXY=ambient.invalid
    no_proxy=ambient.invalid
    CARGO_HOME=/tmp/ambient-cargo-home
    RUSTUP_HOME=/tmp/ambient-rustup-home
    CARGO_REGISTRIES_CRATES_IO_INDEX=https://ambient.invalid/index
    CARGO_HTTP_PROXY=http://ambient.invalid
    CARGO_NET_OFFLINE=true
    CARGO_SOURCE_CRATES_IO_REPLACE_WITH=ambient-source
    CARGO_SOURCE_FOO_REPLACE_WITH=ambient-source
    CARGO_REGISTRY_TOKEN=ambient-token
    RUSTUP_DIST_SERVER=https://ambient.invalid/dist
    RUSTUP_UPDATE_ROOT=https://ambient.invalid/update
    RUSTC_WRAPPER=/tmp/ambient-wrapper
    CARGO_BUILD_RUSTC_WRAPPER=/tmp/ambient-wrapper
    RUSTFLAGS='--cfg ambient_secret'
    RUSTUP_TOOLCHAIN=ambient-toolchain
    "SSL_CERT_FILE=${fixture_ca_input}"
    "SSL_CERT_DIR=${fixture_ca_dir}"
    "CURL_CA_BUNDLE=${fixture_ca_input}"
    "CARGO_HTTP_CAINFO=${fixture_ca_input}"
    "TMPDIR=${case_dir}/ambient-tmp"
    "BASH_ENV=${case_dir}/bash-env"
    RPM_CLOUD_TEST_SECRET=ambient-secret
  )
  if [ "${trusted_path}" != __DEFAULT__ ]; then
    env_args+=("RPM_CODEX_CLOUD_TRUSTED_PATH=${trusted_path}")
  fi
  if [ "$#" -ge 7 ] && [ "${nvm_bin_override}" != __NO_NVM__ ]; then
    env_args+=("NVM_BIN=${nvm_bin_override}")
  fi
  if [ "$#" -ge 8 ]; then
    env_args+=("${transport_override}")
  fi
  NVM_BIN=/tmp/ambient-nvm-bin \
  RPM_CODEX_CLOUD_TRUSTED_PATH=/tmp/ambient-trusted/bin \
  RUSTDOCFLAGS=--ambient-rustdocflags \
  RUSTC_WORKSPACE_WRAPPER=/tmp/ambient-rustc-wrapper \
  /usr/bin/env -i "${env_args[@]}" \
    /bin/sh -c 'cd "$1/outside" && exec "$2"' sh "${case_dir}" \
    "${script_dir}/codex-cloud-setup.sh" >"${output_file}" 2>&1
  printf '%s\n' "$?" >"${status_file}"
  set -e
}

new_case() {
  local name="$1"
  local case_dir="${temp_dir}/${name}"
  mkdir -p "${case_dir}"
  printf '%s\n' "${case_dir}"
}

if [ "${RPM_CLOUD_TEST_TMPDIR_REGRESSION:-}" = 1 ]; then
  tmpdir_probe_case="$(new_case tmpdir-probe)"
  make_fake_environment "${tmpdir_probe_case}" warm
  make_shadow_environment "${tmpdir_probe_case}"
  tmpdir_probe_output="${tmpdir_probe_case}/output"
  tmpdir_probe_status="${tmpdir_probe_case}/status"
  run_setup "${tmpdir_probe_case}" "${tmpdir_probe_case}/trusted/bin" \
    "${tmpdir_probe_case}/trusted/bin" "${tmpdir_probe_output}" \
    "${tmpdir_probe_status}"
  if [ "$(<"${tmpdir_probe_status}")" -ne 0 ]; then
    cat "${tmpdir_probe_output}" >&2
    exit 1
  fi
  exit 0
fi

run_tmpdir_regression

commands_without_environment_markers() {
  local line
  while IFS= read -r line; do
    [ "${line}" = env=scrubbed ] || printf '%s\n' "${line}"
  done <"$1"
}

fresh_case="$(new_case fresh)"
make_fake_environment "${fresh_case}" fresh
make_shadow_environment "${fresh_case}"
fresh_log="${fresh_case}/commands"
fresh_output="${fresh_case}/output"
fresh_status="${fresh_case}/status"
fresh_trusted_path="${fresh_case}/home/.cargo/bin:${fresh_case}/trusted/bin"
run_setup "${fresh_case}" "${fresh_trusted_path}" "${fresh_case}/shadow/bin" \
  "${fresh_output}" "${fresh_status}"
[ "$(<"${fresh_status}")" -eq 0 ]
assert_contains "$(<"${fresh_output}")" 'codex-cloud-setup: ready ('
expected_fresh=$'rustup toolchain list --verbose\nrustup component list --toolchain stable-x86_64-unknown-linux-gnu --installed\nrustup component add --toolchain stable-x86_64-unknown-linux-gnu rustfmt\nrustup component add --toolchain stable-x86_64-unknown-linux-gnu clippy\nrustup which --toolchain stable-x86_64-unknown-linux-gnu cargo\nrustup which --toolchain stable-x86_64-unknown-linux-gnu rustc\ncargo install just --locked\ncargo fetch --quiet --locked\ncargo check --quiet --offline --locked --all-targets'
actual_fresh="$(commands_without_environment_markers "${fresh_log}")"
[ "${actual_fresh}" = "${expected_fresh}" ] || {
  printf 'unexpected fresh setup commands:\n%s\n' "${actual_fresh}" >&2
  exit 1
}
assert_contains "$(<"${fresh_log}")" 'env=scrubbed'
assert_not_contains "$(<"${fresh_log}")" 'cargo-proxy'
assert_not_contains "$(<"${fresh_log}")" 'rustup-proxy-network-attempt'
assert_not_contains "$(<"${fresh_log}")" 'cargo test'
assert_not_contains "$(<"${fresh_log}")" 'just validate'
"${fresh_case}/home/.cargo/bin/just" check
"${fresh_case}/home/.cargo/bin/just" test
"${fresh_case}/home/.cargo/bin/just" validate
expected_recipes=$'just check\njust test\njust validate'
[ "$(<"${fresh_case}/recipes")" = "${expected_recipes}" ] || {
  printf 'unexpected fresh recipe commands:\n%s\n' "$(<"${fresh_case}/recipes")" >&2
  exit 1
}
assert_not_contains "$(<"${fresh_log}")" 'just check'
assert_not_contains "$(<"${fresh_log}")" 'just test'
assert_not_contains "$(<"${fresh_log}")" 'just validate'

warm_case="$(new_case warm)"
make_fake_environment "${warm_case}" warm
warm_log="${warm_case}/commands"
warm_output="${warm_case}/output"
warm_status="${warm_case}/status"
run_setup "${warm_case}" "${warm_case}/trusted/bin" "${warm_case}/trusted/bin" \
  "${warm_output}" "${warm_status}"
[ "$(<"${warm_status}")" -eq 0 ]
expected_warm=$'rustup toolchain list --verbose\nrustup component list --toolchain stable-x86_64-unknown-linux-gnu --installed\nrustup which --toolchain stable-x86_64-unknown-linux-gnu cargo\nrustup which --toolchain stable-x86_64-unknown-linux-gnu rustc\ncargo fetch --quiet --locked\ncargo check --quiet --offline --locked --all-targets'
actual_warm="$(commands_without_environment_markers "${warm_log}")"
[ "${actual_warm}" = "${expected_warm}" ] || {
  printf 'unexpected warm setup commands:\n%s\n' "${actual_warm}" >&2
  exit 1
}
assert_not_contains "$(<"${warm_log}")" 'cargo-proxy'
assert_not_contains "$(<"${warm_log}")" 'rustup-proxy-network-attempt'

rustup_proxies_case="$(new_case rustup-proxies)"
make_fake_environment "${rustup_proxies_case}" rustup-proxies
rustup_proxies_output="${rustup_proxies_case}/output"
rustup_proxies_status="${rustup_proxies_case}/status"
run_setup "${rustup_proxies_case}" \
  "${rustup_proxies_case}/home/.cargo/bin:${rustup_proxies_case}/trusted/bin" \
  "${rustup_proxies_case}/trusted/bin" "${rustup_proxies_output}" \
  "${rustup_proxies_status}"
[ "$(<"${rustup_proxies_status}")" -eq 0 ]
assert_contains "$(<"${rustup_proxies_output}")" 'codex-cloud-setup: ready ('
assert_not_contains "$(<"${rustup_proxies_case}/commands")" 'rustup-proxy-network-attempt'

cargo_parent_symlink_case="$(new_case cargo-parent-symlink)"
make_fake_environment "${cargo_parent_symlink_case}" rustup-proxies
mv "${cargo_parent_symlink_case}/home/.cargo" \
  "${cargo_parent_symlink_case}/home/cargo-platform-cache"
ln -s cargo-platform-cache "${cargo_parent_symlink_case}/home/.cargo"
cargo_parent_symlink_output="${cargo_parent_symlink_case}/output"
cargo_parent_symlink_status="${cargo_parent_symlink_case}/status"
run_setup "${cargo_parent_symlink_case}" \
  "${cargo_parent_symlink_case}/home/.cargo/bin:${cargo_parent_symlink_case}/trusted/bin" \
  "${cargo_parent_symlink_case}/trusted/bin" "${cargo_parent_symlink_output}" \
  "${cargo_parent_symlink_status}"
assert_contains "$(<"${cargo_parent_symlink_output}")" 'Cargo bin contains a symlink path component'
[ "$(<"${cargo_parent_symlink_status}")" -eq 1 ]

regular_cargo_parent_symlink_case="$(new_case regular-cargo-parent-symlink)"
make_fake_environment "${regular_cargo_parent_symlink_case}" warm
cp "${regular_cargo_parent_symlink_case}/trusted/bin/"* \
  "${regular_cargo_parent_symlink_case}/home/.cargo/bin/"
mv "${regular_cargo_parent_symlink_case}/home/.cargo" \
  "${regular_cargo_parent_symlink_case}/home/cargo-platform-cache"
ln -s cargo-platform-cache "${regular_cargo_parent_symlink_case}/home/.cargo"
regular_cargo_parent_symlink_output="${regular_cargo_parent_symlink_case}/output"
regular_cargo_parent_symlink_status="${regular_cargo_parent_symlink_case}/status"
run_setup "${regular_cargo_parent_symlink_case}" \
  "${regular_cargo_parent_symlink_case}/home/.cargo/bin:${regular_cargo_parent_symlink_case}/trusted/bin" \
  "${regular_cargo_parent_symlink_case}/trusted/bin" \
  "${regular_cargo_parent_symlink_output}" "${regular_cargo_parent_symlink_status}"
assert_contains "$(<"${regular_cargo_parent_symlink_output}")" \
  'Cargo bin contains a symlink path component'
[ "$(<"${regular_cargo_parent_symlink_status}")" -eq 1 ]

rustup_proxy_writable_case="$(new_case rustup-proxy-writable)"
make_fake_environment "${rustup_proxy_writable_case}" rustup-proxies
chmod 777 "${rustup_proxy_writable_case}/home/.cargo/bin/rustup"
rustup_proxy_writable_output="${rustup_proxy_writable_case}/output"
rustup_proxy_writable_status="${rustup_proxy_writable_case}/status"
run_setup "${rustup_proxy_writable_case}" \
  "${rustup_proxy_writable_case}/home/.cargo/bin:${rustup_proxy_writable_case}/trusted/bin" \
  "${rustup_proxy_writable_case}/trusted/bin" "${rustup_proxy_writable_output}" \
  "${rustup_proxy_writable_status}"
[ "$(<"${rustup_proxy_writable_status}")" -eq 1 ]
assert_contains "$(<"${rustup_proxy_writable_output}")" 'writable by a group or other user'

rustup_proxy_escape_case="$(new_case rustup-proxy-escape)"
make_fake_environment "${rustup_proxy_escape_case}" warm
ln -s "${rustup_proxy_escape_case}/trusted/bin/rustup" \
  "${rustup_proxy_escape_case}/home/.cargo/bin/cargo"
rustup_proxy_escape_output="${rustup_proxy_escape_case}/output"
rustup_proxy_escape_status="${rustup_proxy_escape_case}/status"
run_setup "${rustup_proxy_escape_case}" \
  "${rustup_proxy_escape_case}/home/.cargo/bin:${rustup_proxy_escape_case}/trusted/bin" \
  "${rustup_proxy_escape_case}/trusted/bin" "${rustup_proxy_escape_output}" \
  "${rustup_proxy_escape_status}"
[ "$(<"${rustup_proxy_escape_status}")" -eq 1 ]
assert_contains "$(<"${rustup_proxy_escape_output}")" 'rustup proxy target must be an executable regular file'

versioned_toolchain_case="$(new_case versioned-toolchain)"
make_fake_environment "${versioned_toolchain_case}" versioned-toolchain
versioned_toolchain_output="${versioned_toolchain_case}/output"
versioned_toolchain_status="${versioned_toolchain_case}/status"
run_setup "${versioned_toolchain_case}" "${versioned_toolchain_case}/trusted/bin" \
  "${versioned_toolchain_case}/trusted/bin" "${versioned_toolchain_output}" \
  "${versioned_toolchain_status}"
[ "$(<"${versioned_toolchain_status}")" -eq 0 ]
assert_contains "$(<"${versioned_toolchain_case}/commands")" \
  'rustup which --toolchain 1.89.0-x86_64-unknown-linux-gnu cargo'
assert_contains "$(<"${versioned_toolchain_case}/commands")" \
  'rustup which --toolchain 1.89.0-x86_64-unknown-linux-gnu rustc'

multiple_stable_case="$(new_case multiple-stable)"
make_fake_environment "${multiple_stable_case}" multiple-stable
multiple_stable_output="${multiple_stable_case}/output"
multiple_stable_status="${multiple_stable_case}/status"
run_setup "${multiple_stable_case}" \
  "${multiple_stable_case}/home/.cargo/bin:${multiple_stable_case}/trusted/bin" \
  "${multiple_stable_case}/trusted/bin" "${multiple_stable_output}" \
  "${multiple_stable_status}"
[ "$(<"${multiple_stable_status}")" -ne 0 ]
assert_contains "$(<"${multiple_stable_output}")" 'exactly one active/default concrete stable host toolchain'

custom_stable_case="$(new_case custom-stable)"
make_fake_environment "${custom_stable_case}" custom-stable
custom_stable_output="${custom_stable_case}/output"
custom_stable_status="${custom_stable_case}/status"
run_setup "${custom_stable_case}" \
  "${custom_stable_case}/home/.cargo/bin:${custom_stable_case}/trusted/bin" \
  "${custom_stable_case}/trusted/bin" "${custom_stable_output}" \
  "${custom_stable_status}"
[ "$(<"${custom_stable_status}")" -ne 0 ]
assert_contains "$(<"${custom_stable_output}")" 'not a supported Cloud host'

host_mismatch_case="$(new_case host-mismatch)"
make_fake_environment "${host_mismatch_case}" host-mismatch
host_mismatch_output="${host_mismatch_case}/output"
host_mismatch_status="${host_mismatch_case}/status"
run_setup "${host_mismatch_case}" \
  "${host_mismatch_case}/home/.cargo/bin:${host_mismatch_case}/trusted/bin" \
  "${host_mismatch_case}/trusted/bin" "${host_mismatch_output}" \
  "${host_mismatch_status}"
[ "$(<"${host_mismatch_status}")" -ne 0 ]
assert_contains "$(<"${host_mismatch_output}")" 'does not match its active host name'

tracking_stable_case="$(new_case tracking-stable)"
make_fake_environment "${tracking_stable_case}" tracking-stable
tracking_stable_output="${tracking_stable_case}/output"
tracking_stable_status="${tracking_stable_case}/status"
run_setup "${tracking_stable_case}" \
  "${tracking_stable_case}/home/.cargo/bin:${tracking_stable_case}/trusted/bin" \
  "${tracking_stable_case}/trusted/bin" "${tracking_stable_output}" \
  "${tracking_stable_status}"
[ "$(<"${tracking_stable_status}")" -eq 1 ]
assert_contains "$(<"${tracking_stable_output}")" 'tracking stable channel entry'

proxy_userinfo_case="$(new_case proxy-userinfo)"
make_fake_environment "${proxy_userinfo_case}" warm
proxy_userinfo_output="${proxy_userinfo_case}/output"
proxy_userinfo_status="${proxy_userinfo_case}/status"
run_setup "${proxy_userinfo_case}" \
  "${proxy_userinfo_case}/home/.cargo/bin:${proxy_userinfo_case}/trusted/bin" \
  "${proxy_userinfo_case}/trusted/bin" "${proxy_userinfo_output}" \
  "${proxy_userinfo_status}" "${proxy_userinfo_case}/home" __NO_NVM__ \
  HTTP_PROXY=http://user:password@ambient.invalid
[ "$(<"${proxy_userinfo_status}")" -eq 1 ]
assert_contains "$(<"${proxy_userinfo_output}")" 'proxy userinfo'

proxy_newline_case="$(new_case proxy-newline)"
make_fake_environment "${proxy_newline_case}" warm
proxy_newline_output="${proxy_newline_case}/output"
proxy_newline_status="${proxy_newline_case}/status"
proxy_newline_override=$'HTTP_PROXY=http://ambient.invalid\nunsafe'
run_setup "${proxy_newline_case}" \
  "${proxy_newline_case}/home/.cargo/bin:${proxy_newline_case}/trusted/bin" \
  "${proxy_newline_case}/trusted/bin" "${proxy_newline_output}" \
  "${proxy_newline_status}" "${proxy_newline_case}/home" __NO_NVM__ \
  "${proxy_newline_override}"
[ "$(<"${proxy_newline_status}")" -eq 1 ]
assert_contains "$(<"${proxy_newline_output}")" 'must not contain a newline'

unsafe_no_proxy_case="$(new_case unsafe-no-proxy)"
make_fake_environment "${unsafe_no_proxy_case}" warm
unsafe_no_proxy_output="${unsafe_no_proxy_case}/output"
unsafe_no_proxy_status="${unsafe_no_proxy_case}/status"
run_setup "${unsafe_no_proxy_case}" \
  "${unsafe_no_proxy_case}/home/.cargo/bin:${unsafe_no_proxy_case}/trusted/bin" \
  "${unsafe_no_proxy_case}/trusted/bin" "${unsafe_no_proxy_output}" \
  "${unsafe_no_proxy_status}" "${unsafe_no_proxy_case}/home" __NO_NVM__ \
  NO_PROXY='ambient.invalid;curl'
[ "$(<"${unsafe_no_proxy_status}")" -eq 1 ]
assert_contains "$(<"${unsafe_no_proxy_output}")" 'unsafe NO_PROXY value'

ca_outside_case="$(new_case ca-outside)"
make_fake_environment "${ca_outside_case}" warm
ca_outside_path="${ca_outside_case}/outside-ca.pem"
printf 'outside trusted CA root\n' >"${ca_outside_path}"
ca_outside_output="${ca_outside_case}/output"
ca_outside_status="${ca_outside_case}/status"
run_setup "${ca_outside_case}" \
  "${ca_outside_case}/home/.cargo/bin:${ca_outside_case}/trusted/bin" \
  "${ca_outside_case}/trusted/bin" "${ca_outside_output}" \
  "${ca_outside_status}" "${ca_outside_case}/home" __NO_NVM__ \
  "SSL_CERT_FILE=${ca_outside_path}"
[ "$(<"${ca_outside_status}")" -eq 1 ]
assert_contains "$(<"${ca_outside_output}")" 'outside the trusted CA roots'

ca_symlink_case="$(new_case ca-symlink)"
make_fake_environment "${ca_symlink_case}" warm
ca_symlink_path="${ca_symlink_case}/ca-link.pem"
ln -s "${fixture_ca_input}" "${ca_symlink_path}"
ca_symlink_output="${ca_symlink_case}/output"
ca_symlink_status="${ca_symlink_case}/status"
run_setup "${ca_symlink_case}" \
  "${ca_symlink_case}/home/.cargo/bin:${ca_symlink_case}/trusted/bin" \
  "${ca_symlink_case}/trusted/bin" "${ca_symlink_output}" \
  "${ca_symlink_status}" "${ca_symlink_case}/home" __NO_NVM__ \
  "SSL_CERT_FILE=${ca_symlink_path}"
[ "$(<"${ca_symlink_status}")" -eq 1 ]
assert_contains "$(<"${ca_symlink_output}")" 'regular trusted CA file'

shadow_symlink_case="$(new_case shadow-symlink)"
make_fake_environment "${shadow_symlink_case}" warm
mkdir -p "${shadow_symlink_case}/outside"
printf '#!/bin/bash\nexit 0\n' >"${shadow_symlink_case}/outside/cargo"
chmod +x "${shadow_symlink_case}/outside/cargo"
ln -s "${shadow_symlink_case}/outside/cargo" \
  "${shadow_symlink_case}/home/.cargo/bin/cargo"
shadow_symlink_output="${shadow_symlink_case}/output"
shadow_symlink_status="${shadow_symlink_case}/status"
run_setup "${shadow_symlink_case}" \
  "${shadow_symlink_case}/home/.cargo/bin:${shadow_symlink_case}/trusted/bin" \
  "${shadow_symlink_case}/trusted/bin" "${shadow_symlink_output}" \
  "${shadow_symlink_status}"
[ "$(<"${shadow_symlink_status}")" -eq 1 ]
assert_contains "$(<"${shadow_symlink_output}")" 'rustup proxy target must be an executable regular file'

shadow_writable_case="$(new_case shadow-writable)"
make_fake_environment "${shadow_writable_case}" warm
printf '#!/bin/bash\nexit 0\n' >"${shadow_writable_case}/home/.cargo/bin/cargo"
chmod 777 "${shadow_writable_case}/home/.cargo/bin/cargo"
shadow_writable_output="${shadow_writable_case}/output"
shadow_writable_status="${shadow_writable_case}/status"
run_setup "${shadow_writable_case}" \
  "${shadow_writable_case}/home/.cargo/bin:${shadow_writable_case}/trusted/bin" \
  "${shadow_writable_case}/trusted/bin" "${shadow_writable_output}" \
  "${shadow_writable_status}"
[ "$(<"${shadow_writable_status}")" -eq 1 ]
assert_contains "$(<"${shadow_writable_output}")" 'writable by a group or other user'

dotdot_case="$(new_case dotdot)"
make_fake_environment "${dotdot_case}" dotdot
dotdot_output="${dotdot_case}/output"
dotdot_status="${dotdot_case}/status"
run_setup "${dotdot_case}" "${dotdot_case}/home/.cargo/bin:${dotdot_case}/trusted/bin" \
  "${dotdot_case}/trusted/bin" \
  "${dotdot_output}" "${dotdot_status}"
[ "$(<"${dotdot_status}")" -ne 0 ]
assert_contains "$(<"${dotdot_output}")" 'traversal component'
assert_not_contains "$(<"${dotdot_case}/commands")" 'cargo-proxy'

external_symlink_case="$(new_case external-symlink)"
make_fake_environment "${external_symlink_case}" external-symlink
external_symlink_output="${external_symlink_case}/output"
external_symlink_status="${external_symlink_case}/status"
run_setup "${external_symlink_case}" \
  "${external_symlink_case}/home/.cargo/bin:${external_symlink_case}/trusted/bin" \
  "${external_symlink_case}/trusted/bin" "${external_symlink_output}" \
  "${external_symlink_status}"
[ "$(<"${external_symlink_status}")" -ne 0 ]
assert_contains "$(<"${external_symlink_output}")" 'symlink path component'
assert_not_contains "$(<"${external_symlink_case}/commands")" 'cargo-proxy'

parent_symlink_case="$(new_case parent-symlink)"
make_fake_environment "${parent_symlink_case}" parent-symlink
parent_symlink_output="${parent_symlink_case}/output"
parent_symlink_status="${parent_symlink_case}/status"
run_setup "${parent_symlink_case}" \
  "${parent_symlink_case}/home/.cargo/bin:${parent_symlink_case}/trusted/bin" \
  "${parent_symlink_case}/trusted/bin" "${parent_symlink_output}" \
  "${parent_symlink_status}"
[ "$(<"${parent_symlink_status}")" -ne 0 ]
assert_contains "$(<"${parent_symlink_output}")" 'symlink path component'
assert_not_contains "$(<"${parent_symlink_case}/commands")" 'cargo-proxy'

different_toolchain_case="$(new_case different-toolchain)"
make_fake_environment "${different_toolchain_case}" different-toolchain
different_toolchain_output="${different_toolchain_case}/output"
different_toolchain_status="${different_toolchain_case}/status"
run_setup "${different_toolchain_case}" \
  "${different_toolchain_case}/home/.cargo/bin:${different_toolchain_case}/trusted/bin" \
  "${different_toolchain_case}/trusted/bin" "${different_toolchain_output}" \
  "${different_toolchain_status}"
[ "$(<"${different_toolchain_status}")" -ne 0 ]
assert_contains "$(<"${different_toolchain_output}")" 'different toolchains'
assert_not_contains "$(<"${different_toolchain_case}/commands")" 'cargo-proxy'

unselected_toolchain_case="$(new_case unselected-toolchain)"
make_fake_environment "${unselected_toolchain_case}" unselected-toolchain
unselected_toolchain_output="${unselected_toolchain_case}/output"
unselected_toolchain_status="${unselected_toolchain_case}/status"
run_setup "${unselected_toolchain_case}" \
  "${unselected_toolchain_case}/home/.cargo/bin:${unselected_toolchain_case}/trusted/bin" \
  "${unselected_toolchain_case}/trusted/bin" "${unselected_toolchain_output}" \
  "${unselected_toolchain_status}"
[ "$(<"${unselected_toolchain_status}")" -ne 0 ]
assert_contains "$(<"${unselected_toolchain_output}")" 'unexpected toolchain'
assert_not_contains "$(<"${unselected_toolchain_case}/commands")" 'cargo-proxy'

rustc_missing_case="$(new_case rustc-missing)"
make_fake_environment "${rustc_missing_case}" rustc-missing
rustc_missing_output="${rustc_missing_case}/output"
rustc_missing_status="${rustc_missing_case}/status"
run_setup "${rustc_missing_case}" \
  "${rustc_missing_case}/home/.cargo/bin:${rustc_missing_case}/trusted/bin" \
  "${rustc_missing_case}/trusted/bin" "${rustc_missing_output}" \
  "${rustc_missing_status}"
[ "$(<"${rustc_missing_status}")" -ne 0 ]
assert_contains "$(<"${rustc_missing_output}")" 'did not return the stable rustc path'
assert_not_contains "$(<"${rustc_missing_case}/commands")" 'cargo-proxy'

rustc_failure_case="$(new_case rustc-failure)"
make_fake_environment "${rustc_failure_case}" rustc-failure
rustc_failure_output="${rustc_failure_case}/output"
rustc_failure_status="${rustc_failure_case}/status"
run_setup "${rustc_failure_case}" \
  "${rustc_failure_case}/home/.cargo/bin:${rustc_failure_case}/trusted/bin" \
  "${rustc_failure_case}/trusted/bin" "${rustc_failure_output}" \
  "${rustc_failure_status}"
[ "$(<"${rustc_failure_status}")" -ne 0 ]
assert_contains "$(<"${rustc_failure_output}")" 'fake rustc lookup failed'
assert_not_contains "$(<"${rustc_failure_case}/commands")" 'cargo-proxy'

default_nvm_case="$(new_case default-nvm)"
make_fake_environment "${default_nvm_case}" warm
default_nvm_bin="${default_nvm_case}/home/.nvm/versions/node/vfixture/bin"
mkdir -p "${default_nvm_bin}"
cp "${default_nvm_case}/trusted/bin/"* "${default_nvm_case}/home/.cargo/bin/"
cp "${default_nvm_case}/trusted/bin/node" "${default_nvm_bin}/node"
chmod +x "${default_nvm_bin}/node"
default_nvm_output="${default_nvm_case}/output"
default_nvm_status="${default_nvm_case}/status"
run_setup "${default_nvm_case}" __DEFAULT__ "${default_nvm_case}/shadow/bin" \
  "${default_nvm_output}" "${default_nvm_status}" "${default_nvm_case}/home" \
  "${default_nvm_bin}"
[ "$(<"${default_nvm_status}")" -eq 0 ]
default_canonical_nvm_bin="$(cd -- "${default_nvm_bin}" && pwd -P)"
default_expected_path="${default_canonical_nvm_bin}:${default_nvm_case}/home/.cargo/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
[ "$(<"${default_nvm_case}/observed-trusted-path")" = "${default_expected_path}" ] || {
  printf 'unexpected default trusted PATH:\n%s\n' \
    "$(<"${default_nvm_case}/observed-trusted-path")" >&2
  exit 1
}

nvm_writable_case="$(new_case nvm-writable)"
make_fake_environment "${nvm_writable_case}" warm
nvm_writable_bin="${nvm_writable_case}/home/.nvm/versions/node/vfixture/bin"
mkdir -p "${nvm_writable_bin}"
cp "${nvm_writable_case}/trusted/bin/"* "${nvm_writable_case}/home/.cargo/bin/"
cp "${nvm_writable_case}/trusted/bin/node" "${nvm_writable_bin}/node"
chmod 775 "${nvm_writable_case}/home/.nvm/versions/node/vfixture"
nvm_writable_output="${nvm_writable_case}/output"
nvm_writable_status="${nvm_writable_case}/status"
run_setup "${nvm_writable_case}" __DEFAULT__ "${nvm_writable_case}/shadow/bin" \
  "${nvm_writable_output}" "${nvm_writable_status}" \
  "${nvm_writable_case}/home" "${nvm_writable_bin}"
[ "$(<"${nvm_writable_status}")" -eq 1 ]
assert_contains "$(<"${nvm_writable_output}")" 'NVM_BIN is writable by a group or other user'

if [ "${EUID}" -eq 0 ]; then
  platform_nvm_case="$(new_case platform-nvm-owner)"
  make_fake_environment "${platform_nvm_case}" warm
  platform_nvm_bin="${platform_nvm_case}/home/.nvm/versions/node/vfixture/bin"
  mkdir -p "${platform_nvm_bin}"
  cp "${platform_nvm_case}/trusted/bin/"* "${platform_nvm_case}/home/.cargo/bin/"
  cp "${platform_nvm_case}/trusted/bin/node" "${platform_nvm_bin}/node"
  chown -R 1001 "${platform_nvm_case}/home/.nvm"
  platform_nvm_output="${platform_nvm_case}/output"
  platform_nvm_status="${platform_nvm_case}/status"
  run_setup "${platform_nvm_case}" __DEFAULT__ \
    "${platform_nvm_case}/shadow/bin" "${platform_nvm_output}" \
    "${platform_nvm_status}" "${platform_nvm_case}/home" "${platform_nvm_bin}"
  [ "$(<"${platform_nvm_status}")" -eq 0 ]

  mixed_nvm_case="$(new_case mixed-nvm-owner)"
  make_fake_environment "${mixed_nvm_case}" warm
  mixed_nvm_bin="${mixed_nvm_case}/home/.nvm/versions/node/vfixture/bin"
  mkdir -p "${mixed_nvm_bin}"
  cp "${mixed_nvm_case}/trusted/bin/"* "${mixed_nvm_case}/home/.cargo/bin/"
  cp "${mixed_nvm_case}/trusted/bin/node" "${mixed_nvm_bin}/node"
  chown -R 1001 "${mixed_nvm_case}/home/.nvm"
  chown 1002 "${mixed_nvm_bin}/node"
  mixed_nvm_output="${mixed_nvm_case}/output"
  mixed_nvm_status="${mixed_nvm_case}/status"
  run_setup "${mixed_nvm_case}" __DEFAULT__ "${mixed_nvm_case}/shadow/bin" \
    "${mixed_nvm_output}" "${mixed_nvm_status}" "${mixed_nvm_case}/home" \
    "${mixed_nvm_bin}"
  [ "$(<"${mixed_nvm_status}")" -eq 1 ]
  assert_contains "$(<"${mixed_nvm_output}")" 'does not match the pinned NVM owner'
fi

default_unset_nvm_case="$(new_case default-unset-nvm)"
make_fake_environment "${default_unset_nvm_case}" warm
cp "${default_unset_nvm_case}/trusted/bin/"* \
  "${default_unset_nvm_case}/home/.cargo/bin/"
default_unset_nvm_output="${default_unset_nvm_case}/output"
default_unset_nvm_status="${default_unset_nvm_case}/status"
run_setup "${default_unset_nvm_case}" __DEFAULT__ \
  "${default_unset_nvm_case}/shadow/bin" "${default_unset_nvm_output}" \
  "${default_unset_nvm_status}"
[ "$(<"${default_unset_nvm_status}")" -eq 0 ]
default_unset_nvm_expected_path="${default_unset_nvm_case}/home/.cargo/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
[ "$(<"${default_unset_nvm_case}/observed-trusted-path")" = \
  "${default_unset_nvm_expected_path}" ] || {
  printf 'unexpected default trusted PATH with unset NVM_BIN:\n%s\n' \
    "$(<"${default_unset_nvm_case}/observed-trusted-path")" >&2
  exit 1
}

empty_nvm_case="$(new_case empty-nvm)"
make_fake_environment "${empty_nvm_case}" warm
empty_nvm_output="${empty_nvm_case}/output"
empty_nvm_status="${empty_nvm_case}/status"
run_setup "${empty_nvm_case}" __DEFAULT__ "${empty_nvm_case}/shadow/bin" \
  "${empty_nvm_output}" "${empty_nvm_status}" "${empty_nvm_case}/home" ''
[ "$(<"${empty_nvm_status}")" -eq 1 ]
assert_contains "$(<"${empty_nvm_output}")" 'NVM_BIN must not be empty'
[ ! -s "${empty_nvm_case}/commands" ]

invalid_nvm_case="$(new_case invalid-nvm)"
make_fake_environment "${invalid_nvm_case}" warm
invalid_nvm_output="${invalid_nvm_case}/output"
invalid_nvm_status="${invalid_nvm_case}/status"
run_setup "${invalid_nvm_case}" "${invalid_nvm_case}/trusted/bin" \
  "${invalid_nvm_case}/trusted/bin" "${invalid_nvm_output}" "${invalid_nvm_status}" \
  "${invalid_nvm_case}/home" "${invalid_nvm_case}/outside/node/bin"
[ "$(<"${invalid_nvm_status}")" -eq 1 ]
assert_contains "$(<"${invalid_nvm_output}")" 'NVM_BIN must be under HOME/.nvm/versions/node/<version>/bin'

missing_tool_case="$(new_case missing-tool)"
make_fake_environment "${missing_tool_case}" warm jq
missing_tool_output="${missing_tool_case}/output"
missing_tool_status="${missing_tool_case}/status"
run_setup "${missing_tool_case}" "${missing_tool_case}/trusted/bin" \
  "${missing_tool_case}/trusted/bin" "${missing_tool_output}" "${missing_tool_status}"
[ "$(<"${missing_tool_status}")" -eq 1 ]
assert_contains "$(<"${missing_tool_output}")" 'jq is required on the trusted PATH'

rustup_absent_case="$(new_case rustup-absent)"
make_fake_environment "${rustup_absent_case}" warm rustup
rustup_absent_output="${rustup_absent_case}/output"
rustup_absent_status="${rustup_absent_case}/status"
run_setup "${rustup_absent_case}" "${rustup_absent_case}/trusted/bin" \
  "${rustup_absent_case}/trusted/bin" "${rustup_absent_output}" "${rustup_absent_status}"
[ "$(<"${rustup_absent_status}")" -eq 1 ]
assert_contains "$(<"${rustup_absent_output}")" 'rustup is required on the trusted PATH'

no_tools_case="$(new_case no-tools)"
make_fake_environment "${no_tools_case}" warm
rm -f "${no_tools_case}/trusted/bin/rustfmt" "${no_tools_case}/trusted/bin/cargo-clippy"
no_tools_output="${no_tools_case}/output"
no_tools_status="${no_tools_case}/status"
run_setup "${no_tools_case}" "${no_tools_case}/trusted/bin" \
  "${no_tools_case}/trusted/bin" "${no_tools_output}" "${no_tools_status}"
[ "$(<"${no_tools_status}")" -eq 1 ]
assert_contains "$(<"${no_tools_output}")" 'rustfmt is required on the trusted PATH'

missing_just_case="$(new_case missing-just)"
make_fake_environment "${missing_just_case}" fresh
missing_just_log="${missing_just_case}/commands"
missing_just_output="${missing_just_case}/output"
missing_just_status="${missing_just_case}/status"
run_setup "${missing_just_case}" "${missing_just_case}/trusted/bin" \
  "${missing_just_case}/trusted/bin" "${missing_just_output}" "${missing_just_status}"
[ "$(<"${missing_just_status}")" -eq 1 ]
assert_contains "$(<"${missing_just_output}")" 'just is missing and trusted PATH must include '
assert_not_contains "$(<"${missing_just_log}")" 'rustup component add'
assert_not_contains "$(<"${missing_just_log}")" 'cargo install just --locked'
assert_not_contains "$(<"${missing_just_log}")" 'cargo fetch'

fetch_failure_case="$(new_case fetch-failure)"
make_fake_environment "${fetch_failure_case}" fetch-failure
fetch_failure_log="${fetch_failure_case}/commands"
fetch_failure_output="${fetch_failure_case}/output"
fetch_failure_status="${fetch_failure_case}/status"
run_setup "${fetch_failure_case}" "${fetch_failure_case}/trusted/bin" \
  "${fetch_failure_case}/trusted/bin" "${fetch_failure_output}" "${fetch_failure_status}"
[ "$(<"${fetch_failure_status}")" -eq 42 ]
assert_contains "$(<"${fetch_failure_log}")" 'cargo fetch --quiet --locked'
assert_not_contains "$(<"${fetch_failure_log}")" 'cargo check'

config_case="$(new_case cargo-config)"
make_fake_environment "${config_case}" warm
mkdir -p "${config_case}/repo/.cargo"
printf 'secret-token=must-not-be-read\n' >"${config_case}/repo/.cargo/config.toml"
config_output="${config_case}/output"
config_status="${config_case}/status"
run_setup "${config_case}" "${config_case}/trusted/bin" "${config_case}/trusted/bin" \
  "${config_output}" "${config_status}"
[ "$(<"${config_status}")" -eq 1 ]
assert_contains "$(<"${config_output}")" 'refusing Cargo configuration or credentials'
assert_not_contains "$(<"${config_output}")" 'must-not-be-read'

credentials_case="$(new_case credentials)"
make_fake_environment "${credentials_case}" warm
mkdir -p "${credentials_case}/home/.cargo"
printf 'token=must-not-be-read\n' >"${credentials_case}/home/.cargo/credentials.toml"
credentials_output="${credentials_case}/output"
credentials_status="${credentials_case}/status"
run_setup "${credentials_case}" "${credentials_case}/trusted/bin" \
  "${credentials_case}/trusted/bin" "${credentials_output}" "${credentials_status}"
[ "$(<"${credentials_status}")" -eq 1 ]
assert_contains "$(<"${credentials_output}")" 'refusing Cargo configuration or credentials'
assert_not_contains "$(<"${credentials_output}")" 'must-not-be-read'

invalid_path_case="$(new_case invalid-path)"
make_fake_environment "${invalid_path_case}" warm
invalid_output="${invalid_path_case}/output"
invalid_status="${invalid_path_case}/status"
run_setup "${invalid_path_case}" relative/path "${invalid_path_case}/trusted/bin" \
  "${invalid_output}" "${invalid_status}"
[ "$(<"${invalid_status}")" -eq 1 ]
assert_contains "$(<"${invalid_output}")" 'trusted PATH entry must be absolute'

invalid_home_case="$(new_case invalid-home)"
make_fake_environment "${invalid_home_case}" warm
invalid_home_output="${invalid_home_case}/output"
invalid_home_status="${invalid_home_case}/status"
run_setup "${invalid_home_case}" "${invalid_home_case}/trusted/bin" \
  "${invalid_home_case}/trusted/bin" "${invalid_home_output}" "${invalid_home_status}" \
  relative-home
[ "$(<"${invalid_home_status}")" -eq 1 ]
assert_contains "$(<"${invalid_home_output}")" 'HOME must be an absolute path'

colon_home_case="$(new_case colon-home)"
make_fake_environment "${colon_home_case}" warm
colon_home_output="${colon_home_case}/output"
colon_home_status="${colon_home_case}/status"
run_setup "${colon_home_case}" "${colon_home_case}/trusted/bin" \
  "${colon_home_case}/trusted/bin" "${colon_home_output}" "${colon_home_status}" \
  "${colon_home_case}/home:alternate"
[ "$(<"${colon_home_status}")" -eq 1 ]
assert_contains "$(<"${colon_home_output}")" 'HOME must not contain colon or newline'

empty_path_case="$(new_case empty-path)"
make_fake_environment "${empty_path_case}" warm
empty_output="${empty_path_case}/output"
empty_status="${empty_path_case}/status"
run_setup "${empty_path_case}" "${empty_path_case}/trusted/bin::/usr/bin" \
  "${empty_path_case}/trusted/bin" "${empty_output}" "${empty_status}"
[ "$(<"${empty_status}")" -eq 1 ]
assert_contains "$(<"${empty_output}")" 'trusted PATH must not contain empty entries'

printf 'codex_cloud_setup_tests=ok\n'
