---
name: slice-prep
description: スライス着手前の下調べを並列化し、計画草案と未決論点を作る。実装計画のスライスや大きめのIssueへ着手する前に使用する。
---

# Claude Code用アダプター

`.agents/skills/slice-prep/SKILL.md`が手順の正典である。実行前に同ファイルを完全に読み、その指示に従う。このファイルへ読むソースや出力形式を複製しない。

Workflowツールが使える場合は、`.claude/workflows/slice-prep.js`を`scriptPath`で起動し、スライス番号またはIssue番号を`args`に渡す(共通skillの上限・停止条件に従う)。使えない場合は共通skillの逐次実行手順に従う。

呼び出し引数がある場合の対象: `$ARGUMENTS`
