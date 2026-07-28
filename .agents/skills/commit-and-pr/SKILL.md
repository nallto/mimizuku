---
name: commit-and-pr
description: コミットからPR、CI確認、squash merge、統合後の後始末までを進める。git commit、PR作成、マージ準備、stacked branchの統合時に使用する。
---

# コミットと PR の作成手順

このスキルは統合手順への入口であり、手順本文の正典ではない。実行前に必ず次を
順に読む。

1. `AGENTS.md`の「ブランチとマージ」「コミットとPR」「実行モード」
2. `docs/development.md`の「変更をmainへ統合する」
3. `.github/pull_request_template.md`

具体的なコマンド、PR本文形式、CI条件、squash本文、統合後の同期、stacked branchの
扱いは`docs/development.md`だけに定義する。このファイルへ複製しない。

## 適用

- Approval-drivenではコミット前の変更確認を、利用中のAgentが提供する
  ユーザー入力機構または会話で受ける。
- 非自明な変更は`verify`スキルに従って第三者検証を行う。
- PRマージとブランチ削除は、実行モードにかかわらず直前で停止し、対象と最新状態を
  示して明示承認を得る。
- 権限やフックが共通手順の操作を拒否した場合は迂回せず、失敗内容を報告する。
