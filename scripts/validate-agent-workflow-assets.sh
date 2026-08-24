#!/usr/bin/env bash
set -euo pipefail

status="ok"
format="jsonl"
skill_validator="${RPM_SKILL_VALIDATOR:-}"

while [ "$#" -gt 0 ]; do
  case "$1" in
    --format)
      [ "$#" -ge 2 ] || {
        printf 'agent_assets.error=missing-format-value\n' >&2
        exit 2
      }
      format="$2"
      shift 2
      ;;
    --format=*)
      format="${1#--format=}"
      shift
      ;;
    *)
      printf 'agent_assets.error=unknown-argument:%s\n' "$1" >&2
      exit 2
      ;;
  esac
done

if [ "${format}" != "jsonl" ] && [ "${format}" != "text" ] && [ "${format}" != "summary" ]; then
  printf 'agent_assets.error=invalid-format:%s\n' "${format}" >&2
  exit 2
fi

if [ -z "${skill_validator}" ] && [ -n "${HOME:-}" ]; then
  candidate="${HOME}/.codex/skills/.system/skill-creator/scripts/quick_validate.py"
  if [ -f "${candidate}" ]; then
    skill_validator="${candidate}"
  fi
fi

emit_check() {
  local name="$1"
  local result="$2"
  local output="${3:-}"
  if [ "${format}" = "jsonl" ]; then
    jq -nc \
      --arg name "${name}" \
      --arg status "${result}" \
      --arg output "${output}" \
      '{type:"agent_asset_check",data:{name:$name,status:$status,output:(if $output == "" then null else $output end)}}'
  elif [ "${format}" = "text" ] || [ "${result}" = "fail" ]; then
    printf 'agent_assets.%s=%s\n' "${name}" "${result}"
    if [ -n "${output}" ]; then
      printf 'agent_assets.%s.output.begin\n%s\nagent_assets.%s.output.end\n' \
        "${name}" "${output}" "${name}"
    fi
  fi
}

check() {
  local name="$1"
  shift
  local output
  if output="$("$@" 2>&1)"; then
    emit_check "${name}" "ok"
  else
    status="fail"
    emit_check "${name}" "fail" "${output}"
  fi
}

check_skill_policy_structure_negative() {
  PYTHONDONTWRITEBYTECODE=1 python3 - <<'PY'
import importlib.util
import pathlib
import tempfile

checker_path = pathlib.Path("scripts/check-agent-organization.py")
spec = importlib.util.spec_from_file_location("rpm_agent_organization", checker_path)
checker = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(checker)

malformed = {
    "empty-policy": "policy:\n",
    "relocated-child": "policy:\nallow_implicit_invocation: false\n",
    "interface-child": "interface:\n  allow_implicit_invocation: false\npolicy:\n",
    "nested-child": "policy:\n    allow_implicit_invocation: false\n",
    "duplicate-policy": "policy:\n  allow_implicit_invocation: false\npolicy:\n  allow_implicit_invocation: false\n",
    "duplicate-child": "policy:\n  allow_implicit_invocation: false\n  allow_implicit_invocation: false\n",
    "non-boolean": "policy:\n  allow_implicit_invocation: \"false\"\n",
    "document-start": "---\npolicy:\n  allow_implicit_invocation: false\n",
    "document-end": "policy:\n  allow_implicit_invocation: false\n...\n",
    "multiple-documents": "policy:\n  allow_implicit_invocation: false\n---\npolicy:\n  allow_implicit_invocation: true\n",
    "bom-document-start": "\ufeff---\npolicy:\n  allow_implicit_invocation: false\n",
    "bom-document-end": "\ufeff...\npolicy:\n  allow_implicit_invocation: false\n",
    "bom-document-end-after-policy": "policy:\n  allow_implicit_invocation: false\n\ufeff...\n",
}
for name, text in malformed.items():
    value, error = checker.parse_skill_invocation_policy(text)
    if error is None:
        raise SystemExit(f"{name} was accepted: value={value!r}")

document_marker_error = "YAML document markers are not supported in openai.yaml"
for name in (
    "document-start",
    "document-end",
    "multiple-documents",
    "bom-document-start",
    "bom-document-end",
    "bom-document-end-after-policy",
):
    _, error = checker.parse_skill_invocation_policy(malformed[name])
    if error is None or document_marker_error not in error:
        raise SystemExit(f"{name} did not report a document marker error: {error!r}")

bom_policy_value, bom_policy_error = checker.parse_skill_invocation_policy(
    "\ufeffpolicy:\n  allow_implicit_invocation: false\n"
)
if bom_policy_value is not False or bom_policy_error is not None:
    raise SystemExit(
        "valid BOM-prefixed policy was rejected: "
        f"value={bom_policy_value!r}, error={bom_policy_error!r}"
    )

policy_comment_value, policy_comment_error = checker.parse_skill_invocation_policy(
    "interface: # interface mapping comment\n"
    "policy: # policy mapping comment\n"
    "  allow_implicit_invocation: false\n"
)
if policy_comment_value is not False or policy_comment_error is not None:
    raise SystemExit(
        "valid root mapping comments were rejected by policy parser: "
        f"value={policy_comment_value!r}, error={policy_comment_error!r}"
    )

for expected, child_value in (
    (False, "false # comment"),
    (True, "true  # comment"),
    (False, "false #comment # trailing"),
):
    policy_value, policy_error = checker.parse_skill_invocation_policy(
        "policy:\n"
        f"  allow_implicit_invocation: {child_value}\n"
    )
    if policy_value is not expected or policy_error is not None:
        raise SystemExit(
            f"valid boolean comment was rejected: child={child_value!r}, "
            f"value={policy_value!r}, error={policy_error!r}"
        )

boolean_error = "allow_implicit_invocation must be boolean"
for name, child_value in {
    "no-space-comment": "false#comment",
    "nbsp-comment": "false\u00a0#comment",
    "quoted-boolean-comment": '"false" # comment',
    "quoted-hash-content": '"false # comment"',
    "tab-comment": "false\t# comment",
}.items():
    policy_value, policy_error = checker.parse_skill_invocation_policy(
        "policy:\n"
        f"  allow_implicit_invocation: {child_value}\n"
    )
    if policy_value is not None or policy_error is None or boolean_error not in policy_error:
        raise SystemExit(
            f"invalid boolean comment {name} was accepted: child={child_value!r}, "
            f"value={policy_value!r}, error={policy_error!r}"
        )

literal_yaml_control_error = checker.YAML_LITERAL_CONTROL_ERROR
for control in (
    "\x00",
    "\x01",
    "\x1f",
    "\x7f",
    "\x80",
    "\x84",
    "\x86",
    "\x9f",
    "\ufffe",
    "\uffff",
):
    policy_value, policy_error = checker.parse_skill_invocation_policy(
        "policy:\n"
        "  allow_implicit_invocation: false # comment"
        f"{control}\n"
    )
    if policy_value is not None or policy_error != literal_yaml_control_error:
        raise SystemExit(
            f"policy control U+{ord(control):04X} was accepted after comment stripping: "
            f"value={policy_value!r}, error={policy_error!r}"
        )
    interface_errors = checker.validate_skill_interface_metadata(
        "interface:\n"
        "  display_name: Fixture Governance\n"
        "  short_description: Create safe fixtures.\n"
        "  default_prompt: Use $fixture-governance. # comment"
        f"{control}\n",
        "fixture-governance",
    )
    if interface_errors != [literal_yaml_control_error]:
        raise SystemExit(
            f"interface control U+{ord(control):04X} was accepted in a comment: "
            f"errors={interface_errors!r}"
        )

nested_policy = (
    "policy:\n"
    "  allow_implicit_invocation: false\n"
    "    unexpected: value\n"
)
policy_value, policy_error = checker.parse_skill_invocation_policy(nested_policy)
if (
    policy_value is not None
    or policy_error is None
    or "policy descendants must be direct children" not in policy_error
):
    raise SystemExit(
        "over-indented policy descendant was accepted: "
        f"value={policy_value!r}, error={policy_error!r}"
    )

nested_interface = (
    "interface:\n"
    "  display_name: Fixture Governance\n"
    "    unexpected: value\n"
    "  short_description: Create deterministic fixtures.\n"
    "  default_prompt: Use $fixture-governance.\n"
)
interface_errors = checker.validate_skill_interface_metadata(
    nested_interface,
    "fixture-governance",
)
if (
    len(interface_errors) != 1
    or "interface descendants must be direct children" not in interface_errors[0]
):
    raise SystemExit(
        "over-indented interface descendant was accepted: "
        f"errors={interface_errors!r}"
    )

policy_parser_nested_interface = (
    "interface:\n"
    "  display_name: Fixture Governance\n"
    "    unexpected: value\n"
    "policy:\n"
    "  allow_implicit_invocation: false\n"
)
policy_value, policy_error = checker.parse_skill_invocation_policy(
    policy_parser_nested_interface
)
if (
    policy_value is not None
    or policy_error is None
    or "interface descendants must be direct children" not in policy_error
):
    raise SystemExit(
        "policy parser accepted an over-indented interface descendant: "
        f"value={policy_value!r}, error={policy_error!r}"
    )

interface_parser_nested_policy = (
    "policy:\n"
    "  allow_implicit_invocation: false\n"
    "    unexpected: value\n"
    "interface:\n"
    "  display_name: Fixture Governance\n"
    "  short_description: Create deterministic fixtures.\n"
    "  default_prompt: Use $fixture-governance.\n"
)
interface_errors = checker.validate_skill_interface_metadata(
    interface_parser_nested_policy,
    "fixture-governance",
)
if (
    len(interface_errors) != 1
    or "policy descendants must be direct children" not in interface_errors[0]
):
    raise SystemExit(
        "interface parser accepted an over-indented policy descendant: "
        f"errors={interface_errors!r}"
    )

nested_comment_policy = (
    "policy:\n"
    "  allow_implicit_invocation: false\n"
    "    # nested comments remain comments\n"
)
policy_value, policy_error = checker.parse_skill_invocation_policy(nested_comment_policy)
if policy_value is not False or policy_error is not None:
    raise SystemExit(
        "valid indented policy comment was rejected: "
        f"value={policy_value!r}, error={policy_error!r}"
    )

root_mapping_error = "root-level YAML nodes must be supported mappings"
for root_line in ("policy:\u00a0# comment", "interface:\u00a0# comment"):
    policy_value, policy_error = checker.parse_skill_invocation_policy(
        f"{root_line}\n  allow_implicit_invocation: false\n"
    )
    if policy_value is not None or policy_error is None or root_mapping_error not in policy_error:
        raise SystemExit(
            f"non-ASCII policy root comment separator was accepted: "
            f"line={root_line!r}, value={policy_value!r}, error={policy_error!r}"
        )
    interface_errors = checker.validate_skill_interface_metadata(
        f"{root_line}\n"
        "  display_name: Fixture Governance\n"
        "  short_description: Create deterministic fixtures.\n"
        "  default_prompt: Use $fixture-governance.\n",
        "fixture-governance",
    )
    if len(interface_errors) != 1 or root_mapping_error not in interface_errors[0]:
        raise SystemExit(
            f"non-ASCII interface root comment separator was accepted: "
            f"line={root_line!r}, errors={interface_errors!r}"
        )

unsupported_structure_separator_error = (
    "U+000B, U+000C, U+001C, U+001D, and U+001E are not supported "
    "as YAML line separators in openai.yaml"
)
for separator in ("\u000B", "\u000C", "\u001C", "\u001D", "\u001E"):
    policy_value, policy_error = checker.parse_skill_invocation_policy(
        "policy:"
        f"{separator}  allow_implicit_invocation: false\n"
    )
    if policy_value is not None or policy_error != unsupported_structure_separator_error:
        raise SystemExit(
            f"policy structure separator U+{ord(separator):04X} was accepted: "
            f"value={policy_value!r}, error={policy_error!r}"
        )
    interface_errors = checker.validate_skill_interface_metadata(
        "interface:"
        f"{separator}  display_name: Fixture Governance\n"
        "  short_description: Create deterministic fixtures.\n"
        "  default_prompt: Use $fixture-governance.\n",
        "fixture-governance",
    )
    if interface_errors != [unsupported_structure_separator_error]:
        raise SystemExit(
            f"interface structure separator U+{ord(separator):04X} was accepted: "
            f"errors={interface_errors!r}"
        )

for marker in ("---", "..."):
    for prefix in ("", "\ufeff"):
        for interface_with_marker in (
            f"{prefix}{marker}\ninterface:\n",
            "interface:\n"
            "  display_name: Fixture Governance\n"
            "  short_description: Create deterministic fixtures.\n"
            "  default_prompt: Use $fixture-governance.\n"
            f"{prefix}{marker}\n",
        ):
            interface_errors = checker.validate_skill_interface_metadata(
                interface_with_marker,
                "fixture-governance",
            )
            if len(interface_errors) != 1 or document_marker_error not in interface_errors[0]:
                raise SystemExit(
                    f"interface {prefix + marker!r} marker was accepted: "
                    f"errors={interface_errors!r}"
                )

root_scalars = (
    '"---"',
    "---#comment",
    "...foo",
    "\u00a0\"---\"",
    "\u00a0...foo",
    "\u00a0#comment",
)
for root_scalar in root_scalars:
    policy_text = (
        "policy:\n"
        "  allow_implicit_invocation: false\n"
        f"{root_scalar}\n"
    )
    policy_value, policy_error = checker.parse_skill_invocation_policy(policy_text)
    if policy_error is None or root_mapping_error not in policy_error:
        raise SystemExit(
            f"policy root scalar {root_scalar!r} was accepted: "
            f"value={policy_value!r}, error={policy_error!r}"
        )
    interface_text = (
        "interface:\n"
        "  display_name: Fixture Governance\n"
        "  short_description: Create deterministic fixtures.\n"
        "  default_prompt: Use $fixture-governance.\n"
        f"{root_scalar}\n"
    )
    interface_errors = checker.validate_skill_interface_metadata(
        interface_text,
        "fixture-governance",
    )
    if len(interface_errors) != 1 or root_mapping_error not in interface_errors[0]:
        raise SystemExit(
            f"interface root scalar {root_scalar!r} was accepted: "
            f"errors={interface_errors!r}"
        )

unsupported_root_error = "only interface, dependencies, and policy root mappings are supported"
for unknown_value in ("value", "[unclosed", '"unmatched', "{unclosed"):
    policy_with_unknown_root = (
        f"extra: {unknown_value}\n"
        "policy:\n"
        "  allow_implicit_invocation: false\n"
    )
    policy_value, policy_error = checker.parse_skill_invocation_policy(
        policy_with_unknown_root
    )
    if policy_value is not None or policy_error is None or unsupported_root_error not in policy_error:
        raise SystemExit(
            f"unknown policy root value {unknown_value!r} was accepted: "
            f"value={policy_value!r}, error={policy_error!r}"
        )

misplaced_interface = """\
interface:
other:
  display_name: "Fixture Governance"
  short_description: "Create deterministic fixtures."
  default_prompt: "Use $fixture-governance for fixtures."
policy:
  allow_implicit_invocation: true
"""
interface_errors = checker.validate_skill_interface_metadata(
    misplaced_interface,
    "fixture-governance",
)
if len(interface_errors) != 1 or unsupported_root_error not in interface_errors[0]:
    raise SystemExit(
        f"misplaced interface metadata was accepted: errors={interface_errors!r}"
    )

invalid_interface_scalars = {
    "empty-display-name": ("display_name", '""', "display_name is missing", False),
    "null-display-name": (
        "display_name",
        "null",
        "interface metadata must be a non-empty YAML string scalar",
        False,
    ),
    "empty-prompt-comment": (
        "default_prompt",
        '"" # $fixture-governance',
        "default_prompt is missing",
        False,
    ),
    "longer-skill-prefix": (
        "default_prompt",
        '"Use $fixture-governance-extra."',
        "default_prompt must mention $fixture-governance",
        False,
    ),
    "combining-mark-skill-suffix": (
        "default_prompt",
        '"Use $fixture-governance\u0301."',
        "default_prompt must mention $fixture-governance",
        False,
    ),
    "zero-width-joiner-skill-suffix": (
        "default_prompt",
        '"Use $fixture-governance\u200dfoo."',
        "default_prompt must mention $fixture-governance",
        False,
    ),
    "variation-selector-skill-suffix": (
        "default_prompt",
        '"Use $fixture-governance\ufe0f."',
        "default_prompt must mention $fixture-governance",
        False,
    ),
    "unmatched-quote": (
        "display_name",
        '"Fixture Governance',
        "unterminated double-quoted scalar",
        False,
    ),
    "surrogate-short-escape": (
        "display_name",
        r'"Fixture\uD800Governance"',
        "surrogate Unicode code points are not allowed in YAML scalars",
        False,
    ),
    "surrogate-long-escape": (
        "display_name",
        r'"Fixture\U0000D800Governance"',
        "surrogate Unicode code points are not allowed in YAML scalars",
        False,
    ),
    "literal-c0-control": (
        "display_name",
        '"Fixture ' + chr(1) + 'Governance"',
        "literal C0 and DEL control characters",
        False,
    ),
    "literal-del-control": (
        "display_name",
        '"Fixture ' + chr(127) + 'Governance"',
        "literal C0 and DEL control characters",
        False,
    ),
    "literal-single-c0-control": (
        "short_description",
        "'Create " + chr(1) + " fixtures.'",
        "literal C0 and DEL control characters",
        False,
    ),
    "literal-single-del-control": (
        "short_description",
        "'Create " + chr(127) + " fixtures.'",
        "literal C0 and DEL control characters",
        False,
    ),
    "literal-plain-c0-control": (
        "short_description",
        "Create" + chr(1) + " fixtures.",
        "literal C0 and DEL control characters",
        False,
    ),
    "literal-plain-del-control": (
        "short_description",
        "Create" + chr(127) + " fixtures.",
        "literal C0 and DEL control characters",
        False,
    ),
    "tab-separation": (
        "display_name",
        chr(9) + "Fixture Governance",
        "literal tabs are not supported in interface metadata",
        True,
    ),
    "quoted-trailing-tab": (
        "display_name",
        '"Fixture Governance"' + chr(9),
        "literal tabs are not supported in interface metadata",
        False,
    ),
    "plain-trailing-tab": (
        "short_description",
        "Create fixtures." + chr(9),
        "literal tabs are not supported in interface metadata",
        False,
    ),
    "plain-trailing-colon": (
        "display_name",
        "Fixture Governance:",
        "interface metadata must be a non-empty YAML string scalar",
        False,
    ),
    **{
        f"plain-{name}-indicator": (
            "display_name",
            value,
            "interface metadata must be a non-empty YAML string scalar",
            False,
        )
        for name, value in {
            "dash": "- value",
            "question": "? value",
            "colon": ": value",
            "comma": ",value",
            "at": "@value",
            "percent": "%value",
            "backtick": "`value`",
        }.items()
    },
    "missing-separation-space": (
        "display_name",
        "Fixture Governance",
        "must use YAML separation space",
        True,
    ),
}
for name, (field, value, expected_error, omit_space) in invalid_interface_scalars.items():
    fields = {
        "display_name": '"Fixture Governance"',
        "short_description": '"Create deterministic fixtures."',
        "default_prompt": '"Use $fixture-governance for fixtures."',
    }
    fields[field] = value
    text = "interface:\n" + "\n".join(
        f"  {key}:{'' if omit_space and key == field else ' '}{value}"
        for key, value in fields.items()
    ) + "\n"
    interface_errors = checker.validate_skill_interface_metadata(
        text,
        "fixture-governance",
    )
    if len(interface_errors) != 1 or expected_error not in interface_errors[0]:
        raise SystemExit(
            f"{name} did not report {expected_error!r}: errors={interface_errors!r}"
        )

valid_interface_scalars = {
    "double-quoted-escape": """\
interface:
  display_name: "Fixture \\u0047overnance"
  short_description: "Create deterministic fixtures."
  default_prompt: "Use $fixture-governance."
""",
    "single-quoted-doubled-apostrophe": """\
interface:
  display_name: Fixture Governance
  short_description: 'Create ''safe'' fixtures.'
  default_prompt: "Use $fixture-governance."
""",
    "inline-comment": """\
interface:
  display_name: Fixture Governance
  short_description: Create safe fixtures.
  default_prompt: Use $fixture-governance # trailing comment
""",
    "hash-without-space": """\
interface:
  display_name: Fixture#Governance
  short_description: Create safe# fixtures.
  default_prompt: Use $fixture-governance.
""",
    "root-mapping-comment": """\
interface: # interface mapping comment
  display_name: Fixture Governance
  short_description: Create safe fixtures.
  default_prompt: Use $fixture-governance.
policy: # policy mapping comment
""",
    "dependencies-tools": """\
interface:
  display_name: Fixture Governance
  short_description: Create safe fixtures.
  default_prompt: Use $fixture-governance.
dependencies:
  tools:
    - type: "mcp"
      value: "github"
      description: "GitHub MCP server"
      transport: "streamable_http"
      url: "https://api.githubcopilot.com/mcp/"
policy:
  allow_implicit_invocation: false
""",
    "indented-comment": """\
interface:
  display_name: Fixture Governance
    # nested comments remain comments
  short_description: Create safe fixtures.
  default_prompt: Use $fixture-governance.
""",
    "bom-prefix": "\ufeffinterface:\n"
    "  display_name: Fixture Governance\n"
    "  short_description: Create deterministic fixtures.\n"
    "  default_prompt: Use $fixture-governance.\n",
}
for name, text in valid_interface_scalars.items():
    interface_errors = checker.validate_skill_interface_metadata(
        text,
        "fixture-governance",
    )
    if interface_errors:
        raise SystemExit(f"{name} was rejected: errors={interface_errors!r}")

dependencies_policy_value, dependencies_policy_error = checker.parse_skill_invocation_policy(
    valid_interface_scalars["dependencies-tools"]
)
if dependencies_policy_value is not False or dependencies_policy_error is not None:
    raise SystemExit(
        "supported dependencies.tools declaration was rejected by policy parser: "
        f"value={dependencies_policy_value!r}, error={dependencies_policy_error!r}"
    )

figma_dependencies = valid_interface_scalars["dependencies-tools"].replace(
    'value: "github"',
    'value: "figma"',
)
figma_interface_errors = checker.validate_skill_interface_metadata(
    figma_dependencies,
    "fixture-governance",
)
if figma_interface_errors:
    raise SystemExit(
        "Figma-style dependencies.tools declaration was rejected by interface parser: "
        f"errors={figma_interface_errors!r}"
    )
figma_policy_value, figma_policy_error = checker.parse_skill_invocation_policy(
    figma_dependencies
)
if figma_policy_value is not False or figma_policy_error is not None:
    raise SystemExit(
        "Figma-style dependencies.tools declaration was rejected by policy parser: "
        f"value={figma_policy_value!r}, error={figma_policy_error!r}"
    )

empty_tools_dependencies = valid_interface_scalars["dependencies-tools"].replace(
    "  tools:\n"
    "    - type: \"mcp\"\n"
    "      value: \"github\"\n"
    "      description: \"GitHub MCP server\"\n"
    "      transport: \"streamable_http\"\n"
    "      url: \"https://api.githubcopilot.com/mcp/\"\n",
    "  tools: []\n",
)
empty_tools_interface_errors = checker.validate_skill_interface_metadata(
    empty_tools_dependencies,
    "fixture-governance",
)
if empty_tools_interface_errors:
    raise SystemExit(
        "empty dependencies.tools sequence was rejected by interface parser: "
        f"errors={empty_tools_interface_errors!r}"
    )
empty_tools_policy_value, empty_tools_policy_error = checker.parse_skill_invocation_policy(
    empty_tools_dependencies
)
if empty_tools_policy_value is not False or empty_tools_policy_error is not None:
    raise SystemExit(
        "empty dependencies.tools sequence was rejected by policy parser: "
        f"value={empty_tools_policy_value!r}, error={empty_tools_policy_error!r}"
    )

invalid_dependencies = {
    "shell-type": (
        valid_interface_scalars["dependencies-tools"].replace(
            'type: "mcp"',
            'type: "shell"',
        ),
        "dependency tool type must be 'mcp'",
    ),
    "command-field": (
        valid_interface_scalars["dependencies-tools"].replace(
            '      value: "github"\n',
            '      value: "github"\n      command: "npx"\n',
        ),
        checker.YAML_DEPENDENCY_ERROR,
    ),
    "unknown-field": (
        valid_interface_scalars["dependencies-tools"].replace(
            '      value: "github"\n',
            '      value: "github"\n      executable: "npx"\n',
        ),
        checker.YAML_DEPENDENCY_ERROR,
    ),
    "empty-value": (
        valid_interface_scalars["dependencies-tools"].replace(
            'value: "github"',
            'value: ""',
        ),
        "dependency tool field 'value' must be a non-empty string",
    ),
    "missing-value": (
        valid_interface_scalars["dependencies-tools"].replace(
            '      value: "github"\n',
            '',
        ),
        "dependency tool requires type and value",
    ),
    "flow-sequence": (
        empty_tools_dependencies.replace(
            "tools: []",
            'tools: [{type: "mcp", value: "figma"}]',
        ),
        checker.YAML_DEPENDENCY_ERROR,
    ),
}
for name, (text, expected_error) in invalid_dependencies.items():
    dependency_error = checker.validate_supported_dependencies(text)
    if dependency_error is None or expected_error not in dependency_error:
        raise SystemExit(
            f"invalid dependency fixture {name} was accepted: "
            f"error={dependency_error!r}"
        )
    interface_errors = checker.validate_skill_interface_metadata(
        text,
        "fixture-governance",
    )
    if len(interface_errors) != 1 or expected_error not in interface_errors[0]:
        raise SystemExit(
            f"interface parser accepted invalid dependency fixture {name}: "
            f"errors={interface_errors!r}"
        )
    policy_value, policy_error = checker.parse_skill_invocation_policy(text)
    if policy_value is not None or policy_error is None or expected_error not in policy_error:
        raise SystemExit(
            f"policy parser accepted invalid dependency fixture {name}: "
            f"value={policy_value!r}, error={policy_error!r}"
        )

with tempfile.TemporaryDirectory(dir=".") as temp_dir:
    mismatched_skill_path = pathlib.Path(temp_dir) / "SKILL.md"
    mismatched_skill_path.write_text(
        "---\n"
        "name: other-skill\n"
        "description: A valid temporary skill fixture.\n"
        "---\n"
    )
    frontmatter_errors = []
    checker.validate_skill_frontmatter_name(
        "fixture-governance",
        mismatched_skill_path,
        frontmatter_errors,
    )
    if len(frontmatter_errors) != 1 or "does not match inventory entry" not in frontmatter_errors[0]:
        raise SystemExit(
            "mismatched SKILL.md name was accepted: "
            f"errors={frontmatter_errors!r}"
        )

    malformed_frontmatter = {
        "nested-only-name": (
            "---\n"
            "metadata:\n"
            "  name: fixture-governance\n"
            "description: A valid temporary skill fixture.\n"
            "---\n",
            "frontmatter name is missing",
        ),
        "unsupported-metadata-child": (
            "---\n"
            "name: fixture-governance\n"
            "description: A valid temporary skill fixture.\n"
            "metadata:\n"
            "  name: fixture-governance\n"
            "---\n",
            "unsupported metadata field 'name'",
        ),
        "duplicate-metadata-child": (
            "---\n"
            "name: fixture-governance\n"
            "description: A valid temporary skill fixture.\n"
            "metadata:\n"
            "  short-description: first\n"
            "  short-description: second\n"
            "---\n",
            "duplicate metadata field 'short-description'",
        ),
        "missing-metadata-short-description": (
            "---\n"
            "name: fixture-governance\n"
            "description: A valid temporary skill fixture.\n"
            "metadata:\n"
            "  short-description:\n"
            "---\n",
            "metadata field 'short-description' must be a non-empty string",
        ),
        "null-metadata-short-description": (
            "---\n"
            "name: fixture-governance\n"
            "description: A valid temporary skill fixture.\n"
            "metadata:\n"
            "  short-description: null\n"
            "---\n",
            "metadata field 'short-description' must be a non-empty string",
        ),
        "quoted-empty-metadata-short-description": (
            "---\n"
            "name: fixture-governance\n"
            "description: A valid temporary skill fixture.\n"
            "metadata:\n"
            "  short-description: \"\"\n"
            "---\n",
            "metadata field 'short-description' must be a non-empty string",
        ),
        "quoted-whitespace-metadata-short-description": (
            "---\n"
            "name: fixture-governance\n"
            "description: A valid temporary skill fixture.\n"
            "metadata:\n"
            "  short-description: \"   \"\n"
            "---\n",
            "metadata field 'short-description' must be a non-empty string",
        ),
        "flow-metadata-child": (
            "---\n"
            "name: fixture-governance\n"
            "description: A valid temporary skill fixture.\n"
            "metadata: {}\n"
            "  short-description: child\n"
            "---\n",
            "metadata flow mapping cannot contain indented children",
        ),
        "leading-tab": (
            "---\n"
            "\tname: fixture-governance\n"
            "description: A valid temporary skill fixture.\n"
            "---\n",
            "frontmatter indentation must use ASCII spaces",
        ),
        "leading-nbsp": (
            "---\n"
            + chr(0xA0)
            + "name: fixture-governance\n"
            + "description: A valid temporary skill fixture.\n"
            + "---\n",
            "frontmatter indentation must use ASCII spaces",
        ),
        "leading-unicode-space": (
            "---\n"
            + chr(0x2003)
            + "name: fixture-governance\n"
            + "description: A valid temporary skill fixture.\n"
            + "---\n",
            "frontmatter indentation must use ASCII spaces",
        ),
        "duplicate-root-name": (
            "---\n"
            "name: fixture-governance\n"
            "name: fixture-governance\n"
            "---\n",
            "expected exactly one root frontmatter name",
        ),
        "duplicate-invocation-control": (
            "---\n"
            "name: fixture-governance\n"
            "disable-model-invocation: false\n"
            "disable-model-invocation: true\n"
            "---\n",
            "duplicate root frontmatter field 'disable-model-invocation'",
        ),
        "quoted-invocation-control": (
            "---\n"
            "name: fixture-governance\n"
            'disable-model-invocation: "true"\n'
            "---\n",
            "disable-model-invocation must be boolean",
        ),
        "quoted-duplicate-root-name": (
            "---\n"
            '"name": other-skill\n'
            "name: fixture-governance\n"
            "---\n",
            "invalid root frontmatter field",
        ),
        "unterminated-collection": (
            "---\n"
            "name: fixture-governance\n"
            "description: [unterminated\n"
            "---\n",
            "frontmatter must be a non-empty YAML string scalar",
        ),
        "control-in-comment": (
            "---\n"
            "name: fixture-governance\n"
            "# first\u000b# second\n"
            "---\n",
            "frontmatter contains an unsupported control or line separator",
        ),
        "c1-control-in-comment": (
            "---\n"
            "name: fixture-governance\n"
            "# first" + chr(0x80) + "# second\n"
            "---\n",
            "frontmatter contains an unsupported control or line separator",
        ),
        "yaml-noncharacter-in-comment": (
            "---\n"
            "name: fixture-governance\n"
            "# first" + chr(0xFFFE) + "# second\n"
            "---\n",
            "frontmatter contains an unsupported control or line separator",
        ),
        "carriage-return-in-comment": (
            "---\n"
            "name: fixture-governance\n"
            "# first\rname: other-skill\n"
            "---\n",
            "frontmatter contains an unsupported control or line separator",
        ),
        "unterminated": (
            "---\n"
            "name: fixture-governance\n",
            "unterminated frontmatter",
        ),
    }
    for name, (text, expected_error) in malformed_frontmatter.items():
        malformed_skill_path = pathlib.Path(temp_dir) / f"{name}.md"
        malformed_skill_path.write_text(text)
        frontmatter_errors = []
        checker.validate_skill_frontmatter_name(
            "fixture-governance",
            malformed_skill_path,
            frontmatter_errors,
        )
        if not any(expected_error in error for error in frontmatter_errors):
            raise SystemExit(
                f"{name} SKILL.md frontmatter was accepted: "
                f"errors={frontmatter_errors!r}"
            )

    for space_name, space in (
        ("ascii-space", " "),
        ("nbsp", "\u00a0"),
        ("em-space", "\u2003"),
    ):
        root_key_path = pathlib.Path(temp_dir) / f"root-key-{space_name}.md"
        root_key_path.write_text(
            "---\n"
            f"name{space}: fixture-governance\n"
            "description: A valid temporary skill fixture.\n"
            "---\n"
        )
        frontmatter_errors = []
        checker.validate_skill_frontmatter_name(
            "fixture-governance",
            root_key_path,
            frontmatter_errors,
        )
        if not any("invalid root frontmatter field" in error for error in frontmatter_errors):
            raise SystemExit(
                f"root key with {space_name} before ':' was accepted: "
                f"errors={frontmatter_errors!r}"
            )

        metadata_key_path = pathlib.Path(temp_dir) / f"metadata-key-{space_name}.md"
        metadata_key_path.write_text(
            "---\n"
            "name: fixture-governance\n"
            "description: A valid temporary skill fixture.\n"
            "metadata:\n"
            f"  short-description{space}: Fixture metadata\n"
            "---\n"
        )
        frontmatter_errors = []
        checker.validate_skill_frontmatter_name(
            "fixture-governance",
            metadata_key_path,
            frontmatter_errors,
        )
        if not any("invalid metadata field" in error for error in frontmatter_errors):
            raise SystemExit(
                f"metadata key with {space_name} before ':' was accepted: "
                f"errors={frontmatter_errors!r}"
            )

        for dependency_field in ("type", "value"):
            dependency_text = valid_interface_scalars["dependencies-tools"].replace(
                f"{dependency_field}: ",
                f"{dependency_field}{space}: ",
                1,
            )
            dependency_error = checker.validate_supported_dependencies(dependency_text)
            if dependency_error is None or checker.YAML_DEPENDENCY_ERROR not in dependency_error:
                raise SystemExit(
                    f"dependency {dependency_field} key with {space_name} before ':' "
                    f"was accepted: error={dependency_error!r}"
                )

    nested_metadata_skill_path = pathlib.Path(temp_dir) / "nested-metadata.md"
    nested_metadata_skill_path.write_text(
        "---\n"
        "name: fixture-governance\n"
        "description: A valid temporary skill fixture.\n"
        "metadata:\n"
        "  short-description: Fixture metadata\n"
        "---\n"
    )
    frontmatter_errors = []
    checker.validate_skill_frontmatter_name(
        "fixture-governance",
        nested_metadata_skill_path,
        frontmatter_errors,
    )
    if frontmatter_errors:
        raise SystemExit(
            "supported nested SKILL.md metadata was rejected: "
            f"errors={frontmatter_errors!r}"
        )

    empty_flow_metadata_skill_path = pathlib.Path(temp_dir) / "empty-flow-metadata.md"
    empty_flow_metadata_skill_path.write_text(
        "---\n"
        "name: fixture-governance\n"
        "description: A valid temporary skill fixture.\n"
        "metadata: {}\n"
        "---\n"
    )
    frontmatter_errors = []
    checker.validate_skill_frontmatter_name(
        "fixture-governance",
        empty_flow_metadata_skill_path,
        frontmatter_errors,
    )
    if frontmatter_errors:
        raise SystemExit(
            "empty flow-map SKILL.md metadata was rejected: "
            f"errors={frontmatter_errors!r}"
        )

    empty_block_metadata_skill_path = pathlib.Path(temp_dir) / "empty-block-metadata.md"
    empty_block_metadata_skill_path.write_text(
        "---\n"
        "name: fixture-governance\n"
        "description: A valid temporary skill fixture.\n"
        "metadata:\n"
        "---\n"
    )
    frontmatter_errors = []
    checker.validate_skill_frontmatter_name(
        "fixture-governance",
        empty_block_metadata_skill_path,
        frontmatter_errors,
    )
    if frontmatter_errors:
        raise SystemExit(
            "empty block SKILL.md metadata was rejected: "
            f"errors={frontmatter_errors!r}"
        )

    nested_name_metadata_skill_path = pathlib.Path(temp_dir) / "nested-name-metadata.md"
    nested_name_metadata_skill_path.write_text(
        "---\n"
        "metadata:\n"
        "  name: fixture-governance\n"
        "description: A valid temporary skill fixture.\n"
        "---\n"
    )
    frontmatter_errors = []
    checker.validate_skill_frontmatter_name(
        "fixture-governance",
        nested_name_metadata_skill_path,
        frontmatter_errors,
    )
    if not any("unsupported metadata field 'name'" in error for error in frontmatter_errors) or not any(
        "frontmatter name is missing" in error for error in frontmatter_errors
    ):
        raise SystemExit(
            "nested metadata name incorrectly satisfied root skill identity: "
            f"errors={frontmatter_errors!r}"
        )

nbspace_value = "Fixture" + chr(0xA0) + "#Governance"
parsed, parse_error = checker.parse_yaml_string_scalar(nbspace_value, 1)
if parse_error is not None or parsed != nbspace_value:
    raise SystemExit(
        f"NBSP before # was not preserved: parsed={parsed!r}, error={parse_error!r}"
    )
nbspace_interface = (
    "interface:\n"
    f"  display_name: {nbspace_value}\n"
    "  short_description: Create safe fixtures.\n"
    "  default_prompt: Use $fixture-governance.\n"
)
interface_errors = checker.validate_skill_interface_metadata(
    nbspace_interface,
    "fixture-governance",
)
if interface_errors:
    raise SystemExit(f"NBSP interface value was rejected: errors={interface_errors!r}")

for unknown_value in ("value", "[unclosed", '"unmatched', "{unclosed"):
    interface_with_unknown_root = (
        f"extra: {unknown_value}\n"
        "interface:\n"
        "  display_name: Fixture Governance\n"
        "  short_description: Create deterministic fixtures.\n"
        "  default_prompt: Use $fixture-governance.\n"
    )
    interface_errors = checker.validate_skill_interface_metadata(
        interface_with_unknown_root,
        "fixture-governance",
    )
    if len(interface_errors) != 1 or unsupported_root_error not in interface_errors[0]:
        raise SystemExit(
            f"unknown interface root value {unknown_value!r} was accepted: "
            f"errors={interface_errors!r}"
        )

unsupported_line_separator_error = (
    "U+0085, U+2028, and U+2029 are not supported in openai.yaml"
)
for separator in ("\u0085", "\u2028", "\u2029"):
    policy_value, policy_error = checker.parse_skill_invocation_policy(
        "policy:\n"
        "  allow_implicit_invocation: false"
        f"{separator}\n"
    )
    if policy_value is not None or policy_error != unsupported_line_separator_error:
        raise SystemExit(
            f"policy line separator U+{ord(separator):04X} was not rejected: "
            f"value={policy_value!r}, error={policy_error!r}"
        )
    interface_errors = checker.validate_skill_interface_metadata(
        "interface:\n"
        f"  display_name: Fixture{separator}Governance\n"
        "  short_description: Create deterministic fixtures.\n"
        "  default_prompt: Use $fixture-governance.\n",
        "fixture-governance",
    )
    if interface_errors != [unsupported_line_separator_error]:
        raise SystemExit(
            f"interface line separator U+{ord(separator):04X} was not rejected: "
            f"errors={interface_errors!r}"
        )

for scalar in (
    r'"Fixture\u2028Governance"',
    r'"Fixture\u2029Governance"',
    r'"Fixture\x85Governance"',
):
    parsed, parse_error = checker.parse_yaml_string_scalar(scalar, 1)
    expected_scalar_error = f"line 1: {unsupported_line_separator_error}"
    if parsed is not None or parse_error != expected_scalar_error:
        raise SystemExit(
            f"escaped line separator {scalar!r} was not rejected: "
            f"parsed={parsed!r}, error={parse_error!r}"
        )

for separator in ("\u000B", "\u000C", "\u001C", "\u001D", "\u001E"):
    parsed, parse_error = checker.parse_yaml_string_scalar(
        f"Fixture{separator}Governance",
        1,
    )
    if (
        parsed is not None
        or parse_error is None
        or checker.LITERAL_SCALAR_CONTROL_ERROR not in parse_error
        or unsupported_structure_separator_error in parse_error
    ):
        raise SystemExit(
            f"literal scalar separator U+{ord(separator):04X} used the wrong contract: "
            f"parsed={parsed!r}, error={parse_error!r}"
        )

escaped_structure_separator = r'"Fixture\u000bGovernance"'
parsed, parse_error = checker.parse_yaml_string_scalar(escaped_structure_separator, 1)
if parse_error is not None or parsed != "Fixture\u000bGovernance":
    raise SystemExit(
        "escaped structure separator was not decoded as a scalar escape: "
        f"parsed={parsed!r}, error={parse_error!r}"
    )

escaped_control = '"Fixture ' + chr(92) + "u0001Governance\""
parsed, parse_error = checker.parse_yaml_string_scalar(escaped_control, 1)
if parse_error is not None or parsed != "Fixture \x01Governance":
    raise SystemExit(
        f"escaped control was not decoded: parsed={parsed!r}, error={parse_error!r}"
    )

escaped_del_control = '"Fixture ' + chr(92) + "u007fGovernance\""
parsed, parse_error = checker.parse_yaml_string_scalar(escaped_del_control, 1)
if parse_error is not None or parsed != "Fixture \x7fGovernance":
    raise SystemExit(
        f"escaped DEL control was not decoded: parsed={parsed!r}, error={parse_error!r}"
    )

literal_escape = chr(92) + "u0001"
for name, scalar in {
    "single-quoted-literal-escape": "'" + literal_escape + "'",
    "plain-literal-escape": literal_escape,
}.items():
    parsed, parse_error = checker.parse_yaml_string_scalar(scalar, 1)
    if parse_error is not None or parsed != literal_escape:
        raise SystemExit(
            f"{name} was decoded outside double quotes: "
            f"parsed={parsed!r}, error={parse_error!r}"
        )

skill_name = "fixture-governance"
token = f"${skill_name}"
token_boundary_cases = {
    "at-end": (token, True),
    "space": (token + " next", True),
    "nbsp": (token + "\u00a0next", True),
    "period": (token + ".", True),
    "comma": (token + ",", True),
    "exclamation": (token + "!", True),
    "question": (token + "?", True),
    "colon": (token + ":", True),
    "hash": (token + "#note", True),
    "ascii-name-continuation": (token + "extra", False),
    "ascii-hyphen-continuation": (token + "-extra", False),
    "leading-ascii-name-continuation": ("x" + token, False),
    "unicode-letter-continuation": (token + "é", False),
    "unicode-number-continuation": (token + "²", False),
    "combining-mark": (token + "\u0301", False),
    "zero-width-joiner": (token + "\u200dfoo", False),
    "variation-selector": (token + "\ufe0f", False),
    "format-character": (token + "\u2060", False),
}
for name, (prompt, expected) in token_boundary_cases.items():
    actual = checker.has_complete_skill_token(prompt, skill_name)
    if actual != expected:
        raise SystemExit(
            f"token boundary {name} disagreed: prompt={prompt!r}, "
            f"expected={expected!r}, actual={actual!r}"
        )
PY
}

if [ "${RPM_VALIDATE_AGENT_WORKFLOW_ASSETS_REGRESSION:-}" = "1" ]; then
  check_summary_formatter() {
    local output
    local expected
    expected=$'agent_assets.summary_failure=fail\nagent_assets.summary_failure.output.begin\nsummary failure diagnostics\nagent_assets.summary_failure.output.end'
    output="$(
      emit_check "summary_skip" "skip" "skipped checks stay hidden"
      emit_check "summary_failure" "fail" "summary failure diagnostics"
    )"
    if [ "${output}" != "${expected}" ]; then
      printf 'summary formatter output mismatch\nexpected:\n%s\nactual:\n%s\n' \
        "${expected}" "${output}" >&2
      return 1
    fi
  }

  check "summary_formatter" check_summary_formatter
  check "skill_policy_structure_negative" check_skill_policy_structure_negative
  printf 'agent_assets.status=%s\n' "${status}"
  [ "${status}" = "ok" ] || exit 1
  exit 0
fi

with_fake_collect_gh() {
  local fixture="$1"
  shift
  local temp_dir
  temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/rpm-collect-gh.XXXXXX")"
  trap 'rm -rf "${temp_dir}"' RETURN
  cat >"${temp_dir}/gh" <<'GH'
#!/usr/bin/env bash
set -euo pipefail

if [ "${1:-}" = "repo" ] && [ "${2:-}" = "view" ]; then
  printf 'owner/repo\n'
  exit 0
fi

if [ "${1:-}" = "api" ] && [ "${2:-}" = "graphql" ]; then
  count_file="${RPM_COLLECT_FIXTURE}/.count"
  count=0
  if [ -f "${count_file}" ]; then
    count="$(cat "${count_file}")"
  fi
  count=$((count + 1))
  printf '%s\n' "${count}" >"${count_file}"
  if [ -f "${RPM_COLLECT_FIXTURE}/page-${count}.json" ]; then
    cat "${RPM_COLLECT_FIXTURE}/page-${count}.json"
    exit 0
  fi
  cat "${RPM_COLLECT_FIXTURE}/page-last.json"
  exit 0
fi

printf 'unexpected gh call: %s\n' "$*" >&2
exit 99
GH
  chmod +x "${temp_dir}/gh"
  PATH="${temp_dir}:${PATH}" RPM_COLLECT_FIXTURE="${fixture}" "$@"
}

check_collect_paginates_comments_and_reviews() {
  local fixture_dir
  fixture_dir="$(mktemp -d "${TMPDIR:-/tmp}/rpm-collect-paginated.XXXXXX")"
  trap 'rm -rf "${fixture_dir}"' RETURN

  jq -n '
    {
      data: {
        repository: {
          pullRequest: {
            number: 1,
            title: "Fixture PR",
            url: "https://example.test/pr/1",
            state: "OPEN",
            isDraft: false,
            comments: {
              pageInfo: {hasNextPage: true, endCursor: "comment-100"},
              nodes: [
                range(0; 100) as $i |
                {
                  author: {login: "octocat"},
                  createdAt: "2025-12-31T23:59:59Z",
                  body: ("old comment " + ($i | tostring)),
                  url: ("https://example.test/comment/" + ($i | tostring))
                }
              ]
            },
            reviews: {
              pageInfo: {hasNextPage: true, endCursor: "review-100"},
              nodes: [
                range(0; 100) as $i |
                {
                  author: {login: "octocat"},
                  submittedAt: "2025-12-31T23:59:59Z",
                  state: "COMMENTED",
                  body: ("old review " + ($i | tostring)),
                  url: ("https://example.test/review/" + ($i | tostring))
                }
              ]
            },
            reviewThreads: {
              pageInfo: {hasNextPage: false, endCursor: null},
              nodes: []
            }
          }
        }
      }
    }
  ' >"${fixture_dir}/page-1.json"

  jq -n '
    {
      data: {
        repository: {
          pullRequest: {
            number: 1,
            title: "Fixture PR",
            url: "https://example.test/pr/1",
            state: "OPEN",
            isDraft: false,
            comments: {
              pageInfo: {hasNextPage: false, endCursor: "comment-101"},
              nodes: [
                {
                  author: {login: "chatgpt-codex-connector"},
                  createdAt: "2026-01-01T00:00:01Z",
                  body: "latest issue comment",
                  url: "https://example.test/comment/latest"
                }
              ]
            },
            reviews: {
              pageInfo: {hasNextPage: false, endCursor: "review-101"},
              nodes: [
                {
                  author: {login: "chatgpt-codex-connector"},
                  submittedAt: "2026-01-01T00:00:02Z",
                  state: "COMMENTED",
                  body: "latest review",
                  url: "https://example.test/review/latest"
                }
              ]
            },
            reviewThreads: {
              pageInfo: {hasNextPage: false, endCursor: null},
              nodes: []
            }
          }
        }
      }
    }
  ' >"${fixture_dir}/page-2.json"
  cp "${fixture_dir}/page-2.json" "${fixture_dir}/page-last.json"

  local output
  output="$(
    with_fake_collect_gh \
      "${fixture_dir}" \
      bash scripts/collect-pr-review-context.sh 1 --format json 2>&1
  )"
  printf '%s\n' "${output}" | jq -e '
    (.issueComments | length) == 101
    and (.reviews | length) == 101
    and any(.issueComments[]; .body == "latest issue comment")
    and any(.reviews[]; .body == "latest review")
  ' >/dev/null
}

check_collect_does_not_duplicate_exhausted_connections() {
  local fixture_dir
  fixture_dir="$(mktemp -d "${TMPDIR:-/tmp}/rpm-collect-asymmetric.XXXXXX")"
  trap 'rm -rf "${fixture_dir}"' RETURN

  jq -n '
    {
      data: {
        repository: {
          pullRequest: {
            number: 1,
            title: "Fixture PR",
            url: "https://example.test/pr/1",
            state: "OPEN",
            isDraft: false,
            comments: {
              pageInfo: {hasNextPage: false, endCursor: "comment-only"},
              nodes: [
                {
                  author: {login: "octocat"},
                  createdAt: "2026-01-01T00:00:01Z",
                  body: "single issue comment",
                  url: "https://example.test/comment/only"
                }
              ]
            },
            reviews: {
              pageInfo: {hasNextPage: true, endCursor: "review-1"},
              nodes: [
                {
                  author: {login: "octocat"},
                  submittedAt: "2026-01-01T00:00:02Z",
                  state: "COMMENTED",
                  body: "review page 1",
                  url: "https://example.test/review/1"
                }
              ]
            },
            reviewThreads: {
              pageInfo: {hasNextPage: false, endCursor: null},
              nodes: []
            }
          }
        }
      }
    }
  ' >"${fixture_dir}/page-1.json"

  jq -n '
    {
      data: {
        repository: {
          pullRequest: {
            number: 1,
            title: "Fixture PR",
            url: "https://example.test/pr/1",
            state: "OPEN",
            isDraft: false,
            comments: {
              pageInfo: {hasNextPage: false, endCursor: null},
              nodes: [
                {
                  author: {login: "octocat"},
                  createdAt: "2026-01-01T00:00:01Z",
                  body: "single issue comment",
                  url: "https://example.test/comment/only"
                }
              ]
            },
            reviews: {
              pageInfo: {hasNextPage: true, endCursor: "review-2"},
              nodes: [
                {
                  author: {login: "octocat"},
                  submittedAt: "2026-01-01T00:00:03Z",
                  state: "COMMENTED",
                  body: "review page 2",
                  url: "https://example.test/review/2"
                }
              ]
            },
            reviewThreads: {
              pageInfo: {hasNextPage: false, endCursor: null},
              nodes: []
            }
          }
        }
      }
    }
  ' >"${fixture_dir}/page-2.json"

  jq -n '
    {
      data: {
        repository: {
          pullRequest: {
            number: 1,
            title: "Fixture PR",
            url: "https://example.test/pr/1",
            state: "OPEN",
            isDraft: false,
            comments: {
              pageInfo: {hasNextPage: false, endCursor: null},
              nodes: [
                {
                  author: {login: "octocat"},
                  createdAt: "2026-01-01T00:00:01Z",
                  body: "single issue comment",
                  url: "https://example.test/comment/only"
                }
              ]
            },
            reviews: {
              pageInfo: {hasNextPage: false, endCursor: "review-3"},
              nodes: [
                {
                  author: {login: "octocat"},
                  submittedAt: "2026-01-01T00:00:04Z",
                  state: "COMMENTED",
                  body: "review page 3",
                  url: "https://example.test/review/3"
                }
              ]
            },
            reviewThreads: {
              pageInfo: {hasNextPage: false, endCursor: null},
              nodes: []
            }
          }
        }
      }
    }
  ' >"${fixture_dir}/page-3.json"
  cp "${fixture_dir}/page-3.json" "${fixture_dir}/page-last.json"

  local output
  output="$(
    with_fake_collect_gh \
      "${fixture_dir}" \
      bash scripts/collect-pr-review-context.sh 1 --format json 2>&1
  )"
  printf '%s\n' "${output}" | jq -e '
    ([.issueComments[] | select(.body == "single issue comment")] | length) == 1
    and (.issueComments | length) == 1
    and (.reviews | length) == 3
    and ([.reviews[].body] == ["review page 1", "review page 2", "review page 3"])
  ' >/dev/null
}

check_readiness_ready() {
  local output
  output="$(
    python3 scripts/check-agent-issue-readiness.py \
      --body-file .agents/fixtures/backlog/readiness-ready.md \
      --format jsonl
  )"
  printf '%s\n' "${output}" | jq -e '
    .type == "issue_readiness_result"
    and .data.status == "ready"
    and .data.ready == true
    and (.data.missing_sections | length) == 0
    and (.data.unresolved_decisions | length) == 0
    and .data.execution_error == null
    and .data.execution_metadata.executor == "cloud"
  ' >/dev/null
}

check_readiness_missing_execution() {
  local output
  local exit_code
  set +e
  output="$(
    python3 scripts/check-agent-issue-readiness.py \
      --body-file .agents/fixtures/backlog/readiness-missing-execution.md \
      --format jsonl
  )"
  exit_code=$?
  set -e
  [ "${exit_code}" -eq 1 ] || {
    printf 'expected readiness exit 1, got %s\n%s\n' "${exit_code}" "${output}"
    return 1
  }
  printf '%s\n' "${output}" | jq -e '
    .data.ready == false
    and .data.execution_error == "missing-execution-metadata"
  ' >/dev/null
}

check_readiness_missing() {
  local output
  local exit_code
  set +e
  output="$(
    python3 scripts/check-agent-issue-readiness.py \
      --body-file .agents/fixtures/backlog/readiness-missing.md \
      --format json
  )"
  exit_code=$?
  set -e
  [ "${exit_code}" -eq 1 ] || {
    printf 'expected readiness exit 1, got %s\n%s\n' "${exit_code}" "${output}"
    return 1
  }
  printf '%s\n' "${output}" | jq -e '
    .data.status == "needs-refinement"
    and .data.ready == false
    and (.data.missing_sections | index("Contract")) != null
    and (.data.missing_sections | index("Done criteria")) != null
  ' >/dev/null
}

check_readiness_unresolved() {
  local output
  local exit_code
  set +e
  output="$(
    python3 scripts/check-agent-issue-readiness.py \
      --body-file .agents/fixtures/backlog/readiness-unresolved.md \
      --format jsonl
  )"
  exit_code=$?
  set -e
  [ "${exit_code}" -eq 1 ] || {
    printf 'expected readiness exit 1, got %s\n%s\n' "${exit_code}" "${output}"
    return 1
  }
  printf '%s\n' "${output}" | jq -e '
    .data.ready == false
    and any(.data.unresolved_decisions[]; .reason == "contract-tbd")
    and any(.data.unresolved_decisions[]; .reason == "unchecked-decision")
  ' >/dev/null
}

check_readiness_live_issue() {
  local temp_dir
  local output
  temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/rpm-readiness-gh.XXXXXX")"
  trap 'rm -rf "${temp_dir}"' RETURN
  cp .agents/fixtures/backlog/fake-gh "${temp_dir}/gh"
  chmod +x "${temp_dir}/gh"
  output="$(
    PATH="${temp_dir}:${PATH}" \
      RPM_READINESS_FIXTURE=".agents/fixtures/backlog/live-issue.json" \
      python3 scripts/check-agent-issue-readiness.py --issue 3 --format jsonl
  )"
  printf '%s\n' "${output}" | jq -e '
    .data.status == "ready"
    and .data.source.kind == "live-issue"
    and .data.source.number == 3
    and .data.source.labels == ["agent:research"]
  ' >/dev/null
}

with_fake_backlog_gh() {
  local state_arg="$1"
  local temp_dir
  temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/rpm-backlog-gh.XXXXXX")"
  trap 'rm -rf "${temp_dir}"' RETURN
  cp .agents/fixtures/backlog/fake-gh "${temp_dir}/gh"
  chmod +x "${temp_dir}/gh"
  PATH="${temp_dir}:${PATH}" \
    RPM_BACKLOG_FIXTURE=".agents/fixtures/backlog/project-items.json" \
    bash scripts/backlog-gen --state "${state_arg}" --format jsonl
}

check_backlog_research_batch() {
  local output
  output="$(with_fake_backlog_gh research)"
  printf '%s\n' "${output}" | jq -e '
    .type == "backlog_selection"
    and .data.status == "selected"
    and .data.project.number == 7
    and .data.batch_limit == 1
    and .data.count == 1
    and [.data.issues[].number] == [3]
  ' >/dev/null
}

check_backlog_no_work() {
  local output
  output="$(with_fake_backlog_gh blocked)"
  printf '%s\n' "${output}" | jq -e '
    .data.status == "no-work"
    and .data.count == 0
    and .data.issues == []
  ' >/dev/null
}

check_backlog_inventory_order() {
  local output
  output="$(with_fake_backlog_gh all)"
  printf '%s\n' "${output}" | jq -e '
    .data.status == "selected"
    and [.data.issues[].number] == [3, 7, 9]
    and [.data.issues[].state] == ["research", "research", "ready"]
  ' >/dev/null
}

check_backlog_access_preflight() {
  local temp_dir
  local output
  temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/rpm-backlog-access-gh.XXXXXX")"
  trap 'rm -rf "${temp_dir}"' RETURN
  cp .agents/fixtures/backlog/fake-gh "${temp_dir}/gh"
  chmod +x "${temp_dir}/gh"
  output="$(
    PATH="${temp_dir}:${PATH}" \
      RPM_BACKLOG_FIXTURE=".agents/fixtures/backlog/project-items.json" \
      bash scripts/check-agent-backlog-access.sh --format jsonl
  )"
  printf '%s\n' "${output}" | jq -s -e '
    length == 5
    and ([.[] | select(.type == "backlog_access_check" and .data.status == "ok")] | length) == 4
    and .[-1].type == "backlog_access_result"
    and .[-1].data.status == "ok"
    and .[-1].data.repository == "nerdchanii/rpm"
    and .[-1].data.project == 7
  ' >/dev/null
}

check_summary_suppresses_skips() {
  local temp_home
  local output
  temp_home="$(mktemp -d "${TMPDIR:-/tmp}/rpm-agent-assets-no-validator-home.XXXXXX")"
  trap 'rm -rf "${temp_home}"' RETURN
  output="$(
    HOME="${temp_home}" \
      RPM_SKILL_VALIDATOR= \
      RPM_VALIDATE_AGENT_WORKFLOW_ASSETS_REGRESSION=1 \
      bash scripts/validate-agent-workflow-assets.sh --format=summary
  )"
  [ "${output}" = "agent_assets.status=ok" ]
}

check_just_test_verbosity() {
  local temp_dir
  local output
  temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/rpm-just-test-verbosity.XXXXXX")"
  trap 'rm -f "${temp_dir}/cargo"; rmdir "${temp_dir}"' RETURN
  ln -s /bin/echo "${temp_dir}/cargo"

  output="$(PATH="${temp_dir}:${PATH}" just --justfile justfile test -v)"
  printf '%s\n' "${output}" | rg -q '^test --locked --lib --bins --tests -v$' || return 1

  output="$(PATH="${temp_dir}:${PATH}" just --justfile justfile test -vv)"
  printf '%s\n' "${output}" | rg -q '^test --locked --lib --bins --tests -vv$' || return 1

  output="$(PATH="${temp_dir}:${PATH}" just --justfile justfile test -vvv)"
  printf '%s\n' "${output}" | rg -q '^test --locked --lib --bins --tests -vvv$' || return 1

  output="$(PATH="${temp_dir}:${PATH}" just --justfile justfile test --verbose)"
  printf '%s\n' "${output}" | rg -q '^test --locked --lib --bins --tests --verbose$' || return 1

  output="$(PATH="${temp_dir}:${PATH}" just --justfile justfile test package_filter --nocapture)"
  printf '%s\n' "${output}" | rg -q '^test --quiet --locked --lib --bins --tests package_filter --nocapture$' || return 1

  output="$(PATH="${temp_dir}:${PATH}" just --justfile justfile test -q)"
  printf '%s\n' "${output}" | rg -q '^test --locked --lib --bins --tests -q$' || return 1

  output="$(PATH="${temp_dir}:${PATH}" just --justfile justfile test --quiet)"
  printf '%s\n' "${output}" | rg -q '^test --locked --lib --bins --tests --quiet$' || return 1
}

for skill in .agents/skills/*; do
  [ -d "${skill}" ] || continue
  name="$(basename "${skill}")"
  if [ "${name}" = "take-ticket" ] || [ "${name}" = "prepare-backlog" ] || [ "${name}" = "merge-gatekeeper" ]; then
    emit_check \
      "skill_${name}" \
      "ok" \
      "hidden entry flags and routing are validated by check-agent-organization.py"
  elif [ -n "${skill_validator}" ]; then
    check "skill_${name}" python3 "${skill_validator}" "${skill}"
  else
    emit_check \
      "skill_${name}" \
      "skip" \
      "skill validator not found; set RPM_SKILL_VALIDATOR to enable this check"
  fi
done

if [ -d .codex/agents ]; then
  for agent in .codex/agents/*.toml; do
    [ -f "${agent}" ] || continue
    name="$(basename "${agent}" .toml)"
    check "agent_${name}_toml" \
      python3 -c 'import sys,tomllib; tomllib.load(open(sys.argv[1],"rb"))' "${agent}"
  done
fi

check "backlog_policy_schema" jq -e '
  .version == 3
  and .repository == "nerdchanii/rpm"
  and .execution_queue == {
    source:"issue-labels",
    open_issues_only:true,
    order:"issue-number-ascending",
    active_states:["claimed","review-pending"]
  }
  and .project.number == 7
  and .project.role == "local-roadmap"
  and .project.required_for_execution == false
  and .labels == {
    research:"agent:research",
    ready:"agent:ready",
    claimed:"agent:claimed",
    "review-pending":"agent:review-pending",
    "awaiting-merge":"agent:awaiting-merge",
    blocked:"agent:blocked"
  }
  and .execution_contract == {
    approved_metadata:["approval_id","plan_revision","scope_hash","executor"],
    executor_values:["local","cloud"],
    active_states:["claimed","review-pending"],
    lease:{
      field:"lease",
      required_fields:["run_id","owner","expires_at"],
      ttl_seconds:3600
    },
    idempotency:{
      ledger_field:"runs",
      key_fields:["repository","issue","plan_revision","scope_hash","event_id"],
      algorithm:"sha256-nul-joined"
    }
  }
  and .batch_limits == {research:1,execution:1}
  and .allowed_transitions == {
    untracked:["research"],
    research:["research","ready","blocked"],
    ready:["claimed","blocked"],
    claimed:["ready","review-pending","blocked"],
    "review-pending":["review-pending","awaiting-merge","blocked"],
    "awaiting-merge":["blocked"],
    blocked:["research","ready"]
  }
  and .automation == {
    create_followup_issues_by_default:false,
    merge_pull_requests:false,
    request_codex_review:false
  }
  and .merge_gate == {
    enabled:true,
    source_state:"awaiting-merge",
    order:"issue-number-ascending",
    batch_limit:1,
    required_checks:["metadata","verify"],
    required_mergeable:true,
    forbid_unresolved_p0_p1:true,
    method:"squash",
    delete_branch:true
  }
' .agents/workflows/backlog-policy.json

check "agent_organization" python3 scripts/check-agent-organization.py
check "agent_hooks_json" jq -e . .codex/hooks.json
for hook in .codex/hooks/agent_tool_policy.py .codex/hooks/issue_manager_stop_gate.py; do
  name="$(basename "${hook}" .py)"
  check "hook_${name}_syntax" \
    python3 -c 'import ast,pathlib,sys; ast.parse(pathlib.Path(sys.argv[1]).read_text())' "${hook}"
done

for script in \
  scripts/backlog-gen \
  scripts/check-agent-backlog-access.sh \
  scripts/collect-pr-review-context.sh \
  scripts/create-review-followup-issue.sh \
  scripts/ticket-gen
do
  [ -f "${script}" ] || continue
  name="$(basename "${script}")"
  check "script_${name}_syntax" bash -n "${script}"
done

check "script_check_agent_issue_readiness_syntax" \
  python3 -c 'import ast,pathlib; ast.parse(pathlib.Path("scripts/check-agent-issue-readiness.py").read_text())'
check "script_check_agent_organization_syntax" \
  python3 -c 'import ast,pathlib; ast.parse(pathlib.Path("scripts/check-agent-organization.py").read_text())'
check "script_check_cloud_queue_contract_syntax" \
  python3 -c 'import ast,pathlib; ast.parse(pathlib.Path("scripts/check-cloud-queue-contract.py").read_text())'
check "script_check_merge_gate_syntax" \
  python3 -c 'import ast,pathlib; ast.parse(pathlib.Path("scripts/check-merge-gate.py").read_text())'
check "script_validate_agent_workflow_assets_syntax" \
  bash -n scripts/validate-agent-workflow-assets.sh

check "summary_suppresses_skips" check_summary_suppresses_skips
check "skill_policy_structure_negative" check_skill_policy_structure_negative
check "just_test_verbosity" check_just_test_verbosity

check "collect_pr_review_context_paginates" check_collect_paginates_comments_and_reviews
check "collect_pr_review_context_no_duplicates" check_collect_does_not_duplicate_exhausted_connections
check "readiness_ready_fixture" check_readiness_ready
check "readiness_missing_execution_fixture" check_readiness_missing_execution
check "readiness_missing_fixture" check_readiness_missing
check "readiness_unresolved_fixture" check_readiness_unresolved
check "readiness_live_issue_fixture" check_readiness_live_issue
check "backlog_research_batch" check_backlog_research_batch
check "backlog_no_work" check_backlog_no_work
check "backlog_inventory_order" check_backlog_inventory_order
check "backlog_access_preflight" check_backlog_access_preflight

check "cloud_label_only_selection" sh -c '
  output="$(python3 scripts/check-cloud-queue-contract.py \
    --issues-file .agents/fixtures/backlog/cloud-issues.json \
    --operation select-execution)"
  printf "%s\n" "$output" | jq -e "
    .data.status == \"selected\"
    and .data.issues == [3]
  " >/dev/null
'
check "cloud_claim_contract" sh -c '
  output="$(python3 scripts/check-cloud-queue-contract.py \
    --issues-file .agents/fixtures/backlog/cloud-claim-ready.json \
    --operation claim --issue 3 --run-id run-3 --event-id delivery-3 \
    --executor cloud --plan-revision plan-3 \
    --scope-hash sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
    --lease-owner cloud:executor)"
  printf "%s\n" "$output" | jq -e "
    .data.status == \"claim\"
    and .data.issue == 3
    and .data.before == \"ready\"
    and .data.after == \"claimed\"
    and .data.lease.run_id == \"run-3\"
    and .data.lease.owner == \"cloud:executor\"
    and .data.lease.expires_at == \"2026-08-21T13:00:00Z\"
    and .data.preserved_labels == [\"priority:high\"]
    and .data.labels == [\"agent:claimed\",\"priority:high\"]
  " >/dev/null
'
check "cloud_claim_stale_revision_blocked" sh -c '
  set +e
  output="$(python3 scripts/check-cloud-queue-contract.py \
    --issues-file .agents/fixtures/backlog/cloud-claim-ready.json \
    --operation claim --issue 3 --run-id run-stale --event-id delivery-stale \
    --executor cloud --plan-revision plan-old \
    --scope-hash sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
    --lease-owner cloud:executor)"
  code=$?
  set -e
  [ "$code" -eq 1 ]
  printf "%s\n" "$output" | jq -e ".data.status == \"blocked\" and .data.reason == \"plan-revision-mismatch\"" >/dev/null
'
check "cloud_claim_duplicate_event_no_work" sh -c '
  output="$(python3 scripts/check-cloud-queue-contract.py \
    --issues-file .agents/fixtures/backlog/cloud-claim-duplicate.json \
    --operation claim --issue 3 --run-id run-3 --event-id delivery-3 \
    --executor cloud --plan-revision plan-3 \
    --scope-hash sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
    --lease-owner cloud:executor)"
  printf "%s\n" "$output" | jq -e ".data.status == \"no-work\" and .data.reason == \"duplicate-event\"" >/dev/null
'
check "cloud_claim_expired_lease_blocked" sh -c '
  set +e
  output="$(python3 scripts/check-cloud-queue-contract.py \
    --issues-file .agents/fixtures/backlog/cloud-claim-expired.json \
    --operation claim --issue 8 --run-id run-8b --event-id delivery-8b \
    --executor cloud --plan-revision plan-8 \
    --scope-hash sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb \
    --lease-owner cloud:executor)"
  code=$?
  set -e
  [ "$code" -eq 1 ]
  printf "%s\n" "$output" | jq -e ".data.status == \"blocked\" and .data.reason == \"lease-expired\"" >/dev/null
'
check "cloud_claim_executor_mismatch_blocked" sh -c '
  set +e
  output="$(python3 scripts/check-cloud-queue-contract.py \
    --issues-file .agents/fixtures/backlog/cloud-claim-executor-mismatch.json \
    --operation claim --issue 7 --run-id run-7 --event-id delivery-7 \
    --executor local --plan-revision plan-7 \
    --scope-hash sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc \
    --lease-owner local:executor)"
  code=$?
  set -e
  [ "$code" -eq 1 ]
  printf "%s\n" "$output" | jq -e ".data.status == \"blocked\" and .data.reason == \"executor-mismatch\"" >/dev/null
'
check "cloud_multiple_lifecycle_blocked" sh -c '
  set +e
  output="$(python3 scripts/check-cloud-queue-contract.py \
    --issues-file .agents/fixtures/backlog/cloud-invalid.json \
    --operation select-execution)"
  code=$?
  set -e
  [ "$code" -eq 1 ]
  printf "%s\n" "$output" | jq -e "
    .data.status == \"blocked\"
    and .data.reason == \"multiple-lifecycle-labels\"
  " >/dev/null
'
check "cloud_active_work_no_work" sh -c '
  output="$(python3 scripts/check-cloud-queue-contract.py \
    --issues-file .agents/fixtures/backlog/cloud-active.json \
    --operation select-execution)"
  printf "%s\n" "$output" | jq -e "
    .data.status == \"no-work\"
    and .data.reason == \"active-work\"
  " >/dev/null
'
check "cloud_ready_to_claimed" sh -c '
  output="$(python3 scripts/check-cloud-queue-contract.py \
    --issues-file .agents/fixtures/backlog/cloud-issues.json \
    --operation transition --issue 3 --from-state ready --to-state claimed)"
  printf "%s\n" "$output" | jq -e "
    .data.status == \"transition\"
    and .data.preserved_labels == [\"priority:high\"]
    and .data.labels == [\"agent:claimed\",\"priority:high\"]
  " >/dev/null
'
check "cloud_claimed_to_review_pending" sh -c '
  output="$(python3 scripts/check-cloud-queue-contract.py \
    --issues-file .agents/fixtures/backlog/cloud-active.json \
    --operation transition --issue 4 --from-state claimed --to-state review-pending)"
  printf "%s\n" "$output" | jq -e "
    .data.status == \"transition\"
    and .data.labels == [\"agent:review-pending\",\"kind:bug\"]
  " >/dev/null
'
check "cloud_review_not_arrived_no_work" sh -c '
  output="$(python3 scripts/check-cloud-queue-contract.py \
    --issues-file .agents/fixtures/backlog/cloud-review.json \
    --operation select-review)"
  printf "%s\n" "$output" | jq -e "
    .data.status == \"no-work\"
    and .data.reason == \"review-not-arrived\"
    and .data.issues == [12]
  " >/dev/null
'
check "cloud_review_pending_to_awaiting_merge" sh -c '
  selected="$(python3 scripts/check-cloud-queue-contract.py \
    --issues-file .agents/fixtures/backlog/cloud-review-ready.json \
    --operation select-review)"
  transitioned="$(python3 scripts/check-cloud-queue-contract.py \
    --issues-file .agents/fixtures/backlog/cloud-review-ready.json \
    --operation transition --issue 12 --from-state review-pending --to-state awaiting-merge)"
  printf "%s\n" "$selected" | jq -e ".data.status == \"selected\"" >/dev/null
  printf "%s\n" "$transitioned" | jq -e "
    .data.status == \"transition\"
    and .data.preserved_labels == [\"kind:feature\"]
    and .data.labels == [\"agent:awaiting-merge\",\"kind:feature\"]
  " >/dev/null
'
check "cloud_queue_has_no_gh_or_project_dependency" sh -c '
  ! rg -n "(^|[^[:alnum:]_])(gh|GH_TOKEN|Project)([^[:alnum:]_]|$)" \
    scripts/check-cloud-queue-contract.py
'
check "merge_gate_pass" sh -c '
  output="$(python3 scripts/check-merge-gate.py \
    --issues-file .agents/fixtures/backlog/merge-ready.json \
    --operation select-merge)"
  printf "%s\n" "$output" | jq -e "
    .data.status == \"merge\"
    and .data.issue == 12
    and .data.pr == 44
    and .data.method == \"squash\"
    and .data.delete_branch == true
  " >/dev/null
'
check "merge_gate_checks_pending_no_work" sh -c '
  output="$(python3 scripts/check-merge-gate.py \
    --issues-file .agents/fixtures/backlog/merge-checks-pending.json \
    --operation select-merge)"
  printf "%s\n" "$output" | jq -e "
    .data.status == \"no-work\"
    and .data.reason == \"checks-pending\"
    and .data.checks == [\"verify\"]
  " >/dev/null
'
check "merge_gate_checks_failed_blocked" sh -c '
  set +e
  output="$(python3 scripts/check-merge-gate.py \
    --issues-file .agents/fixtures/backlog/merge-checks-failed.json \
    --operation select-merge)"
  code=$?
  set -e
  [ "$code" -eq 1 ]
  printf "%s\n" "$output" | jq -e "
    .data.status == \"blocked\"
    and .data.reason == \"checks-failed\"
  " >/dev/null
'
check "merge_gate_no_candidate_no_work" sh -c '
  output="$(python3 scripts/check-merge-gate.py \
    --issues-file .agents/fixtures/backlog/cloud-issues.json \
    --operation select-merge)"
  printf "%s\n" "$output" | jq -e "
    .data.status == \"no-work\"
    and .data.reason == \"no-awaiting-merge-candidate\"
  " >/dev/null
'
check "merge_gate_has_no_gh_or_project_dependency" sh -c '
  ! rg -n "(^|[^[:alnum:]_])(gh|GH_TOKEN|Project)([^[:alnum:]_]|$)" \
    scripts/check-merge-gate.py
'
check "local_prepare_keeps_project_registration" sh -c '
  rg -q "register the new issue in the policy-defined Project" \
    .codex/agents/rpm_idea_issue_creator.toml
  rg -q "local Project preflight" .agents/skills/prepare-backlog/SKILL.md
'
check "workflow_forbids_merge_and_codex_request" sh -c '
  ! rg -n -i \
    "(gh pr merge|merge_pull_request|@codex review)" \
    .agents/skills .codex/agents .agents/docs \
    | rg -v \
      "(Never|never|금지|Do not|does not|do not|without|request_codex_review|configured code review|does not post|no @codex review|or request @codex review|request, or wait for)"
'

if [ "${format}" = "jsonl" ]; then
  jq -nc --arg status "${status}" '{type:"agent_assets_result",data:{status:$status}}'
else
  printf 'agent_assets.status=%s\n' "${status}"
fi

if [ "${status}" != "ok" ]; then
  exit 1
fi
