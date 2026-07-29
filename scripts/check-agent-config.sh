#!/usr/bin/env bash
# Agent共通skillと環境別アダプター、共通hookの構成を検証する。
set -euo pipefail

repo_root=$(git rev-parse --show-toplevel)
cd "$repo_root"

fail() {
  echo "agent config check failed: $1" >&2
  exit 1
}

skill_files=()
while IFS= read -r -d '' skill_file; do
  skill_files+=("$skill_file")
done < <(find .agents/skills .claude/skills -name SKILL.md -print0)

ruby_bin=${AGENT_CONFIG_RUBY_BIN:-/usr/bin/ruby}
[[ -x $ruby_bin ]] ||
  fail "YAML frontmatter検証に必要な${ruby_bin}がない"
"$ruby_bin" scripts/check-skill-frontmatter.rb "${skill_files[@]}"

registry=.agents/integrations.json
jq -e '
  . as $root |
  $root.schemaVersion == 1 and
  ($root.fallback.instructions | type == "string") and
  ($root.fallback.skills | type == "string") and
  ($root.agents | (type == "array" and length > 0)) and
  (([$root.agents[].id] | length) == ([$root.agents[].id] | unique | length)) and
  all(
    $root.agents[];
    (.id | type == "string" and length > 0) and
    (.skills.path | type == "string" and length > 0) and
    (.skills.mode == "native" or .skills.mode == "adapter" or .skills.mode == "instructions") and
    ((.hooks.preToolUseConfig? == null) or
      (.hooks.preToolUseConfig | type == "string" and length > 0)) and
    ((.hooks.postToolUseConfig? == null) or
      (.hooks.postToolUseConfig | type == "string" and length > 0))
  )
' "$registry" >/dev/null ||
  fail "$registry: schemaまたはAgent登録が不正"

fallback_instructions=$(jq -r .fallback.instructions "$registry")
fallback_skills=$(jq -r .fallback.skills "$registry")
[[ -f $fallback_instructions ]] ||
  fail "$registry: fallback instructionsが存在しない"
[[ -d $fallback_skills ]] ||
  fail "$registry: fallback skillsが存在しない"
grep -Fq "$fallback_skills" "$fallback_instructions" ||
  fail "$fallback_instructions: fallback skillsを参照していない"
grep -Fq "$fallback_skills/agent-config/SKILL.md" "$fallback_instructions" ||
  fail "$fallback_instructions: Agent設定変更手順を参照していない"
grep -Fq "local/worktrees/" "$fallback_instructions" ||
  fail "$fallback_instructions: Agent worktreeの正式な配置を参照していない"
grep -Fq "@$fallback_instructions" CLAUDE.md ||
  fail "CLAUDE.md: ${fallback_instructions}をimportしていない"
grep -Fq "Agent worktreeと作業ファイル" docs/development.md ||
  fail "docs/development.md: Agent worktreeと作業ファイルの手順がない"

for ignored_path in \
  local/worktrees/agent-config-probe \
  .claude/worktrees/agent-config-probe \
  .codex/worktrees/agent-config-probe; do
  git check-ignore --quiet "$ignored_path" ||
    fail "$ignored_path: Agent worktree配置がgitignoreされていない"
done

tracked_product_worktrees=$(
  git ls-files -- .claude/worktrees .codex/worktrees
)
[[ -z $tracked_product_worktrees ]] ||
  fail "製品固有worktree配下に追跡ファイルがある: $tracked_product_worktrees"

while IFS=$'\t' read -r agent_id discovery_mode discovery_path; do
  case "$discovery_mode" in
    native)
      [[ $discovery_path == "$fallback_skills" ]] ||
        fail "$agent_id: native skillの正典がfallbackと異なる"
      ;;
    adapter)
      [[ -d $discovery_path ]] ||
        fail "$agent_id: adapter directoryが存在しない"

      for common_skill in "$fallback_skills"/*/SKILL.md; do
        skill_name=$(basename "$(dirname "$common_skill")")
        adapter="$discovery_path/$skill_name/SKILL.md"
        [[ -f $adapter ]] ||
          fail "$agent_id: ${skill_name}のadapterがない"
        grep -Fq "$common_skill" "$adapter" ||
          fail "$adapter: 共通skillを参照していない"
        adapter_lines=$(wc -l <"$adapter" | tr -d ' ')
        [[ $adapter_lines -le 24 ]] ||
          fail "$adapter: 24行を超えているため手順本文の重複を確認する"
      done

      for adapter in "$discovery_path"/*/SKILL.md; do
        skill_name=$(basename "$(dirname "$adapter")")
        [[ -f "$fallback_skills/$skill_name/SKILL.md" ]] ||
          fail "$adapter: 対応する共通skillがない"
      done
      ;;
    instructions)
      [[ -f $discovery_path ]] ||
        fail "$agent_id: instructions fileが存在しない"
      grep -Fq "$fallback_skills" "$discovery_path" ||
        fail "$agent_id: instructionsが共通skillを参照していない"
      ;;
  esac
done < <(
  jq -r '.agents[] | [.id, .skills.mode, .skills.path] | @tsv' "$registry"
)

for common_skill in "$fallback_skills"/*/SKILL.md; do
  skill_name=$(basename "$(dirname "$common_skill")")
  [[ ! -f ".claude/commands/$skill_name.md" ]] ||
    fail ".claude/commands/$skill_name.md: 共通skillと重複している"
done

grep -Fq "$fallback_skills/verify/references/verifier.md" .claude/agents/verifier.md ||
  fail ".claude/agents/verifier.md: 共通検証基準を参照していない"

jq empty .claude/settings.json
jq empty .codex/hooks.json

while IFS=$'\t' read -r agent_id hook_config; do
  [[ -f $hook_config ]] ||
    fail "$agent_id: PreToolUse設定が存在しない"
  grep -Fq "scripts/agent-hooks/protect-command.sh" "$hook_config" ||
    fail "$agent_id: PreToolUse設定が共通hookを参照していない"
done < <(
  jq -r '
    .agents[]
    | select(.hooks.preToolUseConfig? != null)
    | [.id, .hooks.preToolUseConfig]
    | @tsv
  ' "$registry"
)

while IFS=$'\t' read -r agent_id hook_config; do
  [[ -f $hook_config ]] ||
    fail "$agent_id: PostToolUse設定が存在しない"
done < <(
  jq -r '
    .agents[]
    | select(.hooks.postToolUseConfig? != null)
    | [.id, .hooks.postToolUseConfig]
    | @tsv
  ' "$registry"
)

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
