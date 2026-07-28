# G-0006: Agent共通ワークフローは`.agents/skills`を正典とする

- ステータス: Accepted
- 日付: 2026-07-28
- 関連: #79, G-0004

## Context(背景)

本リポジトリではClaude Code向けのskill、command、subagent、hookを`.claude/`に
管理してきた。`AGENTS.md`を読む他のAgentも規約は共有できるが、具体的な
plan-execute-verify、ADR、PR統合、UI設計、第三者検証の手順はClaude Code固有の
配置にあり、同じ動作を再現できなかった。

一方、利用するAgent製品ごとに手順本文をコピーすると、更新漏れによって検証条件や
マージ手順が分岐する。skill探索場所、subagent定義、hookイベント、権限モデルは
製品ごとに異なるため、設定ファイル自体を完全に一つへ統合することもできない。

検討した代替案:

- **`.claude/`を正典のまま他Agentが直接読む(却下)**: Claude Code固有設定と
  共通手順の境界が曖昧で、他Agentから手順を発見しにくい。
- **各Agent向けディレクトリへ手順全文をコピー(却下)**: 同じ手順の複数管理になり、
  将来の乖離を防げない。
- **探索ディレクトリ全体をsymlinkで共用(却下)**: 製品ごとの探索・監視・内部
  ファイル生成の挙動に依存し、一方の更新で他方が不安定になる可能性がある。
- **共通本文と製品別アダプターを分離(採用)**: 重複を最小限にしながら、各製品が
  公式の探索・設定場所を使える。

## Decision(決定)

Agent向けワークフローを次の層へ分離する。

- `AGENTS.md`: 全員が常時知る規約と正典への索引。
- `.agents/skills/`: skill本文、検証基準、参照資料の正典。
- `.claude/skills/`: Claude Codeの探索用アダプター。対応する共通skillを読む指示
  だけを置き、手順本文を複製しない。
- `.claude/agents/`などの製品固有subagent定義: 役割、利用可能tool、共通検証基準
  への参照だけを置く。
- `scripts/agent-hooks/`: 複数製品で共有できる決定的なhook処理の正典。
- `.claude/settings.json`、`.codex/hooks.json`: 各製品のイベント・権限モデルを
  共通処理へ接続するアダプター。

Claude Codeの同名commandとskillは機能が重複しskillが優先されるため、`adr`、
`check`、`verify`の`.claude/commands/`は持たず、Claude Code用skillをslash
commandの入口として使う。

hookは入力と目的が一致する場合だけ共通化する。shellのPreToolUseは共通化し、
単一`file_path`を前提とするClaude CodeのPostToolUse自動整形は製品固有のまま
維持する。sandboxと権限設定も製品別に管理し、完全な互換性を装わない。

## Consequences(結果)

- 得るもの: Claude Code、Codex、その他のAgentが同じ手順本文と検証基準へ到達でき、
  PR統合や第三者検証の定義が一箇所になる。
- 得るもの: 共有可能な危険コマンド判定を一つのテスト対象にでき、製品別hookの
  判定差を減らせる。
- 失うもの: `.claude/skills/`には探索用のname、description、参照指示が残り、
  最小限のアダプター管理は必要になる。
- 失うもの: 製品ごとのtrust、sandbox、権限、イベント入力の差は残る。新しいAgent
  へ対応するときは、その製品用接続層の追加と実機での認識確認が必要になる。
- 見直し条件: Claude Codeを含む利用製品が同じskill探索場所とhook設定標準を
  公式に採用し、アダプターなしで共通本文を発見できるようになった場合。
