# G-0009: Agentのworktreeと作業ファイルをプロジェクト内に置く

- ステータス: Accepted
- 日付: 2026-07-29
- 関連: #88, G-0006, G-0008

## Context(背景)

Agentが並行作業用のGit worktreeを作る際、Codexは`/private/tmp`、Claude Codeは`.claude/worktrees/`を使うことがあった。前者はプロジェクト外へ作業内容が残り、後者は製品固有設定と共通作業物の責務を混在させ、gitignoreされていなければmain checkoutの未追跡ファイルとして現れる。

PR本文、承認snapshot、検証結果、コンパイルキャッシュなども、後のターンやセッションで参照するにもかかわらずシステム一時領域へ残ることがあった。一方、テストfixtureやOS・Swift・Xcode・Agent製品自身が管理する短命な内部データまでプロジェクト内へ強制すると、標準的なcleanupやsandboxと衝突する。

検討した代替案:

- **すべての一時ファイルをシステム一時領域へ置く(却下)**: プロジェクト固有の成果物がリポジトリ外へ残り、発見と後始末が難しい。
- **Agent別に`.claude/`または`.codex/`へ置く(却下)**: 同じ用途を製品ごとに多重管理し、未登録Agentの置き場所も定まらない。
- **Claude Codeの`WorktreeCreate` hookで配置を強制する(却下)**: hookは既定のGit処理全体を置換するため、base ref、PR起点、ローカルファイルの複製、cleanupを再実装しないと機能退行する。
- **存続期間と所有者で`local/`とシステム一時領域を使い分ける(採用)**: プロジェクト固有の作業物を発見可能にしつつ、終了時に削除されるfixtureと製品内部データは標準動作を維持できる。

## Decision(決定)

1. Agentや開発者がこのリポジトリ用に明示的に作るGit worktreeの正式な配置を`local/worktrees/<issue番号>-<短い説明>/`とする。稼働中のworktreeは移動せず、次の作成時から適用する。
2. PR本文、承認snapshot、検証結果など、ターンやセッションを越えて参照するプロジェクト固有の作業ファイルは`local/`へ置く。用途別の標準配置は`local/agent-artifacts/`と`local/cache/`とする。
3. 1コマンド内で完結し、同じプロセスの`trap`等で必ず削除するfixtureは`mktemp`を利用できる。OS、Swift、Xcode、Agent製品自身が管理する内部データは各製品の保存先とcleanupに従う。
4. `.agents/`はAgent共通手順、`.claude/`と`.codex/`は製品固有の探索・hook・権限・接続設定に限定し、共通worktreeと作業成果物の正式な置き場所にしない。
5. 製品がセッション開始前に作るworktreeの保存先は、リポジトリ内の指示だけでは強制できない。保存先だけを安全に指定できる製品設定は手動で`local/worktrees/`へ接続し、それがない利用形態ではGitでworktreeを手動作成してからAgentを起動する。
6. `.claude/worktrees/`と`.codex/worktrees/`は移行時や製品既定動作による未追跡表示を防ぐためgitignoreする。ただし、これは正式な保存先としての利用を認めるものではない。
7. 恒久化すべき判断や共有知識は`local/`に留めず、AGENTS.md、docs、ADR、GitHub Issueへ移す。

## Consequences(結果)

- 得るもの:
  - Agent製品に依存せず、プロジェクト固有の作業環境と作業ファイルをリポジトリ内から発見・後始末できる。
  - `.claude/`と`.codex/`の責務を製品固有の接続設定に保ち、共通作業物の多重管理を避けられる。
  - 終了時にcleanupされるfixtureとtoolchain内部データは、既存の安全な標準動作を維持できる。
- 失うもの:
  - 製品既定のworktree作成ボタンやCLIオプションを、そのまま使うだけでは正式な配置にならない場合がある。
  - 製品設定がリポジトリ単位の保存先を表現できない場合、手動worktree作成が必要になる。
- 維持する保証:
  - Agent製品が持つ会話履歴、snapshot、tool出力などの内部データは本ADRの管理対象外であり、製品のretentionとcleanupに従う。
  - worktreeの削除、ブランチ削除、PR統合の承認手順はG-0001とG-0008から変更しない。
