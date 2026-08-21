---
name: patrol
description: 定期巡回の内容を定義する。open PRのCI監視とmain追従、依存更新の可否判定、乖離検査、次タスクの下調べを無人境界の中で行うときに使用する。
---

# Claude Code用アダプター

`.agents/skills/patrol/SKILL.md`が手順の正典である。実行前に同ファイルを完全に読み、その指示に従う。このファイルへ巡回項目や境界を複製しない。

定期実行の登録(OSのcron/launchdやスケジュール機能から`/patrol`を起動する設定)は**個人ローカル設定であり、リポジトリへコミットしない**。登録手順は`docs/development.md`の「無人実行と報告キュー」を参照する。
