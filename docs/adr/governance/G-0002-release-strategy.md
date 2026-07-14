# G-0002: main のみ + release-please。release ブランチは常設しない

- ステータス: Accepted
- 日付: 2026-07-13
- 関連: G-0001

## Context(背景)

デリバリー速度を保ちつつ、リリースのタイミングは明示的に制御したい。release ブランチを「main が不安定だから」という動機で作ると、main の品質規律が緩む方向に働く。staging / production などの環境ブランチは、環境差をブランチで表現するアンチパターン(環境差は設定と成果物の昇格で表現する)。

検討した代替案:

- **Git Flow(develop / release / hotfix 常設)**
  継続デリバリーには過剰。考案者自身がWeb アプリにはよりシンプルなフローを推奨と原典に追記している。却下。
- **release ブランチの常設**
  複数バージョン並行保守が現時点で存在しないため不要。却下(導入条件は下記)。

## Decision(決定)

- ブランチは main のみ。**main は常にリリース可能**(G-0001 の不変条件が支える)。
- リリース制御は release-please: main へのマージは自由に続け、リリースは自動生成される**リリース PR をマージした瞬間にのみ**発生する(タグ・GitHub Release・CHANGELOG 更新)。
- release-type は当面 `simple`(version.txt + CHANGELOG.md 管理)。
- 実際の macOS 配布(Developer ID 署名 → notarize → staple → Homebrew cask)は Slice 4 で別 workflow として追加し、リリースタグを起点にする。

## Consequences(結果)

- 得るもの: リリースが「リリース PR の承認」という明示的な人間の判断に集約 / ブランチモデルが最小 / SemVer・CHANGELOG が Conventional Commits から自動導出。
- 失うもの: リリース直前だけの安定化期間(コードフリーズ)は持てない。
- **release/x.y の導入条件**(該当したら新 ADR で移行):
  1. 複数バージョンの並行保守(旧版へのセキュリティパッチ等)が必要になった。
  2. ストア審査など外部のリリースサイクルに合わせたリリーストレインが必要になった。
