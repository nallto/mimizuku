# G-0005: GitHub Actions は full-length commit SHA へピン留めする

- ステータス: Accepted
- 日付: 2026-07-15
- 関連: #8, G-0001

## Context(背景)

workflow が参照する外部 action をタグ(`actions/checkout@v4` 等)で指すと、タグは可変であり、タグの指す先が差し替えられれば CI 実行環境で任意コードが動く。これはサプライチェーン攻撃の現実的な経路であり、`ci.yml` のコメントでも当初から「各 action は commit SHA へピン留め推奨」と述べていた ―― が、実体はタグ参照のままだった。

Dependabot(github-actions ecosystem)はタグ版のバンプ PR を出し続け、方針が未確定なまま #1〜#5 の 5 本が滞留していた。「タグ追従のままにするか、SHA ピンへ移行するか」を決めないと、これらの PR を処理できない。

検討した代替案:

- **タグ参照のまま Dependabot に追従(却下)**: 可変タグのリスクを残す。`ci.yml` の既存コメントの意図にも反する。
- **メジャータグ(`@v7`)へピン(却下)**: `@v4` よりは追従頻度が下がるが依然として可変。改ざんリスクは解消しない。
- **full-length commit SHA へピン(採用)**: 参照先が不変。OpenSSF Scorecard の `Pinned-Dependencies` が求める形式でもある。

## Decision(決定)

**全 workflow の全 action を full-length commit SHA へピン留めする。** first-party の `actions/*` も例外にせず一貫させる。

- 各行に `# vX.Y.Z` の版コメントを併記し、可読性(どの版か)を担保する。
- ピン先は各 action の最新リリース版とする。滞留していた Dependabot PR #1〜#5 のバンプはこの移行に統合し、PR 群は close する。
- Dependabot は SHA ピン後も SHA と末尾コメントを追従更新する。ノイズ抑制のため github-actions の更新は `groups` で 1 PR に集約する(`dependabot.yml`)。
- 将来的にリポジトリ設定「Require actions to be pinned to a full-length commit SHA」を有効化し、機械強制へ移す(本方針の恒久的な担保 ―― AGENTS.md「機械が強制できることはここに書かない」)。

## Consequences(結果)

- 得るもの: 参照先が不変になり、タグ差し替えによる CI 侵害経路を塞ぐ / OpenSSF 推奨形式に準拠 / 設定による機械強制へ移行できる土台。
- 失うもの: 生の SHA は可読性が低い(版コメントで緩和)。更新時にタグ→SHA の解決が要る(Dependabot が自動化)。
- 見直し条件: GitHub が action 参照の完全性を別機構(署名付き immutable release 等)で保証し、SHA ピンが冗長になった場合に本 ADR を見直す。
