--- name: commit-and-pr description: コミット作成と PR(プルリクエスト)作成の手順。Conventional Commits 準拠の PR タイトル、squash 本文の書き方、マージ前条件。git commit、PR 作成、マージ準備のときに使用する。---

# コミットと PR の作成手順

前提(G-0001): マージは squash のみ。main の履歴に残るのは「PR タイトル + squash 本文」だけ。ブランチ上の個々のコミットは main の履歴に残らないため形式は自由(論理単位で分けるとレビューしやすい)。

## コミット(作業ブランチ上)

1. `just check` が green であることを確認する。
2. **Approval-driven モードでは、コミット前に一度止めて完了を報告し、変更内容の確認を依頼する**(未コミットの diff をエディタで前後の文脈とともにレビューできるようにするため。詳細は AGENTS.md「AI エージェントの作業規律」)。
3. 変更を論理単位でステージし、コミットメッセージ案を添えて、承認を得てからコミットする。
4. 例外: 自動モード(🟢 Goal-driven / 🟡 Budget-driven。定義は AGENTS.md「実行モード」)では、確認を取らずにこまめにコミットして進めてよい。

## PR 作成

1. **PR タイトル**(= main のコミットヘッダ。CI が検証する):
   - Conventional Commits 1.0.0 準拠: `<type>(<scope>): <要約>`
   - type: `feat` `fix` `perf` `refactor` `docs` `test` `build` `ci` `chore` `revert`
   - 破壊的変更は `!` を付ける: `feat(capture)!: AudioSource 契約を変更`
   - 要約: type は英語トークン、要約(summary)は日本語でよい。ヘッダ全体で 72 文字以内・末尾ピリオドなし。
2. **PR 説明は 5 セクション**(概要 / 変更内容 / 関連 Issue / Squash body / チェックリスト。テンプレート参照)で書く。**マージ時は PR 本文全文を squash コミット本文にする**(#14 スタイル。`gh pr merge <n> --squash --body-file <PR本文> --subject "<PRタイトル> (#<n>)"`)。PR 説明がそのまま main 履歴に残る。
   - `## Squash body` 節には what / why の要約を書く(破壊的変更は `BREAKING CHANGE: <内容と移行方法>` フッター。release-please が major バンプ検出に使う)。
   - GitHub の自動生成(コミットの羅列)は使わない。
3. **PR 説明**(日本語): 概要・変更点・`Closes #<issue>`・テンプレートのチェックリスト。
4. マージ前条件: CI(check / pr-title / gitleaks)がすべて green。

## 禁止事項

- main への直接 push、force push(hooks でもブロック)。
- `--no-verify` の使用。
- CI が red のままのマージ依頼。
- 署名証明書・プロビジョニング成果物・録音音声・文字起こしのコミット。
