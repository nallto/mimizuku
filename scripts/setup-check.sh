#!/usr/bin/env bash
# テンプレートのプレースホルダ(二重波括弧+大文字スネークケース)と、コロン付き
# "TODO(setup)" マーカーの残存を検出する。すべて解消するまで `just check`(= CI)は
# green にならない。これは意図的な設計(セットアップ判断を明示的に迫るため)。
#
# コロン付きの "TODO(defer)" マーカーは意図的に検出しない ―― これは追跡はするが
# 正当に保留する作業(例: 法務確認待ちのライセンス確定)を指し、CI をブロックしない。
# docs/development.md を参照。
#
# 本ファイルと setup-github.sh は検査対象から除外する(パターン定義を含むため)。
set -euo pipefail
cd "$(dirname "$0")/.."

ph_pattern='\{\{[A-Z_]+\}\}'
todo_pattern='TODO\(setup\):'

matches=$(grep -rInE \
  --exclude-dir=.git \
  --exclude-dir=.build \
  --exclude='setup-check.sh' \
  --exclude='setup-github.sh' \
  -e "$ph_pattern" -e "$todo_pattern" . || true)

if [[ -n "$matches" ]]; then
  count=$(printf '%s\n' "$matches" | wc -l | tr -d ' ')
  echo "✗ setup-check: 未設定の箇所が ${count} 件残っています:" >&2
  printf '%s\n' "$matches" >&2
  echo "" >&2
  echo "  各マーカーを埋めるか、正当に保留するものは TODO(defer): へ変えてください。" >&2
  exit 1
fi

echo "✓ setup-check: 未設定の箇所はありません"
