# G-0001: マージは squash に統一し、コミット規約は PR タイトルで強制する

- ステータス: Accepted
- 日付: 2026-07-13
- 関連: G-0002, G-0003

## Context(背景)

マージ方式(squash / merge commit / rebase)が混在すると、「main の 1 コミット = 検証済みの1 論理変更」という不変条件が壊れ、`git bisect`・`git revert`・changelog 自動生成が劣化する。また AI エージェント(Claude Code)は作業中に細かいコミットを多数作るのが自然で、全コミットへのメッセージ規約強制は中間コミットと常に衝突する。

検討した代替案:

- **merge commit(semi-linear 含む)**
  細粒度履歴が残る利点はあるが、内側の未検証コミットがbisect を壊し、Conventional Commits ベースのリリース自動化と干渉する。内側履歴の品質維持には全コミットをアトミックに彫刻する規律が必要でコストが高い。却下。
- **rebase merge + 全コミット commitlint**
  線形履歴だが、ブランチ上の全コミットを清潔に保つ規律が要り、エージェントの作業スタイルと相性が悪い。却下。
- **状況に応じた使い分け**
  都度判断は揺れ、不変条件を破壊する。却下。

## Decision(決定)

- マージは **squash merge のみ**。リポジトリ設定で merge commit / rebase merge を無効化する。
- **PR タイトル**を Conventional Commits 1.0.0 準拠とし、CI(pr-title workflow)で機械検証する。作業ブランチ上の個々のコミット形式は自由。
- squash 本文(what / why、`BREAKING CHANGE:` フッター)は PR 説明の「Squash 本文案」で確定し、マージ時に貼り付ける。
- 例外は構造的に決まるケースのみ(例: G-0002 の条件で release ブランチを導入した場合のback-merge)。都度判断による例外は認めない。

## Consequences(結果)

- 得るもの: main の全コミットが CI green / bisect・revert が PR 単位で単純 / release-please が正確に動作 / 新規参加者(と AI)に課す規律が「PR タイトル 1 点」に集約される。
- 失うもの: ブランチ内の細粒度履歴は git 本体に残らない(GitHub の PR ページには残るがプラットフォーム依存)。残すべき情報は squash 本文と ADR に書く運用で補う。
- 成立条件: PR が小さい(1 PR = 1 論理変更)/ ブランチが短命 / stacked PR を常用しない。
- 移行条件: stacked PR が常態化、または PR 大型化が避けられない場合、rebase merge + 全コミットcommitlint への移行を新 ADR で検討する。
