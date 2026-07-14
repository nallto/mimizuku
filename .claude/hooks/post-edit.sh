#!/usr/bin/env bash
# PostToolUse フック: 編集されたファイルを自動整形する。
# justfile に `fmt-file` レシピが定義されると自動で有効化される(未定義なら no-op)。
# 整形/lint 失敗時は exit 2 で失敗内容を Claude にフィードバックする。
set -euo pipefail

input=$(cat)
file=$(printf '%s' "$input" | jq -r '.tool_input.file_path // empty')
[[ -z "$file" || ! -f "$file" ]] && exit 0

command -v just >/dev/null 2>&1 || exit 0
just --show fmt-file >/dev/null 2>&1 || exit 0

if ! out=$(just fmt-file "$file" 2>&1); then
  echo "fmt-file が失敗しました: $out" >&2
  exit 2
fi
exit 0
