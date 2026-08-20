---
name: investigate-issues
description: 複数Issueを並列調査し、規模・依存・実機要否を同一形式で比較して着手順の判断材料を作る。次の着手先を決めるときに使用する。
---

# Claude Code用アダプター

`.agents/skills/investigate-issues/SKILL.md`が手順の正典である。実行前に同ファイルを完全に読み、その指示に従う。このファイルへ調査項目や出力形式を複製しない。

Workflowツールが使える場合は、`.claude/workflows/investigate-issues.js`を`scriptPath`で起動し、Issue番号の配列を`args`に渡す(共通skillの上限・停止条件に従う)。使えない場合は共通skillの逐次実行手順に従う。

呼び出し引数がある場合の調査対象: `$ARGUMENTS`
