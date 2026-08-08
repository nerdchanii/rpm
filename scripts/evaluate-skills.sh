#!/usr/bin/env bash
set -euo pipefail

# evaluate-skills.sh — score RPM skills under .agents/skills/ for structure,
# content completeness, reference/script validity, Claude Code compatibility,
# and Claude Code discoverability (the .claude/skills symlink bridge).
#
# This complements scripts/validate-agent-workflow-assets.sh (which checks the
# Codex/Cloud workflow contract). evaluate-skills.sh is about skill *quality*
# and *Claude usability*, not the queue/gate lifecycle.
#
# Override the checkout root to evaluate another checkout, e.g.:
#   RPM_REPO_ROOT=/path/rpm bash scripts/evaluate-skills.sh

SKILLS_DIR="${SKILLS_DIR:-.agents/skills}"
CLAUDE_LINKS_DIR="${CLAUDE_LINKS_DIR:-.claude/skills}"

usage() {
  cat <<'USAGE'
usage: evaluate-skills.sh [--sync-links] [<skill-name> ...]

Score each skill in .agents/skills/ (or a named subset) on:
  - structure:        SKILL.md, frontmatter name+description
  - content:          description quality, structure sections, length
  - references:       links to references/* resolve
  - scripts:          scripts/* mentioned in SKILL.md exist
  - metadata:         agents/openai.yaml present with default_prompt
  - claude bridge:    .claude/skills/<name> symlink exists (Claude discovery)
  - claude frontmatter: name+description present (Codex/Claude shared keys)

Options:
  --sync-links    reconcile .claude/skills/ symlinks with .agents/skills/ first
                  (add links for new skills, prune dead links), then evaluate
  --json          emit one compact JSON object per skill on stdout
  -h, --help      show this help

Exit code is 1 if any skill has a failing (critical) check, else 0.
USAGE
}

want_json=false
sync_first=false
targets=()

while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --sync-links) sync_first=true; shift ;;
    --json) want_json=true; shift ;;
    --*) printf 'unknown option: %s\n' "$1" >&2; exit 2 ;;
    *) targets+=("$1"); shift ;;
  esac
done

# Override the checkout root (for evaluating another checkout's skills/scripts).
repo_root="${RPM_REPO_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"

resolve_dir() {
  local d="$1"
  case "$d" in
    /*) printf '%s' "$d" ;;
    *)  printf '%s/%s' "$repo_root" "$d" ;;
  esac
}
SKILLS_DIR="$(resolve_dir "$SKILLS_DIR")"
CLAUDE_LINKS_DIR="$(resolve_dir "$CLAUDE_LINKS_DIR")"

if [ ! -d "$SKILLS_DIR" ]; then
  printf 'evaluate.error=missing-skills-dir:%s\n' "$SKILLS_DIR" >&2
  exit 2
fi

sync_links() {
  mkdir -p "$CLAUDE_LINKS_DIR"
  local s name
  while IFS= read -r s; do
    [ -d "$s" ] || continue
    name="$(basename "$s")"
    # Relative target so the links survive across clones/CI (a machine-absolute
    # target like /Users/.../ would dangle everywhere else).
    ln -sfn "../../.agents/skills/$name" "$CLAUDE_LINKS_DIR/$name"
  done < <(find "$SKILLS_DIR" -mindepth 1 -maxdepth 1 -type d)
  local l target
  for l in "$CLAUDE_LINKS_DIR"/*; do
    [ -L "$l" ] || continue
    if [ ! -e "$l" ]; then
      rm -f "$l"
    else
      target="$(basename "$l")"
      [ -d "$SKILLS_DIR/$target" ] || rm -f "$l"
    fi
  done
}

[ "$sync_first" = "true" ] && sync_links

all_skills=()
while IFS= read -r d; do
  all_skills+=("$(basename "$d")")
done < <(find "$SKILLS_DIR" -mindepth 1 -maxdepth 1 -type d | sort)

if [ "${#targets[@]}" -gt 0 ]; then
  for t in "${targets[@]}"; do
    if [ ! -d "${SKILLS_DIR}/${t}" ]; then
      printf 'evaluate.error=unknown-skill:%s\n' "$t" >&2
      exit 2
    fi
  done
  selected=("${targets[@]}")
else
  selected=("${all_skills[@]}")
fi

grade() {
  if   [ "$1" -ge 90 ]; then printf 'A'
  elif [ "$1" -ge 75 ]; then printf 'B'
  elif [ "$1" -ge 60 ]; then printf 'C'
  else printf 'D'
  fi
}

EVAL_FAILS=0
EVAL_TOTAL=0
EVAL_GRADES=""

evaluate_one() {
  local name="$1"
  local dir="${SKILLS_DIR}/${name}"
  local sk="${dir}/SKILL.md"
  local score=0 max=0 fails=0 warns=0
  local -a lines=()

  bump() { max=$((max + $1)); }
  ok()   { score=$((score + $1)); lines+=("  PASS  [$1/$1] $2"); }
  bad()  { lines+=("  FAIL  [0/$1] $2"); fails=$((fails + 1)); }
  soft() { score=$((score + $1)); lines+=("  PASS  [$1/$1] $2"); }
  nit()  { lines+=("  WARN  [0/$1] $2"); warns=$((warns + 1)); }

  bump 10
  if [ -f "$sk" ]; then ok 10 "SKILL.md exists"; else bad 10 "SKILL.md missing"; fi

  local fm=""
  if [ -f "$sk" ]; then
    fm="$(awk 'NR==1 && /^---$/{f=1;next} f&&/^---$/{exit} f' "$sk")"
  fi
  local name_val desc_val
  name_val="$(printf '%s\n' "$fm" | awk '/^name:/{sub(/^name:[[:space:]]*/,""); gsub(/"/,""); print; exit}')"
  desc_val="$(printf '%s\n' "$fm" | awk '/^description:/{sub(/^description:[[:space:]]*/,""); gsub(/^"|"$/,""); print; exit}')"

  bump 10
  if [ -n "$name_val" ] && [ "$name_val" = "$name" ]; then
    ok 10 "frontmatter name"
  elif [ -n "$name_val" ]; then
    bad 10 "frontmatter name '${name_val}' != dir '${name}'"
  else
    bad 10 "frontmatter name missing"
  fi

  bump 10
  if [ -n "$desc_val" ]; then ok 10 "frontmatter description"; else bad 10 "frontmatter description missing"; fi

  bump 5
  if [ "${#desc_val}" -ge 30 ]; then soft 5 "description length >= 30"; else nit 5 "description short (${#desc_val} < 30)"; fi

  bump 10
  if [ -f "$sk" ]; then
    local headers
    headers="$(grep -cE '^#{2,3} +[A-Za-z]' "$sk")"
    if [ "${headers:-0}" -ge 2 ]; then soft 10 "has ${headers} structure sections"; else nit 10 "few structure sections (${headers:-0})"; fi
  else
    nit 10 "cannot read body (no SKILL.md)"
  fi

  bump 10
  if [ -f "$sk" ]; then
    local -a refs=()
    mapfile -t refs < <(grep -oE 'references/[A-Za-z0-9_./-]+' "$sk" | sort -u || true)
    if [ "${#refs[@]}" -eq 0 ]; then
      soft 10 "no references/ cited"
    else
      local broken=()
      for r in "${refs[@]}"; do [ -e "${dir}/${r}" ] || broken+=("$r"); done
      if [ "${#broken[@]}" -eq 0 ]; then soft 10 "all ${#refs[@]} reference(s) resolve"
      else bad 10 "broken references: ${broken[*]}"; fi
    fi
  else
    bad 10 "cannot check references (no SKILL.md)"
  fi

  bump 5
  if [ -f "$sk" ]; then
    local -a scrs=()
    mapfile -t scrs < <(grep -oE 'scripts/[A-Za-z0-9_./-]+\.(sh|py)' "$sk" | sort -u || true)
    if [ "${#scrs[@]}" -eq 0 ]; then
      soft 5 "no scripts/ cited"
    else
      local missing=()
      for s in "${scrs[@]}"; do [ -e "${repo_root}/${s}" ] || missing+=("$s"); done
      if [ "${#missing[@]}" -eq 0 ]; then soft 5 "all ${#scrs[@]} script(s) exist"
      else nit 5 "missing scripts: ${missing[*]}"; fi
    fi
  else
    nit 5 "cannot check scripts (no SKILL.md)"
  fi

  bump 5
  local yaml="${dir}/agents/openai.yaml"
  if [ -f "$yaml" ] && grep -q 'default_prompt' "$yaml"; then
    soft 5 "agents/openai.yaml has default_prompt"
  else
    nit 5 "agents/openai.yaml missing or no default_prompt"
  fi

  bump 5
  if [ -f "$sk" ]; then
    local n
    n="$(wc -l < "$sk" | tr -d ' ')"
    if [ "$n" -le 120 ]; then soft 5 "SKILL.md concise (${n} lines)"; else nit 5 "SKILL.md long (${n} > 120 lines)"; fi
  else
    nit 5 "cannot measure length (no SKILL.md)"
  fi

  bump 10
  if [ -L "${CLAUDE_LINKS_DIR}/${name}" ] && [ -e "${CLAUDE_LINKS_DIR}/${name}" ]; then
    ok 10 ".claude/skills/${name} bridge symlink"
  else
    bad 10 ".claude/skills/${name} symlink missing (run with --sync-links)"
  fi

  bump 10
  if [ -n "$name_val" ] && [ -n "$desc_val" ]; then
    soft 10 "Claude frontmatter OK (name+description)"
  else
    nit 10 "Claude frontmatter incomplete"
  fi

  local pct=0
  [ "$max" -gt 0 ] && pct=$(( score * 100 / max ))
  local g; g="$(grade "$pct")"

  if [ "$want_json" = "true" ]; then
    printf '{"skill":"%s","score":%d,"max":%d,"pct":%d,"grade":"%s","fails":%d,"warns":%d}\n' \
      "$name" "$score" "$max" "$pct" "$g" "$fails" "$warns"
  else
    printf '=== %s ===\n' "$name"
    printf '%s\n' "${lines[@]}"
    printf -- '--------------------------------------------------\n'
    printf 'Score: %d/%d  Grade: %s  (%d warn, %d fail)\n\n' "$score" "$max" "$g" "$warns" "$fails"
  fi

  EVAL_FAILS=$((EVAL_FAILS + fails))
  EVAL_TOTAL=$((EVAL_TOTAL + 1))
  EVAL_GRADES="$EVAL_GRADES $g"
}

for name in "${selected[@]}"; do
  evaluate_one "$name"
done

if [ "$want_json" = "false" ]; then
  printf '=== Summary (%d skill(s)) ===\n' "$EVAL_TOTAL"
  for g in A B C D; do
    n=$(printf '%s\n' "$EVAL_GRADES" | tr ' ' '\n' | grep -cx "$g" || true)
    printf '%s=%d ' "$g" "$n"
  done
  printf '\n'
  [ "$EVAL_FAILS" -gt 0 ] && printf '%d failing check(s) — see FAIL lines above.\n' "$EVAL_FAILS"
fi

[ "$EVAL_FAILS" -gt 0 ] && exit 1
exit 0
