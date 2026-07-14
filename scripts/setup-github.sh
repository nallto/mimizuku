#!/usr/bin/env bash
# GitHub リポジトリの一度きりのハードニング(任意。リポジトリ内で認証済みの gh CLI が
# 必要)。squash のみ許可と、G-0001 / G-0002 に沿う main ルールセットを設定する。
# 再実行は概ね安全(同名ルールセットが既にあると作成でエラーになる)。
set -euo pipefail
cd "$(dirname "$0")/.."

if ! command -v gh >/dev/null 2>&1 || ! gh repo view >/dev/null 2>&1; then
  echo "gh CLI が未認証、またはリポジトリ外です。スキップします。" >&2
  exit 1
fi

echo "--- マージ方式: squash のみ / マージ後ブランチ自動削除 ---"
gh repo edit \
  --enable-squash-merge \
  --enable-merge-commit=false \
  --enable-rebase-merge=false \
  --delete-branch-on-merge

echo "--- squash 既定: タイトル = PR タイトル / 本文 = 空(マージ時に本文案を貼る) ---"
gh api -X PATCH "repos/{owner}/{repo}" \
  -f squash_merge_commit_title=PR_TITLE \
  -f squash_merge_commit_message=BLANK >/dev/null

echo "--- main ルールセット: PR 必須 / 必須チェック(check, pr-title) / 削除・force push 禁止 ---"
gh api -X POST "repos/{owner}/{repo}/rulesets" --input - >/dev/null <<'RULESET'
{
  "name": "protect-main",
  "target": "branch",
  "enforcement": "active",
  "conditions": { "ref_name": { "include": ["~DEFAULT_BRANCH"], "exclude": [] } },
  "rules": [
    { "type": "deletion" },
    { "type": "non_fast_forward" },
    {
      "type": "pull_request",
      "parameters": {
        "required_approving_review_count": 0,
        "dismiss_stale_reviews_on_push": true,
        "require_code_owner_review": false,
        "require_last_push_approval": false,
        "required_review_thread_resolution": true
      }
    },
    {
      "type": "required_status_checks",
      "parameters": {
        "strict_required_status_checks_policy": true,
        "required_status_checks": [
          { "context": "check" },
          { "context": "pr-title" }
        ]
      }
    }
  ]
}
RULESET

echo "完了。チーム開発では required_approving_review_count を 1 以上へ引き上げてください。"
echo "必須チェックの context は 'check'(ci.yml のジョブ)と 'pr-title'(pr-title.yml の"
echo "ジョブ)です。ジョブ名と同期を保ってください。"
