# ADR-0004: Xcode プロジェクトは XcodeGen で生成する(project.yml を正典に)

- ステータス: Accepted
- 日付: 2026-07-14
- 関連: Slice 0 / ADR-0003

## Context(背景)

Slice 0 で App ターゲット(SwiftUI `MenuBarExtra`)を作る必要がある。構成は ADR-0003 のとおり「App ターゲット + ローカル SPM パッケージ `MimizukuCore`」。しかし `.xcodeproj`(pbxproj)を **どう生成・管理するか** は未決定であり、後から参加する人が「なぜこの方式?」と問う判断なので ADR に残す。

プロジェクト定義方式を規定する力:

1. **レビュー規律。** 本プロジェクトは「毎回 diff をレビュー / 小さく説明された変更を優先」する(AGENTS.md / CLAUDE.md)。pbxproj は数百行・UUID 群で、人手のレビューにも AI の差分レビューにも適さない。
2. **再現性の SSOT。** 補助ツールは `mise.toml` で版を固定している(just/jq/swiftlint/swiftformat)。プロジェクト定義も同じ思想で宣言的・再現可能にしたい。`just check` = CI の原則(ローカルと CI の同一性)を、App ビルドにも広げたい。
3. **OSS の複数コントリビュータ。** pbxproj はマージ衝突が多発する。公開後の PR 運用で衝突が常態化するのは避けたい。
4. **ビルド前提。** SwiftUI `MenuBarExtra` アプリは `swift build` では `.app` 化できず、フル Xcode(`xcodebuild`)が必須。これは生成方式に関わらず前提であり、本 ADR の争点ではない。

検討した代替案と却下理由:

- **Xcode GUI で `.xcodeproj` を作成しコミット**: 最短・確実だが、以後の設定変更が巨大な pbxproj 差分になりレビュー規律(力 1)と衝突。マージ衝突リスク(力 3)も残る。速さより規律・再現性を優先して却下。
- **pbxproj を手書き**: 新規ツール不要だが壊れやすく差分が巨大。フル Xcode 非搭載環境では検証も困難。却下。
- **Tuist**: 型安全で大規模・複雑な生成ロジック向き。だが単一アプリにはツールチェーンが重く、学習/保守コストが過剰。現段階では却下(マルチターゲット化時に再検討余地)。

## Decision(決定)

- **XcodeGen を採用**し、リポジトリルートの `project.yml` を Xcode プロジェクト定義の **唯一の正典** とする。
- `xcodegen` を `mise.toml` に追加し、ローカル/CI で版を固定する(補助ツール SSOT に合わせる)。
- 生成物 `Mimizuku.xcodeproj` は **gitignore し、コミットしない**。開く/ビルドする際は `xcodegen generate`(mise 経由)で再生成する。pbxproj をコミットすると、XcodeGen 採用で避けたいマージ衝突と、`project.yml` との二重管理(ドリフト)を再導入するため。
- `justfile` に生成レシピを追加し(例: `just generate`)、コメントアウト中の `app-build` を有効化する。CI の App ビルドジョブは `xcodegen generate` → `xcodebuild ... build` の順で実行する。App ビルドは Xcode 依存のため、純ロジック検証の `just check` には含めない(別ジョブ。domain-pitfalls #8 / CI 注記の方針を踏襲)。
- App ターゲット設定は `project.yml` に宣言する: デプロイターゲット macOS 26.0、Swift 6 言語モード + strict concurrency = complete、`LSUIElement = YES`、`MimizukuCore` ローカルパッケージ依存、Info.plist usage string(Slice 0 の別 task で追加)。

## Consequences(結果)

- (+) プロジェクト設定変更が `project.yml` の小さな差分としてレビューできる(力 1 に合致)。
- (+) pbxproj のマージ衝突が構造的に発生しない。OSS コントリビューションに強い(力 3)。
- (+) mise + CI でローカル/CI が同一・再現可能(力 2)。
- (+) private API 不使用・オンデバイス等のハード制約に無関係。XcodeGen はビルド構成の生成のみで、成果物バイナリの挙動には介在しない。
- (−) ビルドツール依存が 1 つ増える(mise で緩和)。コントリビュータは初回に `xcodegen generate` の一手間が要る(README / CONTRIBUTING に明記する)。
- (−) Xcode GUI 上で行った設定変更は `project.yml` へ自動反映されない。運用ルールとして「設定は `project.yml` が正。GUI で変えたら `project.yml` に反映して再生成」を徹底する。
- (−) XcodeGen が表現できない/追随の遅い新しい Xcode 設定が出た場合、個別の回避策が要る。

## 再検討する条件(該当したら新 ADR で移行を決定)

1. マルチターゲット化や複雑なプロジェクト生成ロジックが必要になり、Tuist 等の型安全 DSL の実益がコストを上回った。
2. XcodeGen のメンテナンスが停滞し、新しい Xcode / ビルド設定に追随できなくなった。
