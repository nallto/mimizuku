---
name: report-queue
description: 報告待ちの結果を優先度つきで蓄積し、1ターン1件ずつ報告する。並列実行や無人実行の結果を扱うときに使用する。
---

# Claude Code用アダプター

`.agents/skills/report-queue/SKILL.md`が手順の正典である。実行前に同ファイルを完全に読み、その指示に従う。このファイルへ優先度規則、ファイル形式、報告手順を複製しない。

呼び出し引数がある場合の対象範囲: `$ARGUMENTS`
