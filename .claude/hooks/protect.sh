#!/usr/bin/env bash
# PreToolUse フック: 危険な Bash コマンドをブロックする。
# exit 2 = ブロック(stderr が Claude にフィードバックされる)。
# 注意: settings.json の Bash deny ルールは前方一致で回避されうるため、ここが実質的な
#       防御線(多層防御の 2 層目)。文字列検査であり完全ではない。
set -euo pipefail

input=$(cat)
cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // empty')
[[ -z "$cmd" ]] && exit 0

deny() {
  echo "BLOCKED: $1" >&2
  exit 2
}

# --- git push 系 ---
if [[ "$cmd" =~ git[[:space:]].*push ]]; then
  if [[ "$cmd" =~ --force ]] || [[ "$cmd" =~ [[:space:]]-f([[:space:]]|$) ]]; then
    deny "force push は禁止(G-0001: squash 統一・履歴保護)"
  fi
  if [[ "$cmd" =~ (main|master)([[:space:]]|$|:) ]]; then
    deny "main への直接 push は禁止。ブランチを作成し PR を出すこと(AGENTS.md)"
  fi
fi

# --- フック・検証の回避 ---
if [[ "$cmd" =~ --no-verify ]]; then
  deny "--no-verify によるフック回避は禁止(AGENTS.md)"
fi

# --- 広範囲の破壊的削除 ---
if [[ "$cmd" =~ rm[[:space:]]+-[a-zA-Z]*[rf][a-zA-Z]*[rf] ]]; then
  if [[ "$cmd" =~ rm[[:space:]]+-[a-zA-Z]+[[:space:]]+(/([[:space:]]|$)|~|\$HOME|\.\.) ]]; then
    deny "リポジトリ外・広範囲への rm -rf は禁止"
  fi
fi

exit 0
