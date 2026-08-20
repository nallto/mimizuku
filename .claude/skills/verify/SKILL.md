---
name: verify
description: verifierサブエージェントによる独立した敵対的検証を行う。非自明な変更の完了確認に使用する。
---

# Claude Code用アダプター

`.agents/skills/verify/SKILL.md`が手順の正典である。実行前に同ファイルを完全に読み、その指示に従う。Claude Codeでは`verifier`サブエージェントを起動する。観点分割を使う場合は`.claude/workflows/verify.js`を`scriptPath`で起動し、要求とdiff範囲を`args`に渡す(共通skillの上限・停止条件に従う)。このファイルへ検証基準を複製しない。

呼び出し引数がある場合の検証範囲: `$ARGUMENTS`
