--- name: commit-and-pr description: コミット作成と PR(プルリクエスト)作成の手順。Conventional Commits 準拠の PR タイトル、squash 本文の書き方、マージ前条件。git commit、PR 作成、マージ準備のときに使用する。---

# コミットと PR の作成手順

前提(G-0001): マージは squash のみ。main の履歴に残るのは「PR タイトル + squash 本文」だけ。ブランチ上の個々のコミットは main の履歴に残らないため形式は自由(論理単位で分けるとレビューしやすい)。

## コミット(作業ブランチ上)

1. `just check` が green であることを確認する。
2. 変更を論理単位でステージする。
3. コミットメッセージ案を提示し、承認を得てからコミットする。

## PR 作成

1. **PR タイトル**(= main のコミットヘッダ。CI が検証する):
   - Conventional Commits 1.0.0 準拠: `<type>(<scope>): <要約>`
   - type: `feat` `fix` `perf` `refactor` `docs` `test` `build` `ci` `chore` `revert`
   - 破壊的変更は `!` を付ける: `feat(capture)!: AudioSource 契約を変更`
   - 要約: type は英語トークン、要約(summary)は日本語でよい。ヘッダ全体で 72 文字以内・末尾ピリオドなし。
2. **squash 本文案**を PR 説明の `## Squash 本文案` セクションに書く:
   - what(何を)と why(なぜ)。
   - 破壊的変更は `BREAKING CHANGE: <内容と移行方法>` フッターを含める(release-please がmajor バンプを検出するのに必要)。
   - マージ実行者はこのセクションを squash コミット本文に貼り付ける。GitHub の自動生成(コミットの羅列)をそのまま使わない。
3. **PR 説明**(日本語): 概要・変更点・`Closes #<issue>`・テンプレートのチェックリスト。
4. マージ前条件: CI(check / pr-title / gitleaks)がすべて green。

## 禁止事項

- main への直接 push、force push(hooks でもブロック)。
- `--no-verify` の使用。
- CI が red のままのマージ依頼。
- 署名証明書・プロビジョニング成果物・録音音声・文字起こしのコミット。
