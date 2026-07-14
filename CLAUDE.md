@AGENTS.md

# Claude Code 固有の指示

- 非自明な変更は plan-execute-verify スキルの手順に従う(計画 → 承認 → 実行 → `just check` → 報告)。Core Audio や Speech に触れる作業は、計画を提示して承認を待ってからコードを書き、先に `docs/domain-pitfalls.md` を再読する。
- コミット・PR の作成は commit-and-pr スキルの手順に従う。
- 個人的なメモは `CLAUDE.local.md`(gitignore 済み)へ。チームが知るべき知識はAGENTS.md または docs/ への追記を提案する(勝手に確定しない)。
- ユーザーは毎回 diff をレビューする。大きな変更より、小さく説明された変更を優先する。
