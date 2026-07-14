# プロジェクト規約(Mimizuku)

このリポジトリで作業するすべての人間と AI エージェントが従う規約の正典(Single Source of Truth)。AGENTS.md を直接読まないツール(Claude Code)は`CLAUDE.md` の import 経由で本ファイルを読み込む。

> 原則: **機械が強制できることはここに書かない。**
> 強制は linter / hooks / CI / ブランチ保護が担う(`.claude/settings.json`・
> `.github/workflows/`・リポジトリ設定が正)。ここには非自明なルールと理由だけを書く。

## プロジェクト概要

Mimizuku は macOS のメニューバー常駐アプリ。マイクとシステム音声を録音し、Apple の Speech フレームワーク(`SpeechAnalyzer` / `SpeechTranscriber`)で完全オンデバイスのリアルタイム文字起こしを行う。対応言語は日本語と英語を最低限とし、将来的に英語→日本語などの翻訳機能の追加も視野に入れる。字幕オーバーレイではなく、確定行が追記されていくライブ議事ログ UI。OSS として公開し、App Store 外(Developer ID + notarization)で配布する。

- スタック: Swift 6(strict concurrency)、SwiftUI `MenuBarExtra` App ターゲット +ローカル SPM パッケージ 1 つ(`MimizukuCore`)。捕捉は `AVAudioEngine`(マイク)と Core Audio process tap(システム音声)。保存はオンデバイスのみ(`~/Library/Application Support/` 配下)。
- 最小ターゲット: macOS 26.0、Apple Silicon 限定(ADR-0001)。

## 言語

- ユーザーとの会話: 日本語。
- **リポジトリにコミットする文書(規約・docs・ADR・コメント)は、開発中は日本語**で書く。README の英語版整備は公開前タスク(TODO(defer))。
- **PR タイトル**は Conventional Commits に従う。type は英語トークン(`feat` `fix` 等)、要約(summary)は日本語でよい。コード識別子は英語。
- 秘密情報・鍵・トークンはコミットしない。

## ハード制約(絶対に破らない。変更提案の前に必ず ADR を起票する)

1. **本リポジトリのどこにも private API を使わない。** App Store 適格性と OS 更新時の安定性を守るため、非公開 API に依存しない。
2. **音声と文字起こしはデバイス外に出さない。** 音声・文字起こしデータを運ぶネットワーク通信を行わない。既定でテレメトリを持たない。
3. **最小デプロイターゲット: macOS 26.0、Apple Silicon 限定**(ADR-0001)。
4. **Swift 6 言語モード、strict concurrency。** コード内コメントでの正当化理由とPR での言及なしに `@unchecked Sendable` を使わない。
5. **`Packages/*` は UI 非依存・TCC 非依存に保つ。** 権限や AppKit を要するものはApp ターゲットか、プロトコルの裏に置く。

既に他者の時間を奪った実績のあるドメイン上の罠(Core Audio taps・Speech・CI)は[`docs/domain-pitfalls.md`](./docs/domain-pitfalls.md) に集約。捕捉・文字起こしのコードに触れる前に必ず読む(再発見しない)。

## 検証(最重要ルール)

- 完了報告の前に必ず `just check` を実行し、green を確認する。`just check` は CI と同一内容。これが green でない作業は「完了」ではない。タスク一覧は `just --list`。
- `just check` は純ロジックのパッケージテストのみを実行する。**TCC 権限や実音声ハードウェア(マイク・システム音声 tap)を要するものは CI で実行できず、人間がローカルで検証する**(G-0004 と domain-pitfalls #8)。
- 非自明な変更は verifier サブエージェント(`/verify`)の第三者検証も通す。自分の仕事を自分だけで採点しない(手順: plan-execute-verify スキル)。

## 作業の始め方(Issue 起点)

- 実装・調査・修正は、対応する **GitHub Issue から始める**。無ければ着手前に起票する(流動的タスクの正典は Issue ―― 「知識の置き場所」参照)。会話の文脈や AI の auto-memory でタスクを管理しない(チームに共有されず失われるため)。
- ブランチは Issue 番号で切る: `<type>/<issue番号>-<短い説明>`。**1 Issue = 1 PR**(下記「ブランチとマージ」)。
- 実装計画のスライスは、[`docs/plan/IMPLEMENTATION_PLAN.md`](./docs/plan/IMPLEMENTATION_PLAN.md) の各スライス = 1 Issue として**事前に起票**しておく(着手時に Issue 番号でブランチを切れる状態にする)。
- 例外: リポジトリ setup や軽微な雑務など Issue 化の価値が薄いものは Issue 無しでよいが、その理由を PR 概要に書く。

## ブランチとマージ(理由と例外条件: G-0001)

- trunk-based development。変更は 短命ブランチ → PR → CI green → **squash merge** のみ。merge commit / rebase merge はリポジトリ設定で無効化する。
- PR タイトルは Conventional Commits 1.0.0 準拠(CI が検証)。ブランチ上の個々のコミット形式は自由。
- ブランチ名: `<type>/<issue番号>-<短い説明>`(例: `feat/12-mic-source`)。
- 1 Issue = 1 PR。PR は小さく保ち、マージ後のブランチは削除する。
- 1 PR = 実装 1 スライス。スライス順は[`docs/plan/IMPLEMENTATION_PLAN.md`](./docs/plan/IMPLEMENTATION_PLAN.md) に従い、勝手に並べ替えない。大きな変更の分割は G-0003。

## リリース(理由と release ブランチ導入条件: G-0002)

- main は常にリリース可能に保つ。リリースは release-please のリリース PR をマージしたときにのみ発生する(タグ + GitHub Release + CHANGELOG)。常設のrelease / 環境ブランチは持たない。
- 配布は Developer ID 署名 → notarize → staple → Homebrew cask。署名・notarizationの workflow はリリーススライス(Slice 4)で追加する。
- TCC プロンプトは正しく署名されたビルドでのみ出る。未署名成果物を配布しない(domain-pitfalls #4)。

## テスト方針

- テストフレームワークは Swift Testing(`import Testing`)。パッケージテストは各パッケージの `Tests/` に置く。
- モデル・エンコード・ルーティング・watchdog ロジックは CI で検証可能。アサーションのないテストや実装をなぞるだけのテストは書かない。
- 中核ロジックの変更には境界値・異常系のテストを必ず伴わせる。
- TCC / ハードウェア依存のテストはローカル限定。CI 経路から外す。

## 知識の置き場所

AI のメモリ(auto memory / `CLAUDE.local.md`)は個人ローカルであり、チームに共有されない。「他の人(やその AI)も知るべき」と思った瞬間に Git 管理ファイルへ書く。

| 知識の種類 | 置き場所 |
|---|---|
| 個人の揮発メモ・個人設定 | `CLAUDE.local.md` / auto memory(コミットしない) |
| チームの人間・AI 向け規約 | 本ファイル |
| 設計判断の理由 | `docs/adr/`(製品)/ `docs/adr/governance/`(プロセス) |
| ドメインの罠・落とし穴 | `docs/domain-pitfalls.md` |
| 流動的なタスク・調査ログ | GitHub Issues |
| 恒久的な仕様(利用者向け) | `README.md` |
| 恒久的な仕様(開発・設計向け) | `docs/` |

- 不変条件: **docs・コード・テストは同じ PR で一致させる**(乖離を後追いにしない)。
- 設計判断は実装の前(または同じ PR)で ADR に残す。手順: adr スキル / `/adr`。

## コミットと PR

- squash 後に main に残るのは「PR タイトル + squash 本文」だけ。what / why はそこに書く。PR 説明・レビューコメント・ブランチ上のコミット列は git 履歴に残らない前提で扱う。
- コミットしない: 署名証明書・プロビジョニング成果物・`.env`・録音音声・文字起こし。手順の詳細は commit-and-pr スキル。

## AI エージェントの作業規律

- 非自明な変更は、着手前に計画(対象・手順・検証方法・トレードオフ)を提示し、承認を得てから実行する。手順: plan-execute-verify スキル。
- 実行モードは承認駆動が既定。ループ実行の条件とガードレールは G-0004 ―― 特に**音声・TCC・ハードウェア依存の作業は承認駆動のみ**で、無人ループに委任しない。
- 規約・設定・docs に改善余地を見つけたら、勝手に変えず提案する。
- 秘密情報(`.env`・鍵・トークン)は読まない・書かない・コミットしない(permissions / hooks / CI gitleaks でも強制されるが、規律としても守る)。
