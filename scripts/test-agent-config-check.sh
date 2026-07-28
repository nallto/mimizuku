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
  "$fixture_root/scripts/agent-hooks"
cp -R "$source_root/.agents" "$fixture_root/.agents"
cp -R "$source_root/.claude/agents" "$fixture_root/.claude/agents"
cp -R "$source_root/.claude/hooks" "$fixture_root/.claude/hooks"
cp -R "$source_root/.claude/skills" "$fixture_root/.claude/skills"
cp "$source_root/.claude/settings.json" "$fixture_root/.claude/settings.json"
cp "$source_root/.codex/hooks.json" "$fixture_root/.codex/hooks.json"
cp "$source_root/AGENTS.md" "$fixture_root/AGENTS.md"
cp \
  "$source_root/scripts/check-agent-config.sh" \
  "$source_root/scripts/check-skill-frontmatter.rb" \
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

adapter=.claude/skills/agent-config/SKILL.md
mv "$adapter" "$adapter.bak"
expect_failure "adapter欠落" "claude-code: agent-configのadapterがない"
mv "$adapter.bak" "$adapter"

mkdir -p .claude/commands
cp "$adapter" .claude/commands/agent-config.md
expect_failure "同名command" ".claude/commands/agent-config.md: 共通skillと重複している"
rm -f .claude/commands/agent-config.md

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

echo "agent config negative tests passed"
