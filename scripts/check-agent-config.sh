#!/usr/bin/env bash
# Agent共通skillと環境別アダプター、共通hookの構成を検証する。
set -euo pipefail

repo_root=$(git rev-parse --show-toplevel)
cd "$repo_root"

fail() {
  echo "agent config check failed: $1" >&2
  exit 1
}

check_skill_frontmatter() {
  local file=$1
  local frontmatter

  [[ $(sed -n '1p' "$file") == "---" ]] ||
    fail "$file: YAML frontmatterの開始行がない"
  frontmatter=$(sed -n '2,/^---$/p' "$file")
  [[ $frontmatter == *$'\n---' ]] ||
    fail "$file: YAML frontmatterの終了行がない"
  grep -q '^name:[[:space:]]*[^[:space:]]' <<<"$frontmatter" ||
    fail "$file: nameがない"
  grep -q '^description:[[:space:]]*[^[:space:]]' <<<"$frontmatter" ||
    fail "$file: descriptionがない"
}

while IFS= read -r -d '' skill_file; do
  check_skill_frontmatter "$skill_file"
done < <(find .agents/skills .claude/skills -name SKILL.md -print0)

for adapter in .claude/skills/*/SKILL.md; do
  skill_name=$(basename "$(dirname "$adapter")")
  [[ -f ".agents/skills/$skill_name/SKILL.md" ]] ||
    fail "$adapter: 対応する共通skillがない"
  grep -Fq ".agents/skills/$skill_name/SKILL.md" "$adapter" ||
    fail "$adapter: 対応する共通skillを参照していない"
done

for duplicate_command in adr check verify; do
  [[ ! -f ".claude/commands/$duplicate_command.md" ]] ||
    fail ".claude/commands/$duplicate_command.md: 共通skillと重複している"
done

grep -Fq ".agents/skills/verify/references/verifier.md" .claude/agents/verifier.md ||
  fail ".claude/agents/verifier.md: 共通検証基準を参照していない"
grep -Fq "scripts/agent-hooks/protect-command.sh" .claude/settings.json ||
  fail ".claude/settings.json: 共通PreToolUse hookを参照していない"
grep -Fq "scripts/agent-hooks/protect-command.sh" .codex/hooks.json ||
  fail ".codex/hooks.json: 共通PreToolUse hookを参照していない"

jq empty .claude/settings.json
jq empty .codex/hooks.json

run_hook_case() {
  local name=$1
  local expected_status=$2
  local command=$3
  local output
  local actual_status

  set +e
  output=$(
    jq -n --arg command "$command" '{tool_input: {command: $command}}' |
      bash scripts/agent-hooks/protect-command.sh 2>&1
  )
  actual_status=$?
  set -e

  [[ $actual_status -eq $expected_status ]] ||
    fail "$name: status=$actual_status, expected=$expected_status, output=$output"
  if [[ $expected_status -eq 2 ]]; then
    [[ $output == BLOCKED:* ]] ||
      fail "$name: ブロック理由が出力されていない"
  fi
}

run_hook_case "安全なコマンド" 0 "git status --short"
run_hook_case "force push" 2 "git push --force origin topic"
run_hook_case "main直接push" 2 "git push origin HEAD:main"
run_hook_case "hook回避" 2 "git commit --no-verify"
run_hook_case "広範囲削除" 2 "rm -rf /"

echo "agent config check passed"
