#!/usr/bin/env bash
# Agent構成チェッカーの主要な失敗経路と診断メッセージを検証する。
set -euo pipefail

source_root=$(git rev-parse --show-toplevel)
fixture_parent=$(mktemp -d)
fixture_root="$fixture_parent/repository"

case "$fixture_parent" in
  /tmp/* | /private/tmp/* | /var/folders/* | /private/var/folders/*) ;;
  *)
    echo "unsafe temporary directory: $fixture_parent" >&2
    exit 1
    ;;
esac

cleanup() {
  if [[ -n ${fixture_parent:-} && -d $fixture_parent ]]; then
    rm -rf -- "$fixture_parent"
  fi
}
trap cleanup EXIT

mkdir -p \
  "$fixture_root/.claude" \
  "$fixture_root/.codex" \
  "$fixture_root/.github/agents" \
  "$fixture_root/.github/hooks" \
  "$fixture_root/docs" \
  "$fixture_root/scripts/agent-hooks"
cp -R "$source_root/.agents" "$fixture_root/.agents"
cp -R "$source_root/.claude/agents" "$fixture_root/.claude/agents"
cp -R "$source_root/.claude/hooks" "$fixture_root/.claude/hooks"
cp -R "$source_root/.claude/skills" "$fixture_root/.claude/skills"
cp -R "$source_root/.claude/workflows" "$fixture_root/.claude/workflows"
cp "$source_root/.claude/settings.json" "$fixture_root/.claude/settings.json"
cp "$source_root/.codex/hooks.json" "$fixture_root/.codex/hooks.json"
cp "$source_root/.github/copilot-instructions.md" "$fixture_root/.github/copilot-instructions.md"
cp "$source_root/.github/agents/verifier.agent.md" "$fixture_root/.github/agents/verifier.agent.md"
cp "$source_root/.github/hooks/mimizuku-policy.json" "$fixture_root/.github/hooks/mimizuku-policy.json"
cp "$source_root/.gitignore" "$fixture_root/.gitignore"
# workflow構文検査のmise exec -- nodeがfixture内でtool解決できるよう、版数定義もコピーする。
cp "$source_root/mise.toml" "$fixture_root/mise.toml"
cp "$source_root/AGENTS.md" "$fixture_root/AGENTS.md"
cp "$source_root/CLAUDE.md" "$fixture_root/CLAUDE.md"
cp "$source_root/docs/development.md" "$fixture_root/docs/development.md"
cp \
  "$source_root/scripts/check-agent-config.sh" \
  "$source_root/scripts/check-skill-frontmatter.rb" \
  "$source_root/scripts/agent-merge-pr.sh" \
  "$source_root/scripts/agent-review-validate.sh" \
  "$fixture_root/scripts/"
cp \
  "$source_root/scripts/agent-hooks/protect-command.sh" \
  "$fixture_root/scripts/agent-hooks/"

git -C "$fixture_root" init --quiet

cd "$fixture_root"
bash scripts/check-agent-config.sh >/dev/null

set +e
missing_ruby_output=$(
  AGENT_CONFIG_RUBY_BIN=/missing/agent-config-ruby \
    bash scripts/check-agent-config.sh 2>&1
)
missing_ruby_status=$?
set -e
[[ $missing_ruby_status -ne 0 ]] ||
  {
    echo "agent config negative test failed: Ruby欠落 did not fail" >&2
    exit 1
  }
grep -Fq \
  "YAML frontmatter検証に必要な/missing/agent-config-rubyがない" \
  <<<"$missing_ruby_output" ||
  {
    echo "agent config negative test failed: Ruby欠落: $missing_ruby_output" >&2
    exit 1
  }

expect_failure() {
  local name=$1
  local expected_message=$2
  local output
  local status

  set +e
  output=$(bash scripts/check-agent-config.sh 2>&1)
  status=$?
  set -e

  [[ $status -ne 0 ]] ||
    {
      echo "agent config negative test failed: $name did not fail" >&2
      exit 1
    }
  grep -Fq "$expected_message" <<<"$output" ||
    {
      echo "agent config negative test failed: $name: $output" >&2
      exit 1
    }
}

cp .agents/integrations.json .agents/integrations.json.bak
jq '.schemaVersion = 1' .agents/integrations.json.bak >.agents/integrations.json
expect_failure "registry旧schema" ".agents/integrations.json: schemaまたはAgent登録が不正"
mv .agents/integrations.json.bak .agents/integrations.json

cp .agents/integrations.json .agents/integrations.json.bak
jq '(.agents[] | select(.id == "claude-code").instructions.source) = "CLAUDE.md"' \
  .agents/integrations.json.bak >.agents/integrations.json
expect_failure \
  "instructions source不整合" \
  "claude-code: instructions sourceがfallbackと異なる"
mv .agents/integrations.json.bak .agents/integrations.json

cp .agents/integrations.json .agents/integrations.json.bak
jq '(.agents[] | select(.id == "github-copilot").skills.path) = ".github/skills"' \
  .agents/integrations.json.bak >.agents/integrations.json
expect_failure \
  "Copilot native skill不整合" \
  "github-copilot: native skillの正典がfallbackと異なる"
mv .agents/integrations.json.bak .agents/integrations.json

adapter=.claude/skills/agent-config/SKILL.md
mv "$adapter" "$adapter.bak"
expect_failure "adapter欠落" "claude-code: agent-configのadapterがない"
mv "$adapter.bak" "$adapter"

mkdir -p .claude/commands
cp "$adapter" .claude/commands/agent-config.md
expect_failure "同名command" ".claude/commands/agent-config.md: 共通skillと重複している"
rm -f .claude/commands/agent-config.md

printf '%s\n' "export const meta = {}" >.claude/workflows/orphan.js
expect_failure "対応共通skillのないworkflow" ".claude/workflows/orphan.js: 対応する共通skillがない"
rm -f .claude/workflows/orphan.js

# ESM構文を含む.jsは素のnode --checkでは無検査で通るため(domain-pitfalls #19)、
# 壊れたworkflowが実際にfailすることを確認する。この回帰テストが無いと、nodeの
# 版数更新などで検査が無言のno-opへ戻っても気づけない。
broken_workflow=.claude/workflows/verify.js
cp "$broken_workflow" "$broken_workflow.bak"
printf '\nconst broken = (\n' >>"$broken_workflow"
expect_failure \
  "workflow構文エラー" \
  ".claude/workflows/verify.js: JavaScript構文エラー"
mv "$broken_workflow.bak" "$broken_workflow"

workflow_skill=.agents/skills/investigate-issues/SKILL.md
cp "$workflow_skill" "$workflow_skill.bak"
sed -e 's/目的//g' "$workflow_skill.bak" >"$workflow_skill"
expect_failure \
  "workflow skillの目的欠落" \
  "$workflow_skill: オーケストレーションの目的が明記されていない"
sed -e 's/停止条件//g' "$workflow_skill.bak" >"$workflow_skill"
expect_failure \
  "workflow skillの停止条件欠落" \
  "$workflow_skill: オーケストレーションの停止条件が明記されていない"
sed -e 's/上限//g' "$workflow_skill.bak" >"$workflow_skill"
expect_failure \
  "workflow skillの上限欠落" \
  "$workflow_skill: エージェント数の上限が明記されていない"
mv "$workflow_skill.bak" "$workflow_skill"

common_skill=.agents/skills/agent-config/SKILL.md
cp "$common_skill" "$common_skill.bak"
printf '%s\n' "---" "name: [" "description: invalid" "---" >"$common_skill"
expect_failure "不正YAML" "YAML frontmatterを解析できません"
mv "$common_skill.bak" "$common_skill"

cp "$adapter" "$adapter.bak"
counter=0
while [[ $counter -lt 25 ]]; do
  printf '%s\n' "# adapter本文の重複" >>"$adapter"
  counter=$((counter + 1))
done
expect_failure "adapter肥大" "24行を超えているため手順本文の重複を確認する"
mv "$adapter.bak" "$adapter"

cp CLAUDE.md CLAUDE.md.bak
grep -Fv "@AGENTS.md" CLAUDE.md.bak >CLAUDE.md
expect_failure \
  "Claude Code共通規約import欠落" \
  "CLAUDE.md: AGENTS.mdをimportしていない"
mv CLAUDE.md.bak CLAUDE.md

copilot_instructions=.github/copilot-instructions.md
mv "$copilot_instructions" "$copilot_instructions.bak"
expect_failure \
  "Copilot instructions欠落" \
  "github-copilot: instructions fileが存在しない"
mv "$copilot_instructions.bak" "$copilot_instructions"

cp "$copilot_instructions" "$copilot_instructions.bak"
grep -Fv "@../AGENTS.md" "$copilot_instructions.bak" >"$copilot_instructions"
expect_failure \
  "Copilot instructions参照切れ" \
  ".github/copilot-instructions.md: CLI用のAGENTS.md importがない"
mv "$copilot_instructions.bak" "$copilot_instructions"

copilot_hook=.github/hooks/mimizuku-policy.json
mv "$copilot_hook" "$copilot_hook.bak"
expect_failure \
  "Copilot hook欠落" \
  "github-copilot: PreToolUse設定が存在しない"
mv "$copilot_hook.bak" "$copilot_hook"

cp "$copilot_hook" "$copilot_hook.bak"
jq '.hooks.PreToolUse[0].matcher = "bash"' "$copilot_hook.bak" >"$copilot_hook"
expect_failure \
  "Copilot hook形式不正" \
  ".github/hooks/mimizuku-policy.json: Copilot PreToolUse hook形式が不正"
mv "$copilot_hook.bak" "$copilot_hook"

copilot_verifier=.github/agents/verifier.agent.md
mv "$copilot_verifier" "$copilot_verifier.bak"
expect_failure \
  "Copilot verifier欠落" \
  ".github/agents/verifier.agent.md: 共通検証基準を参照していない"
mv "$copilot_verifier.bak" "$copilot_verifier"

cp "$copilot_verifier" "$copilot_verifier.bak"
grep -Fv ".agents/skills/verify/references/verifier.md" "$copilot_verifier.bak" >"$copilot_verifier"
expect_failure \
  "Copilot verifier参照切れ" \
  ".github/agents/verifier.agent.md: 共通検証基準を参照していない"
mv "$copilot_verifier.bak" "$copilot_verifier"

cp "$copilot_verifier" "$copilot_verifier.bak"
sed 's/^tools: \[read, search, execute\]$/tools: [read, search, execute, edit]/' \
  "$copilot_verifier.bak" >"$copilot_verifier"
expect_failure \
  "Copilot verifier書き込みtool混入" \
  ".github/agents/verifier.agent.md: 読み取り専用tool構成が不正"
mv "$copilot_verifier.bak" "$copilot_verifier"

cp .gitignore .gitignore.bak
grep -Fv "/.claude/worktrees/" .gitignore.bak >.gitignore
expect_failure \
  "製品worktreeのignore欠落" \
  ".claude/worktrees/agent-config-probe: Agent worktree配置がgitignoreされていない"
mv .gitignore.bak .gitignore

mkdir -p .claude/worktrees/stray
touch .claude/worktrees/stray/tracked.txt
git add --force .claude/worktrees/stray/tracked.txt
expect_failure \
  "製品worktree配下の追跡ファイル" \
  "製品固有worktree配下に追跡ファイルがある: .claude/worktrees/stray/tracked.txt"

git rm -q --cached .claude/worktrees/stray/tracked.txt
rm -rf .claude/worktrees/stray

# agent-review設定のschema不正(G-0012)。設定なしは正常なので、失敗するのは配置時のみ。
mkdir -p local
printf '%s\n' '{"schemaVersion": 1, "defaultProfile": "p", "profiles": {"p": {"runtime": "bogus-cli"}}}' \
  > local/agent-review.json
expect_failure \
  "agent-review設定のschema不正" \
  "local/agent-review.json: agent-review.schema.json を満たさない"
rm -f local/agent-review.json

echo "agent config negative tests passed"
