#!/usr/bin/env bash
set -euo pipefail

# Validate the untrusted output of `codex cloud diff` before a caller applies it
# to an exact-base checkout.  This script deliberately does not apply the code
# part of the patch.  It extracts and validates only the result envelope, then
# writes a result JSON line and a code-only patch for the caller's git gate.

readonly MAX_PATCH_BYTES=10485760
readonly MAX_SECTIONS=200
readonly RESULT_PATH='.codex-cloud-result.json'

usage() {
  cat >&2 <<'EOF'
usage: validate-cloud-diff.sh --patch FILE [--lane issue|review|merge]
  [--mode issue|review|merge] --expected-issue NUMBER
  [--expected-pr NUMBER] --expected-base-sha SHA [--expected-head-sha SHA]
  --result-out FILE --code-patch-out FILE
EOF
}

die() {
  printf 'validate_cloud_diff.error=%s\n' "$*" >&2
  exit 2
}

patch_path=''
lane=''
mode=''
expected_issue=''
expected_pr=''
expected_base_sha=''
expected_head_sha=''
result_out=''
code_patch_out=''

while [ "$#" -gt 0 ]; do
  case "$1" in
    --patch)
      [ "$#" -ge 2 ] || die 'missing-value:--patch'
      patch_path="$2"
      shift 2
      ;;
    --lane)
      [ "$#" -ge 2 ] || die 'missing-value:--lane'
      lane="$2"
      shift 2
      ;;
    --mode)
      [ "$#" -ge 2 ] || die 'missing-value:--mode'
      mode="$2"
      shift 2
      ;;
    --expected-issue)
      [ "$#" -ge 2 ] || die 'missing-value:--expected-issue'
      expected_issue="$2"
      shift 2
      ;;
    --expected-pr)
      [ "$#" -ge 2 ] || die 'missing-value:--expected-pr'
      expected_pr="$2"
      shift 2
      ;;
    --expected-base-sha)
      [ "$#" -ge 2 ] || die 'missing-value:--expected-base-sha'
      expected_base_sha="$2"
      shift 2
      ;;
    --expected-head-sha)
      [ "$#" -ge 2 ] || die 'missing-value:--expected-head-sha'
      expected_head_sha="$2"
      shift 2
      ;;
    --result-out)
      [ "$#" -ge 2 ] || die 'missing-value:--result-out'
      result_out="$2"
      shift 2
      ;;
    --code-patch-out)
      [ "$#" -ge 2 ] || die 'missing-value:--code-patch-out'
      code_patch_out="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "unknown-option:$1"
      ;;
  esac
done

[ -z "$lane" ] || [ -z "$mode" ] || [ "$lane" = "$mode" ] || die 'lane-mode-mismatch'
[ -n "$mode" ] && lane="$mode"
[ -n "$patch_path" ] || die 'missing:--patch'
[ -n "$lane" ] || die 'missing:--lane'
[ -n "$expected_issue" ] || die 'missing:--expected-issue'
[ -n "$expected_base_sha" ] || die 'missing:--expected-base-sha'
[ -n "$result_out" ] || die 'missing:--result-out'
[ -n "$code_patch_out" ] || die 'missing:--code-patch-out'

case "$lane" in
  issue|review|merge) ;;
  *) die 'invalid-lane' ;;
esac

[[ "$expected_issue" =~ ^[1-9][0-9]*$ ]] || die 'invalid-expected-issue'

if [ "$lane" = issue ]; then
  [ -z "$expected_pr" ] || die 'issue-does-not-accept-expected-pr'
else
  [[ "$expected_pr" =~ ^[1-9][0-9]*$ ]] || die "${lane}-requires-expected-pr"
fi

if [ "$lane" = issue ]; then
  [ -z "$expected_head_sha" ] || die 'issue-does-not-accept-expected-head-sha'
else
  [[ "$expected_head_sha" =~ ^[0-9a-fA-F]{40}$ ]] || die "${lane}-requires-expected-head-sha"
fi
[[ "$expected_base_sha" =~ ^[0-9a-fA-F]{40}$ ]] || die 'invalid-expected-base-sha'
expected_base_sha="$(printf '%s' "$expected_base_sha" | tr '[:upper:]' '[:lower:]')"
if [ -n "$expected_head_sha" ]; then
  expected_head_sha="$(printf '%s' "$expected_head_sha" | tr '[:upper:]' '[:lower:]')"
  [ "$expected_head_sha" != "$expected_base_sha" ] || die "${lane}-head-must-differ-from-base"
fi

for cli_path in "$patch_path" "$result_out" "$code_patch_out"; do
  case "$cli_path" in
    *$'\n'*|*$'\r'*) die 'path-contains-newline' ;;
  esac
done
[ "$result_out" != "$code_patch_out" ] || die 'outputs-must-differ'
[ "$patch_path" != "$result_out" ] || die 'result-output-overlaps-patch'
[ "$patch_path" != "$code_patch_out" ] || die 'code-output-overlaps-patch'

regular_link_count() {
  local path="$1"
  local count

  if count="$(stat -c '%h' -- "$path" 2>/dev/null)" && [[ "$count" =~ ^[0-9]+$ ]]; then
    printf '%s\n' "$count"
    return 0
  fi
  stat -f '%l' -- "$path" 2>/dev/null
}

validate_patch_file() {
  [ -f "$patch_path" ] || die 'patch-must-be-regular-file'
  [ ! -L "$patch_path" ] || die 'patch-symlink-forbidden'

  local link_count
  link_count="$(regular_link_count "$patch_path")" || die 'patch-stat-failed'
  [ "$link_count" = 1 ] || die 'patch-hardlink-forbidden'

  local byte_count
  byte_count="$(wc -c < "$patch_path")" || die 'patch-size-check-failed'
  byte_count="${byte_count//[[:space:]]/}"
  [[ "$byte_count" =~ ^[0-9]+$ ]] || die 'patch-size-check-failed'
  [ "$byte_count" -le "$MAX_PATCH_BYTES" ] || die 'patch-too-large'
}

validate_output_target() {
  local label="$1"
  local target="$2"

  case "$target" in
    ''|*$'\n'*|*$'\r'*) die "${label}-path-invalid" ;;
  esac

  [[ "$target" = /* ]] || die "${label}-path-must-be-absolute"
  [ ! -e "$target" ] || die "${label}-target-exists"
  [ ! -L "$target" ] || die "${label}-symlink-forbidden"
  python3 - "$label" "$target" <<'PY' || die "${label}-path-invalid"
import os
import stat
import sys
import unicodedata

_label, target = sys.argv[1:]
if (
    not os.path.isabs(target)
    or any(ord(char) < 0x20 or ord(char) == 0x7f for char in target)
    or any(unicodedata.category(char).startswith("C") for char in target)
    or any(char.isspace() for char in target)
    or any(component == ".." for component in target.split(os.path.sep))
):
    raise SystemExit(1)
absolute = os.path.abspath(target)
parent = os.path.dirname(absolute)
if not parent or not os.path.isdir(parent):
    raise SystemExit(1)
current = os.path.sep
for component in [item for item in parent.split(os.path.sep) if item]:
    current = os.path.join(current, component)
    metadata = os.lstat(current)
    if stat.S_ISLNK(metadata.st_mode):
        if current != "/var" or os.path.realpath(current) != "/private/var":
            raise SystemExit(1)
        continue
    if not stat.S_ISDIR(metadata.st_mode):
        raise SystemExit(1)
if os.path.lexists(absolute) or not os.access(parent, os.W_OK | os.X_OK):
    raise SystemExit(1)
PY
}

validate_patch_file
validate_output_target 'result-output' "$result_out"
validate_output_target 'code-output' "$code_patch_out"

repo_root="$(git rev-parse --show-toplevel 2>/dev/null)" || die 'not-a-git-checkout'
actual_head="$(git -C "$repo_root" rev-parse --verify HEAD^{commit} 2>/dev/null)" || die 'missing-head'
actual_head="$(printf '%s' "$actual_head" | tr '[:upper:]' '[:lower:]')"
if [ "$lane" = issue ] || [ "$lane" = merge ]; then
  [ "$actual_head" = "$expected_base_sha" ] || die 'checkout-head-mismatch'
else
  [ "$actual_head" = "$expected_head_sha" ] || die 'checkout-head-mismatch'
fi
status_output="$(git -C "$repo_root" status --porcelain=v1 --untracked-files=all 2>/dev/null)" || die 'status-read-failed'
[ -z "$status_output" ] || die 'dirty-checkout'

tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/validate-cloud-diff.XXXXXX")" || die 'temporary-directory-failed'
trap 'rm -rf "$tmp_dir"' EXIT

filtered_code_patch="$tmp_dir/code.patch"
result_patch="$tmp_dir/result.patch"
parse_error="$tmp_dir/parse-error"
if ! patch_meta="$(python3 - "$patch_path" "$MAX_PATCH_BYTES" "$MAX_SECTIONS" "$filtered_code_patch" "$result_patch" <<'PY' 2>"$parse_error"
import os
import re
import stat
import sys
import unicodedata


RESULT_PATH = ".codex-cloud-result.json"


class PatchError(Exception):
    pass


def fail(message: str) -> None:
    raise PatchError(message)


def read_patch(path: str, max_bytes: int) -> bytes:
    flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
    try:
        fd = os.open(path, flags)
    except OSError as error:
        fail(f"patch-open-failed:{error.errno}")
    try:
        metadata = os.fstat(fd)
        if not stat.S_ISREG(metadata.st_mode):
            fail("patch-must-be-regular-file")
        if metadata.st_nlink != 1:
            fail("patch-hardlink-forbidden")
        if metadata.st_size > max_bytes:
            fail("patch-too-large")
        data = os.fdopen(fd, "rb").read()
        if len(data) > max_bytes:
            fail("patch-too-large")
        return data
    except Exception:
        try:
            os.close(fd)
        except OSError:
            pass
        raise


def strip_line(raw: bytes) -> bytes:
    if raw.endswith(b"\r\n") or b"\r" in raw:
        fail("patch-contains-carriage-return")
    return raw[:-1] if raw.endswith(b"\n") else raw


def decode_path(raw: bytes) -> str:
    try:
        path = raw.decode("utf-8")
    except UnicodeDecodeError:
        fail("path-not-utf8")
    if not path:
        fail("empty-path")
    if path.startswith("/"):
        fail("absolute-path")
    if any(ord(char) < 0x20 or ord(char) == 0x7F for char in path):
        fail("path-contains-control-character")
    if any(unicodedata.category(char).startswith("C") for char in path):
        fail("path-contains-invisible-character")
    if any(char.isspace() for char in path):
        fail("path-contains-whitespace")
    if any(char in "\\\"'" for char in path):
        fail("path-uses-quoted-or-escaped-form")
    if ":" in path:
        fail("path-contains-colon")
    components = path.split("/")
    if any(component in ("", ".", "..") for component in components):
        fail("path-traversal-or-empty-component")
    if path == ".git" or path.startswith(".git/"):
        fail("git-internal-path-forbidden")
    return path


def parse_diff_header(raw: bytes) -> tuple[str, str]:
    header = strip_line(raw)
    match = re.fullmatch(rb"diff --git (a/[^ \t\r\n]+) (b/[^ \t\r\n]+)", header)
    if match is None:
        fail("malformed-diff-header")
    old_path = decode_path(match.group(1)[2:])
    new_path = decode_path(match.group(2)[2:])
    if old_path != new_path:
        fail("rename-or-copy-forbidden")
    return old_path, new_path


def parse_mode(value: bytes) -> int:
    if re.fullmatch(rb"[0-7]{6}", value) is None:
        fail("malformed-file-mode")
    mode = int(value, 8)
    if (mode & 0o170000) != 0o100000 or mode != 0o100644:
        fail("symlink-submodule-or-unsafe-mode-forbidden")
    return mode


def metadata_path(raw: bytes, prefix: bytes, expected_prefix: bytes, expected: str) -> str | None:
    if not raw.startswith(prefix):
        return None
    value = strip_line(raw[len(prefix):])
    if b"\t" in value:
        fail("path-contains-whitespace")
    if value == b"/dev/null":
        return "/dev/null"
    if not value.startswith(expected_prefix):
        fail("malformed-file-path-header")
    parsed = decode_path(value[len(expected_prefix):])
    if parsed != expected:
        fail("file-path-header-mismatch")
    return parsed


def validate_section(path: str, lines: list[bytes], is_result: bool) -> None:
    old_path: str | None = None
    new_path: str | None = None
    modes: list[tuple[str, int]] = []
    saw_old_header = False
    saw_new_header = False
    saw_hunk = False
    metadata_phase = True

    for raw in lines[1:]:
        line = strip_line(raw)

        if line.startswith(b"GIT binary patch") or line.startswith(b"Binary files "):
            fail("binary-patch-forbidden")
        if line.startswith(b"rename from ") or line.startswith(b"rename to ") or \
           line.startswith(b"copy from ") or line.startswith(b"copy to ") or \
           line.startswith(b"similarity index ") or line.startswith(b"dissimilarity index "):
            fail("rename-or-copy-forbidden")
        if line.startswith(b"Subproject commit "):
            fail("submodule-forbidden")
        if line.startswith(b"new file mode "):
            modes.append(("new", parse_mode(line[len(b"new file mode "):])))
            continue
        if line.startswith(b"deleted file mode "):
            modes.append(("deleted", parse_mode(line[len(b"deleted file mode "):])))
            continue
        if line.startswith(b"old mode ") or line.startswith(b"new mode "):
            fail("mode-change-forbidden")
        if line.startswith(b"index "):
            match = re.fullmatch(
                rb"index [0-9a-fA-F]+\.\.[0-9a-fA-F]+(?: ([0-7]{6}))?", line
            )
            if match is None:
                fail("malformed-index-line")
            if match.group(1) is not None:
                parse_mode(match.group(1))
            continue

        old_header = metadata_path(raw, b"--- ", b"a/", path)
        if old_header is not None:
            if saw_old_header:
                fail("duplicate-old-file-header")
            old_path = old_header
            saw_old_header = True
            continue
        new_header = metadata_path(raw, b"+++ ", b"b/", path)
        if new_header is not None:
            if saw_new_header:
                fail("duplicate-new-file-header")
            new_path = new_header
            saw_new_header = True
            continue

        if line.startswith(b"@@"):
            saw_hunk = True
            metadata_phase = False
            continue
        if line == b"\\ No newline at end of file":
            if not saw_hunk:
                fail("malformed-diff-line")
            continue
        if not metadata_phase and (line == b"" or line.startswith((b" ", b"+", b"-"))):
            continue
        if metadata_phase and line == b"":
            continue
        fail("malformed-diff-line")

    if not saw_old_header or not saw_new_header:
        fail("malformed-diff-section")
    if old_path == "/dev/null" and new_path == "/dev/null":
        fail("malformed-file-path-header")
    if is_result:
        if not saw_hunk:
            fail("malformed-diff-section")
        if old_path != "/dev/null" or new_path != path:
            fail("result-must-be-new-file")
        if [kind for kind, _mode in modes] != ["new"] or modes[0][1] != 0o100644:
            fail("result-must-be-regular-new-file")
    else:
        kinds = [kind for kind, _mode in modes]
        if len(kinds) != len(set(kinds)):
            fail("duplicate-file-mode")
        if "new" in kinds and old_path != "/dev/null":
            fail("malformed-new-file-section")
        if "deleted" in kinds and new_path != "/dev/null":
            fail("malformed-deleted-file-section")
        if not saw_hunk:
            if kinds == ["new"] and old_path == "/dev/null" and new_path == path:
                return
            if kinds == ["deleted"] and old_path == path and new_path == "/dev/null":
                return
            fail("malformed-diff-section")


def validate_patch(
    data: bytes,
    code_output: str,
    result_output: str,
    max_sections: int,
) -> tuple[int, int, int]:
    if b"\x00" in data:
        fail("patch-contains-nul")
    lines = data.splitlines(keepends=True)
    sections: list[tuple[str, list[bytes]]] = []
    current_path: str | None = None
    current_lines: list[bytes] = []

    for raw in lines:
        if raw.startswith(b"diff --git "):
            if current_path is not None:
                sections.append((current_path, current_lines))
            old_path, new_path = parse_diff_header(raw)
            current_path = old_path
            current_lines = [raw]
        elif current_path is not None:
            current_lines.append(raw)
        else:
            fail("malformed-patch-preamble")

    if current_path is not None:
        sections.append((current_path, current_lines))
    if not sections:
        fail("patch-has-no-git-diff-sections")
    if len(sections) > max_sections:
        fail(f"patch-section-count-exceeds-{max_sections}")

    seen: set[str] = set()
    result_count = 0
    code_path_count = 0
    code_sections: list[bytes] = []
    result_sections: list[bytes] = []
    for path, section_lines in sections:
        if path in seen:
            fail("duplicate-patch-path")
        seen.add(path)
        if path == RESULT_PATH:
            result_count += 1
            validate_section(path, section_lines, True)
            result_sections.append(b"".join(section_lines))
        elif (
            path == "AGENTS.md"
            or path.endswith("/AGENTS.md")
            or path in (".github", ".agents", ".codex", ".githooks")
            or path.startswith((".github/", ".agents/", ".codex/", ".githooks/"))
            # These repository controls run before or during a Cloud task and
            # therefore stay on the trusted side of the publisher boundary.
            # Keep this list aligned with publish-cloud-diff.sh.  Product
            # sources and ordinary data files remain eligible for publication.
            or path in {
                ".cargo",
                "clippy.toml",
                "justfile",
                "rust-toolchain",
                "rust-toolchain.toml",
                "rustfmt.toml",
                ".rustfmt.toml",
                "scripts/audit-fixtures.sh",
                "scripts/benchmark-node-semver.mjs",
                "scripts/benchmark-semver.mjs",
                "scripts/codex-cloud-setup.sh",
                "scripts/setup-codex-cloud-lane.sh",
                "scripts/codex-rust-analyzer.sh",
                "scripts/install-git-hooks.sh",
                "scripts/run-local-git-hook-gate.sh",
                "scripts/worktree-cleanup.sh",
                "scripts/worktree-setup.sh",
                "scripts/collect-merge-gate-evidence.sh",
                "scripts/publish-cloud-merge.sh",
                "scripts/quarantine-merge-selector-anomaly.sh",
            }
            or path.startswith(".cargo/")
            or path.startswith(
                (
                    "scripts/agent-loop-",
                    "scripts/check-agent-",
                    "scripts/safe-direct-merge",
                    "scripts/check-cloud-",
                    "scripts/check-merge-",
                    "scripts/check-workflow-",
                    "scripts/collect-pr-review-context",
                    "scripts/collect-merge-gate-evidence",
                    "scripts/create-review-followup-issue",
                    "scripts/publish-cloud-merge",
                    "scripts/quarantine-merge-selector-anomaly",
                    "scripts/publish-cloud-diff",
                    "scripts/validate-agent-workflow-assets",
                    "scripts/validate-cloud-diff",
                )
            )
            or path.startswith("scripts/test-")
        ):
            fail(f"protected-path:{path}")
        else:
            code_path_count += 1
            validate_section(path, section_lines, False)
            code_sections.append(b"".join(section_lines))

    if result_count != 1:
        fail("result-file-count-must-be-one")
    with open(code_output, "wb") as stream:
        stream.write(b"".join(code_sections))
    with open(result_output, "wb") as stream:
        stream.write(result_sections[0])
    return len(sections), code_path_count, result_count


try:
    patch = read_patch(sys.argv[1], int(sys.argv[2]))
    section_count, code_path_count, result_count = validate_patch(
        patch, sys.argv[4], sys.argv[5], int(sys.argv[3])
    )
    print(f"{section_count}\t{code_path_count}\t{result_count}")
except PatchError as error:
    print(str(error), file=sys.stderr)
    raise SystemExit(1)
except (OSError, ValueError) as error:
    print(f"patch-validation-failed:{error}", file=sys.stderr)
    raise SystemExit(1)
PY
)"; then
  reason="$(tr '\n' ' ' <"$parse_error" | cut -c1-240)"
  [ -n "$reason" ] || reason='malformed-patch'
  die "invalid-patch:$reason"
fi

read -r section_count code_path_count result_count extra <<<"$patch_meta"
[ -z "${extra:-}" ] || die 'invalid-patch-metadata'
[[ "$section_count" =~ ^[0-9]+$ ]] || die 'invalid-patch-metadata'
[[ "$code_path_count" =~ ^[0-9]+$ ]] || die 'invalid-patch-metadata'
[ "$result_count" = 1 ] || die 'result-file-count-must-be-one'

extract_root="$tmp_dir/extract"
mkdir -p "$extract_root" || die 'temporary-repository-failed'
if ! GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
  git -C "$extract_root" init --quiet >"$tmp_dir/git-init.log" 2>&1; then
  die 'temporary-repository-failed'
fi

if ! GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
  git -C "$extract_root" -c core.autocrlf=false apply --check \
  --binary --whitespace=nowarn "$result_patch" \
  >"$tmp_dir/git-apply-check.log" 2>&1; then
  die 'result-extraction-check-failed'
fi
if ! GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
  git -C "$extract_root" -c core.autocrlf=false apply \
  --binary --whitespace=nowarn "$result_patch" \
  >"$tmp_dir/git-apply.log" 2>&1; then
  die 'result-extraction-failed'
fi

result_file="$extract_root/$RESULT_PATH"
[ -f "$result_file" ] || die 'result-extraction-missing'
[ ! -L "$result_file" ] || die 'result-symlink-forbidden'
result_link_count="$(regular_link_count "$result_file")" || die 'result-stat-failed'
[ "$result_link_count" = 1 ] || die 'result-hardlink-forbidden'

result_error="$tmp_dir/result-error"
if ! validated_result="$(python3 - "$result_file" "$lane" "$expected_issue" "$expected_pr" "$expected_base_sha" "$expected_head_sha" <<'PY' 2>"$result_error"
import json
import hashlib
import os
import re
import stat
import sys
import unicodedata


MAX_RESULT_BYTES = 1048576
MAX_SUMMARY_BYTES = 4000
MAX_FOLLOWUP_TITLE_BYTES = 256
MAX_FOLLOWUP_BODY_BYTES = 131072
MAX_FOLLOWUP_LABEL_BYTES = 100
MAX_VALIDATION_ITEMS = 50
# These byte limits mirror scripts/publish-cloud-diff.sh.
MAX_VALIDATION_STRING_BYTES = 2048
MAX_THREAD_ITEMS = 100
MAX_THREAD_ID_BYTES = 256
MAX_FOLLOWUP_ITEMS = 5
MAX_FOLLOWUP_LABELS = 20


class ResultError(Exception):
    pass


def fail(message: str) -> None:
    raise ResultError(message)


def unique_object(pairs: list[tuple[str, object]]) -> dict[str, object]:
    result: dict[str, object] = {}
    for key, value in pairs:
        if key in result:
            fail("result-duplicate-json-key")
        result[key] = value
    return result


def reject_constant(value: str) -> None:
    fail(f"result-invalid-number:{value}")


def checked_text(
    value: object,
    label: str,
    max_bytes: int,
    nonempty: bool = True,
    allow_newlines: bool = False,
) -> str:
    if type(value) is not str:
        fail(f"result-{label}-must-be-string")
    if nonempty and not value:
        fail(f"result-{label}-must-not-be-empty")
    if len(value.encode("utf-8")) > max_bytes:
        fail(f"result-{label}-too-long")
    allowed_controls = "\n\t" if allow_newlines else ""
    if any((ord(char) < 0x20 and char not in allowed_controls) or ord(char) == 0x7F for char in value):
        fail(f"result-{label}-contains-control-character")
    if any(
        unicodedata.category(char).startswith("C") and char not in allowed_controls
        for char in value
    ):
        fail(f"result-{label}-contains-invisible-character")
    return value


def checked_body(value: object, source: str) -> str:
    if type(value) is not str:
        fail("result-followup-body-must-be-string")
    if not value:
        fail("result-followup-body-must-not-be-empty")
    if len(value.encode("utf-8")) > MAX_FOLLOWUP_BODY_BYTES:
        fail("result-followup-body-too-long")
    if any(
        (ord(char) < 0x20 and char not in "\n\t") or ord(char) == 0x7F
        for char in value
    ):
        fail("result-followup-body-contains-control-character")
    if any(
        unicodedata.category(char).startswith("C") and char not in "\n\t"
        for char in value
    ):
        fail("result-followup-body-contains-invisible-character")
    source_marker = f"<!-- rpm-agent-followup-source: {source} -->"
    if not value.startswith(source_marker + "\n") and value != source_marker:
        fail("result-followup-source-marker-not-at-top")
    if value.count(source_marker) != 1:
        fail("result-followup-source-marker-invalid")
    if re.search(r"rpm-agent-followup-fingerprint\s*:", value, re.IGNORECASE):
        fail("result-followup-body-contains-fingerprint-marker")
    return value


def read_result(path: str) -> dict[str, object]:
    flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
    try:
        fd = os.open(path, flags)
    except OSError as error:
        fail(f"result-open-failed:{error.errno}")
    try:
        metadata = os.fstat(fd)
        if not stat.S_ISREG(metadata.st_mode):
            fail("result-must-be-regular-file")
        if metadata.st_nlink != 1:
            fail("result-hardlink-forbidden")
        if metadata.st_size > MAX_RESULT_BYTES:
            fail("result-too-large")
        with os.fdopen(fd, "r", encoding="utf-8") as stream:
            value = json.load(
                stream,
                object_pairs_hook=unique_object,
                parse_constant=reject_constant,
            )
    except ResultError:
        raise
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as error:
        fail(f"result-invalid-json:{type(error).__name__}")
    if type(value) is not dict:
        fail("result-must-be-object")
    return value


def validate(
    value: dict[str, object],
    lane: str,
    issue_text: str,
    pr_text: str,
    base_sha: str,
    head_sha: str,
) -> None:
    expected_keys = {
        "version",
        "lane",
        "status",
        "issue",
        "pr",
        "base_sha",
        "head_sha",
        "summary",
        "validation",
        "actionable_findings_remaining",
        "next_state",
        "correction_label",
        "resolved_thread_ids",
        "followups",
    }
    if set(value) != expected_keys:
        fail("result-schema-keys-mismatch")
    if type(value.get("version")) is not int or value["version"] != 1:
        fail("result-version-must-be-1")
    if value.get("lane") != lane:
        fail("result-lane-mismatch")
    status = value.get("status")
    if status not in {"patch", "merge", "no-work", "blocked"}:
        fail("result-status-invalid")
    issue = value.get("issue")
    if type(issue) is not int or issue <= 0 or issue != int(issue_text):
        fail("result-issue-mismatch")
    if value.get("base_sha") != base_sha:
        fail("result-base-sha-mismatch")
    pr_value = value.get("pr")
    head_value = value.get("head_sha")
    if lane == "issue":
        if pr_value is not None:
            fail("result-issue-pr-must-be-null")
        if value.get("head_sha") is not None:
            fail("result-issue-head-sha-must-be-null")
        pr_number = None
    elif lane in {"review", "merge"}:
        if type(pr_value) is not int or pr_value <= 0 or pr_value != int(pr_text):
            fail("result-pr-mismatch")
        if head_value != head_sha:
            fail("result-head-sha-mismatch")
        if head_value == base_sha:
            fail(f"result-{lane}-head-sha-must-differ-from-base")
        pr_number = pr_value

    checked_text(value.get("summary"), "summary", MAX_SUMMARY_BYTES)

    validation = value.get("validation")
    if type(validation) is not list:
        fail("result-validation-must-be-array")
    if len(validation) > MAX_VALIDATION_ITEMS:
        fail("result-validation-too-many-items")
    for item in validation:
        checked_text(item, "validation-string", MAX_VALIDATION_STRING_BYTES)

    if type(value.get("actionable_findings_remaining")) is not bool:
        fail("result-actionable-findings-must-be-boolean")
    actionable = value["actionable_findings_remaining"]

    next_state = value.get("next_state")
    if next_state not in {"unchanged", "review-pending", "awaiting-merge", "blocked"}:
        fail("result-next-state-invalid")
    correction = value.get("correction_label")
    if correction is not None:
        correction = checked_text(correction, "correction-label", 64)
        if re.fullmatch(r"agent:correction-[0-5]", correction) is None:
            fail("result-correction-label-invalid")

    thread_ids = value.get("resolved_thread_ids")
    if type(thread_ids) is not list:
        fail("result-resolved-thread-ids-must-be-array")
    if len(thread_ids) > MAX_THREAD_ITEMS:
        fail("result-resolved-thread-ids-too-many-items")
    normalized_thread_ids: list[str] = []
    for item in thread_ids:
        thread_id = checked_text(item, "thread-id", MAX_THREAD_ID_BYTES)
        if re.fullmatch(r"[A-Za-z0-9_:-]{1,256}", thread_id) is None:
            fail("result-thread-id-invalid")
        normalized_thread_ids.append(thread_id)
    if len(set(normalized_thread_ids)) != len(normalized_thread_ids):
        fail("result-resolved-thread-ids-duplicate")

    followups = value.get("followups")
    if type(followups) is not list:
        fail("result-followups-must-be-array")
    if len(followups) > MAX_FOLLOWUP_ITEMS:
        fail("result-followups-too-many-items")
    followup_keys = {"title", "body", "source", "fingerprint", "labels"}
    source_pattern = re.compile(r"^(?:pr|issue):[1-9][0-9]*$")
    fingerprint_pattern = re.compile(r"^sha256:[0-9a-f]{64}$")
    fingerprints: set[str] = set()
    for followup in followups:
        if type(followup) is not dict or set(followup) != followup_keys:
            fail("result-followup-schema-keys-mismatch")
        title = checked_text(
            followup.get("title"),
            "followup-title",
            MAX_FOLLOWUP_TITLE_BYTES,
        )
        if "\n" in title or "\r" in title:
            fail("result-followup-title-contains-newline")
        source = followup.get("source")
        if type(source) is not str or source_pattern.fullmatch(source) is None:
            fail("result-followup-source-invalid")
        allowed_sources = {f"issue:{issue}"}
        if pr_number is not None:
            allowed_sources.add(f"pr:{pr_number}")
        if source not in allowed_sources:
            fail("result-followup-source-mismatch")
        body = checked_body(followup.get("body"), source)
        fingerprint = followup.get("fingerprint")
        if type(fingerprint) is not str or fingerprint_pattern.fullmatch(fingerprint) is None:
            fail("result-followup-fingerprint-invalid")
        expected_fingerprint = "sha256:" + hashlib.sha256(
            title.encode("utf-8") + b"\0" + body.encode("utf-8")
        ).hexdigest()
        if fingerprint != expected_fingerprint:
            fail("result-followup-fingerprint-mismatch")
        if fingerprint in fingerprints:
            fail("result-followup-fingerprint-duplicate")
        fingerprints.add(fingerprint)
        labels = followup.get("labels")
        if type(labels) is not list:
            fail("result-followup-labels-must-be-array")
        if len(labels) > MAX_FOLLOWUP_LABELS:
            fail("result-followup-labels-too-many")
        seen_labels: set[str] = set()
        for label in labels:
            label_text = checked_text(
                label,
                "followup-label",
                MAX_FOLLOWUP_LABEL_BYTES,
            )
            if re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9 ._+/&#()'\-]*", label_text) is None:
                fail("result-followup-label-not-ordinary")
            if label_text.lower().startswith(("agent:", "process:", "codex-label")):
                fail("result-followup-reserved-label")
            if label_text in seen_labels:
                fail("result-followup-duplicate-label")
            seen_labels.add(label_text)

    if lane == "issue":
        if normalized_thread_ids:
            fail("result-issue-thread-ids-must-be-empty")
        if status == "patch":
            if next_state != "review-pending" or actionable is not False or correction != "agent:correction-0":
                fail("result-issue-patch-state-incoherent")
        elif status == "no-work":
            if next_state != "unchanged" or actionable is not False or correction is not None or followups:
                fail("result-issue-no-work-state-incoherent")
        elif status == "blocked":
            if next_state != "blocked" or correction is not None:
                fail("result-issue-blocked-state-incoherent")
        else:
            fail("result-issue-status-invalid")
    elif lane == "review":
        if status == "patch":
            if correction is None or re.fullmatch(r"agent:correction-[1-5]", correction) is None:
                fail("result-review-patch-counter-invalid")
            if next_state != "review-pending" or actionable is not True:
                fail("result-review-patch-state-incoherent")
        elif status == "no-work":
            if next_state not in {"unchanged", "awaiting-merge"} or actionable is not False or correction is not None:
                fail("result-review-no-work-state-incoherent")
            if next_state == "unchanged" and (normalized_thread_ids or followups):
                fail("result-review-no-work-state-incoherent")
            # Deferred, unrelated findings are allowed to travel with a clean
            # review handoff.  They are published as separate issues by the
            # trusted Action publisher before the linked issue advances to
            # awaiting-merge.  Review threads still cannot be claimed here:
            # only a fixed change may resolve a thread.
            if next_state == "awaiting-merge" and normalized_thread_ids:
                fail("result-review-no-work-state-incoherent")
        elif status == "blocked":
            if next_state != "blocked" or correction is not None or normalized_thread_ids or followups:
                fail("result-review-blocked-state-incoherent")
        else:
            fail("result-review-status-invalid")
    elif lane == "merge":
        if normalized_thread_ids or followups:
            fail("result-merge-mutation-arrays-must-be-empty")
        if status == "merge":
            if next_state != "awaiting-merge" or actionable is not False or correction is not None:
                fail("result-merge-state-incoherent")
        elif status == "no-work":
            if next_state != "unchanged" or actionable is not False or correction is not None:
                fail("result-merge-no-work-state-incoherent")
        elif status == "blocked":
            if next_state != "blocked" or actionable is not False or correction is not None:
                fail("result-merge-blocked-state-incoherent")
        else:
            fail("result-merge-status-invalid")


try:
    result_path, lane, issue_text, pr_text, base_sha, head_sha = sys.argv[1:]
    result = read_result(result_path)
    validate(result, lane, issue_text, pr_text, base_sha, head_sha)
    print(json.dumps(result, ensure_ascii=False, separators=(",", ":"), sort_keys=True))
except ResultError as error:
    print(str(error), file=sys.stderr)
    raise SystemExit(1)
except (OSError, ValueError) as error:
    print(f"result-validation-failed:{error}", file=sys.stderr)
    raise SystemExit(1)
PY
)"; then
  reason="$(tr '\n' ' ' <"$result_error" | cut -c1-240)"
  [ -n "$reason" ] || reason='invalid-result-json'
  die "invalid-result:$reason"
fi

code_patch_bytes="$(wc -c <"$filtered_code_patch")" || die 'code-patch-size-check-failed'
code_patch_bytes="${code_patch_bytes//[[:space:]]/}"
[[ "$code_patch_bytes" =~ ^[0-9]+$ ]] || die 'code-patch-size-check-failed'

status="$(python3 - "$result_file" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as stream:
    print(json.load(stream)["status"])
PY
)" || die 'result-status-read-failed'

case "$status" in
  patch)
    [ "$code_path_count" -gt 0 ] || die 'patch-status-requires-code-patch'
    [ "$code_patch_bytes" -gt 0 ] || die 'patch-status-requires-code-patch'
    if ! GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
      git -C "$repo_root" -c core.hooksPath=/dev/null apply --check \
      --binary --whitespace=nowarn "$filtered_code_patch" \
      >"$tmp_dir/code-apply-check.log" 2>&1; then
      die 'code-patch-apply-check-failed'
    fi
    ;;
  merge|no-work|blocked)
    [ "$code_path_count" -eq 0 ] || die 'no-code-allowed-for-terminal-status'
    : >"$filtered_code_patch"
    code_patch_bytes=0
    ;;
  *)
    die 'invalid-result-status'
    ;;
esac

result_source="$tmp_dir/result.jsonl"
printf '%s\n' "$validated_result" >"$result_source"

write_atomic() {
  local source="$1"
  local target="$2"
  local parent
  local temporary

  parent="$(dirname -- "$target")"
  temporary="$(mktemp "$parent/.validate-cloud-diff-output.XXXXXX")" || return 1
  chmod 600 "$temporary" || {
    rm -f "$temporary"
    return 1
  }
  if ! cp "$source" "$temporary"; then
    rm -f "$temporary"
    return 1
  fi
  if ! ln -- "$temporary" "$target" 2>/dev/null; then
    rm -f "$temporary"
    return 1
  fi
  rm -f "$temporary"
}

write_atomic "$result_source" "$result_out" || die 'result-output-write-failed'
if ! write_atomic "$filtered_code_patch" "$code_patch_out"; then
  rm -f -- "$result_out"
  die 'code-output-write-failed'
fi

printf 'validate_cloud_diff.PASS=lane=%s status=%s issue=%s code_paths=%s sections=%s\n' \
  "$lane" "$status" "$expected_issue" "$code_path_count" "$section_count"
