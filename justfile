set shell := ["bash", "-euo", "pipefail", "-c"]
set export

CARGO_TERM_COLOR := "never"

default:
    @just --list --unsorted

# Build the local debug binary.
build:
    @echo "::rpm::begin build cargo build --locked"
    cargo build --locked
    @echo "::rpm::end build"

# Run the strict local validation gate.
validate: format-check audit-fixtures fixture-smoke check lint test docs

alias verify := validate

# Check Rust compilation without producing the final binary.
check:
    @echo "::rpm::begin check cargo check --locked --all-targets"
    cargo check --locked --all-targets
    @echo "::rpm::end check"

# Format Rust sources in place.
format:
    @echo "::rpm::begin format cargo fmt --all"
    cargo fmt --all
    @echo "::rpm::end format"

# Verify Rust formatting without changing files.
format-check:
    @echo "::rpm::begin format-check cargo fmt --all --check"
    cargo fmt --all --check
    @echo "::rpm::end format-check"

# Run Rust lints with the same scope as CI.
lint:
    @echo "::rpm::begin lint cargo clippy strict"
    cargo clippy --locked --all-targets --all-features -- -D warnings -D clippy::dbg_macro -D clippy::todo -D clippy::unimplemented -D clippy::wildcard_imports -D clippy::indexing_slicing -D clippy::integer_division -D clippy::float_cmp -D clippy::large_stack_arrays -D clippy::large_stack_frames -D clippy::disallowed_methods -D clippy::disallowed_types -D clippy::disallowed_macros
    @echo "::rpm::end lint"

# Run tests. Extra cargo test args may be passed after the recipe name.
test *args:
    @echo "::rpm::begin test cargo test --locked --all-targets {{args}}"
    cargo test --locked --all-targets {{args}}
    @echo "::rpm::end test"

# Build documentation and fail on rustdoc warnings.
docs:
    @echo "::rpm::begin docs RUSTDOCFLAGS=-Dwarnings cargo doc --locked --no-deps"
    RUSTDOCFLAGS="-Dwarnings" cargo doc --locked --no-deps
    @echo "::rpm::end docs"

# Audit fixture structure before running behavior tests.
audit-fixtures:
    @echo "::rpm::begin audit-fixtures"
    ./scripts/audit-fixtures.sh
    @echo "::rpm::end audit-fixtures"

# Verify fixture creation helpers produce auditable fixtures.
fixture-smoke:
    @echo "::rpm::begin fixture-smoke"
    ./scripts/test-fixture-tools.sh
    @echo "::rpm::end fixture-smoke"

# Run benchmarks when benchmark targets exist. Extra cargo bench args are forwarded.
bench *args:
    @echo "::rpm::begin bench cargo bench --locked {{args}}"
    cargo bench --locked {{args}}
    @echo "::rpm::end bench"

# Create a new install-project fixture skeleton under tests/fixtures/install-projects.
fixture name:
    @echo "::rpm::begin fixture {{name}}"
    ./scripts/new-install-fixture.sh "{{name}}"
    @echo "::rpm::end fixture {{name}}"

# Create a new performance fixture by copying the current benchmark baseline.
bench-fixture name:
    @echo "::rpm::begin bench-fixture {{name}}"
    ./scripts/new-bench-fixture.sh "{{name}}"
    @echo "::rpm::end bench-fixture {{name}}"
