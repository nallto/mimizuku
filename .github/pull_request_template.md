## 概要

<!-- 何を・なぜ変更したかを簡潔に(日本語可) -->

## 変更内容

-

## 関連 Issue

Closes #

## Squash body

<!-- what / why の要約(TL;DR)。破壊的変更は "BREAKING CHANGE: <内容と移行>" フッターを含める(release-please が major を検出)。マージ時は PR 本文全文を squash コミット本文にする(#14 スタイル)ため、この PR 説明はそのまま main の履歴に残る。 -->

```text

```

## チェックリスト

- [ ] 対応する Issue に紐付けた(上の「関連 Issue」に記入。setup 等の例外は概要に理由)
- [ ] `just check` が手元で green
- [ ] PR タイトルが Conventional Commits 準拠(英語・72 文字以内)
- [ ] Squash body(what / why)を記載した
- [ ] テストを追加・更新した(不要ならその理由を概要に記載)
- [ ] README / docs に影響する変更は同じ PR で更新した(乖離を残さない)
- [ ] 設計判断は ADR に記録した(製品=docs/adr、統治=docs/adr/governance)
- [ ] Core Audio / Speech に触れる変更は docs/domain-pitfalls.md を再読した
- [ ] ハードウェア/TCC 依存の挙動はローカル実機で検証した(該当時)
- [ ] private API・音声/文字起こしのネットワーク送信を追加していない(hard constraints)
