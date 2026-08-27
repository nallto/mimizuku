#!/usr/bin/env bash
# AI Agent用のPRマージ入口。release-please管理PRは人間自身がマージする(G-0011)。
set -euo pipefail

if (($# < 1)); then
  echo "usage: scripts/agent-merge-pr.sh <PR番号> [gh pr mergeのオプション]" >&2
  exit 2
fi

pr_number=$1
shift

if [[ ! $pr_number =~ ^[0-9]+$ ]]; then
  echo "ERROR: PR番号は正の整数で指定すること: $pr_number" >&2
  exit 2
fi

head_ref=$(gh pr view "$pr_number" --json headRefName --jq .headRefName)
if [[ $head_ref == release-please--branches--* ]]; then
  echo "BLOCKED: release-please PRのマージは人間自身が実行すること(G-0011)" >&2
  exit 2
fi

exec gh pr merge "$pr_number" "$@"
