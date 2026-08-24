#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/rpm-codex-cloud-setup.XXXXXX")"
trap 'rm -rf -- "${temp_dir}"' EXIT

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
  local stable_toolchain_bin="${home_dir}/.rustup/toolchains/stable-fixture/bin"
  local stable_canonical_toolchain_bin
  local other_toolchain_bin="${home_dir}/.rustup/toolchains/other-fixture/bin"
  local ambient_tmp="${case_dir}/ambient-tmp"
  local log_file="${case_dir}/commands"
  local recipe_log="${case_dir}/recipes"
  local command_name

  mkdir -p "${trusted_bin}" "${repo_dir}" "${home_dir}/.cargo/bin" \
    "${stable_toolchain_bin}"
  canonical_rustup_home="$(cd -- "${home_dir}/.rustup" && pwd -P)"
  stable_canonical_toolchain_bin="$(cd -- "${stable_toolchain_bin}" && pwd -P)"
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
  RUSTFLAGS RPM_CLOUD_TEST_SECRET
do
  case "\${variable}" in
    CARGO_HOME|RUSTUP_HOME|RUSTUP_TOOLCHAIN) ;;
    *) [ -z "\${!variable+x}" ] || { printf 'git-env-leak=%s\\n' "\${variable}" >&2; exit 90; } ;;
  esac
done
[ "\${CARGO_HOME}" = "\${original_home}/.cargo" ] || exit 91
[ "\${RUSTUP_HOME}" = "\${canonical_rustup_home}" ] || exit 92
[ "\${RUSTUP_TOOLCHAIN}" = stable ] || exit 93
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
for variable in HTTP_PROXY HTTPS_PROXY http_proxy https_proxy ALL_PROXY all_proxy \
  NO_PROXY no_proxy CARGO_REGISTRIES_CRATES_IO_INDEX CARGO_HTTP_PROXY CARGO_NET_OFFLINE \
  CARGO_SOURCE_CRATES_IO_REPLACE_WITH CARGO_SOURCE_FOO_REPLACE_WITH CARGO_REGISTRY_TOKEN RUSTUP_DIST_SERVER \
  RUSTUP_UPDATE_ROOT RUSTC_WRAPPER CARGO_BUILD_RUSTC_WRAPPER RUSTFLAGS \
  RPM_CLOUD_TEST_SECRET
do
  [ -z "\${!variable+x}" ] || { printf 'env-leak=%s\\n' "\${variable}" >>"\${log_file}"; exit 90; }
done
[ "\${CARGO_HOME}" = "\${original_home}/.cargo" ] || exit 91
[ "\${RUSTUP_HOME}" = "\${canonical_rustup_home}" ] || exit 92
[ "\${RUSTUP_TOOLCHAIN}" = stable ] || exit 93
[ "\${HOME}" != "\${original_home}" ] || exit 94
case "\${HOME}" in '${ambient_tmp}'*) exit 95 ;; esac
[ "\${GIT_CONFIG_GLOBAL}" = /dev/null ] || exit 96
[ "\${GIT_CONFIG_SYSTEM}" = /dev/null ] || exit 97
[ "\${GIT_CONFIG_NOSYSTEM}" = 1 ] || exit 98
[ "\${GIT_TERMINAL_PROMPT}" = 0 ] || exit 99
printf 'rustup %s\\n' "\$*" >>"\${log_file}"
if [ "\${1:-}" = which ] && [ "\${2:-}" = --toolchain ] && \\
  [ "\${3:-}" = stable ] && [ "\${4:-}" = cargo ]; then
  case "\${mode}" in
    dotdot) printf '%s\\n' '${stable_canonical_toolchain_bin}/../bin/cargo' ;;
    *) printf '%s\\n' '${stable_canonical_toolchain_bin}/cargo' ;;
  esac
  exit 0
fi
if [ "\${1:-}" = which ] && [ "\${2:-}" = --toolchain ] && \\
  [ "\${3:-}" = stable ] && [ "\${4:-}" = rustc ]; then
  case "\${mode}" in
    rustc-missing) exit 0 ;;
    rustc-failure) printf 'fake rustc lookup failed\\n' >&2; exit 77 ;;
    different-toolchain) printf '%s\\n' '${canonical_rustup_home}/toolchains/other-fixture/bin/rustc' ;;
    *) printf '%s\\n' '${stable_canonical_toolchain_bin}/rustc' ;;
  esac
  exit 0
fi
if [ "\${1:-}" = component ] && [ "\${2:-}" = list ]; then
  if [ "\${mode}" = warm ] || [ "\${mode}" = missing-just ] || [ "\${mode}" = fetch-failure ]; then
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
for variable in HTTP_PROXY HTTPS_PROXY http_proxy https_proxy ALL_PROXY all_proxy \
  NO_PROXY no_proxy CARGO_HOME RUSTUP_HOME CARGO_REGISTRIES_CRATES_IO_INDEX \
  CARGO_HTTP_PROXY CARGO_NET_OFFLINE CARGO_SOURCE_CRATES_IO_REPLACE_WITH \
  CARGO_SOURCE_FOO_REPLACE_WITH CARGO_REGISTRY_TOKEN \
  RUSTUP_DIST_SERVER RUSTUP_UPDATE_ROOT RUSTC_WRAPPER CARGO_BUILD_RUSTC_WRAPPER \
  RUSTFLAGS RPM_CLOUD_TEST_SECRET
do
  case "\${variable}" in
    CARGO_HOME|RUSTUP_HOME) ;;
    *) [ -z "\${!variable+x}" ] || { printf 'env-leak=%s\\n' "\${variable}" >>"\${log_file}"; exit 90; } ;;
  esac
done
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

  if [ "${mode}" = different-toolchain ]; then
    mkdir -p "${other_toolchain_bin}"
    printf '#!/bin/bash\\nexit 0\\n' >"${other_toolchain_bin}/rustc"
    chmod +x "${other_toolchain_bin}/rustc"
  fi
  if [ "${mode}" = external-symlink ]; then
    mkdir -p "${case_dir}/external"
    printf '#!/bin/bash\\nexit 0\\n' >"${case_dir}/external/cargo"
    chmod +x "${case_dir}/external/cargo"
    rm -f "${stable_toolchain_bin}/cargo"
    ln -s "${case_dir}/external/cargo" "${stable_toolchain_bin}/cargo"
  fi
  if [ "${mode}" = parent-symlink ]; then
    parent_toolchain_dir="${case_dir}/external/stable-fixture"
    mkdir -p "${parent_toolchain_dir}/bin"
    mv "${stable_toolchain_bin}/cargo" "${parent_toolchain_dir}/bin/cargo"
    mv "${stable_toolchain_bin}/rustc" "${parent_toolchain_dir}/bin/rustc"
    rmdir "${stable_toolchain_bin}" "${home_dir}/.rustup/toolchains/stable-fixture"
    ln -s "${parent_toolchain_dir}" "${home_dir}/.rustup/toolchains/stable-fixture"
  fi

  for command_name in jq node python3; do
    [ "${command_name}" = "${omit_command}" ] && continue
    printf '#!/bin/bash\nexit 0\n' >"${trusted_bin}/${command_name}"
  done

  if [ "${mode}" = warm ] || [ "${mode}" = missing-just ] || [ "${mode}" = fetch-failure ]; then
    for command_name in rustfmt cargo-clippy; do
      printf '#!/bin/bash\nexit 0\n' >"${trusted_bin}/${command_name}"
    done
  fi
  if [ "${mode}" = warm ] || [ "${mode}" = fetch-failure ]; then
    printf '#!/bin/bash\nexit 0\n' >"${trusted_bin}/just"
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
    "TMPDIR=${case_dir}/ambient-tmp"
    "BASH_ENV=${case_dir}/bash-env"
    RPM_CLOUD_TEST_SECRET=ambient-secret
  )
  if [ "${trusted_path}" != __DEFAULT__ ]; then
    env_args+=("RPM_CODEX_CLOUD_TRUSTED_PATH=${trusted_path}")
  fi
  if [ "$#" -ge 7 ]; then
    env_args+=("NVM_BIN=${nvm_bin_override}")
  fi
  /usr/bin/env "${env_args[@]}" \
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
expected_fresh=$'rustup component list --toolchain stable --installed\nrustup component add --toolchain stable rustfmt\nrustup component add --toolchain stable clippy\nrustup which --toolchain stable cargo\nrustup which --toolchain stable rustc\ncargo install just --locked\ncargo fetch --quiet --locked\ncargo check --quiet --offline --locked --all-targets'
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
expected_warm=$'rustup component list --toolchain stable --installed\nrustup which --toolchain stable cargo\nrustup which --toolchain stable rustc\ncargo fetch --quiet --locked\ncargo check --quiet --offline --locked --all-targets'
actual_warm="$(commands_without_environment_markers "${warm_log}")"
[ "${actual_warm}" = "${expected_warm}" ] || {
  printf 'unexpected warm setup commands:\n%s\n' "${actual_warm}" >&2
  exit 1
}
assert_not_contains "$(<"${warm_log}")" 'cargo-proxy'
assert_not_contains "$(<"${warm_log}")" 'rustup-proxy-network-attempt'

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
