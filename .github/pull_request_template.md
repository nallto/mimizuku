## 概要

<!-- 何を・なぜ変更したかを簡潔に(日本語可) -->

## 変更内容

-

## 関連 Issue

Closes #

## 人の介在が必要な項目

<!-- 人の介在なしに進められない項目があれば、`needs-human` ラベルを付けて種類と具体手順を書く。種類の一覧と理由は docs/adr/governance/G-0010-unattended-agent-work.md。該当が無ければ、この見出しごと削除する(PR 本文全文が squash 本文として履歴に残るため、空の節を残さない)。 -->

## Squash body

<!-- what / why の要約(TL;DR)。破壊的変更は "BREAKING CHANGE: <内容と移行>" フッターを含める(release-please が major を検出)。マージ時は PR 本文全文を squash コミット本文にする(#14 スタイル)ため、この PR 説明はそのまま main の履歴に残る。 -->

```text

```

## チェックリスト

- [ ] 対応する Issue に紐付けた(上の「関連 Issue」に記入。setup 等の例外は概要に理由)
- [ ] `just check` が手元で green
- [ ] PR タイトルが Conventional Commits 準拠(type は英語、summary は日本語可、72 文字以内)
- [ ] Squash body(what / why)を記載した
- [ ] テストを追加・更新した(不要ならその理由を概要に記載)
- [ ] README / docs に影響する変更は同じ PR で更新した(乖離を残さない)
- [ ] 設計判断は ADR に記録した(製品=docs/adr、統治=docs/adr/governance)
- [ ] Agent関連設定を変更した場合、registryの全Agentとfallbackへの影響を確認した
- [ ] Agent製品上でしか確認できないskill探索・trust・hook発火の結果、または未確認理由を概要に記載した
- [ ] Core Audio / Speech に触れる変更は docs/domain-pitfalls.md を再読した
- [ ] ハードウェア/TCC 依存の挙動はローカル実機で検証した(該当時)
- [ ] 人の介在が必要な項目がある場合、`needs-human` ラベルと上の節を記入した
- [ ] private API・音声/文字起こしのネットワーク送信を追加していない(hard constraints)
