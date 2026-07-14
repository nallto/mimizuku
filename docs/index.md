# Mimizuku ドキュメント

Mimizuku は macOS のメニューバー常駐アプリ。マイクとシステム音声を録音し、Apple の Speechフレームワークで完全オンデバイスのリアルタイム文字起こしを行う。

このドキュメントは「設計の正」として、コードおよびテストと一致した状態を保ちながら育てる。実装前の計画書ではなく、**現在の仕様・設計判断**を記録する。

## 目次

### 設計・仕様

- [アーキテクチャ](./architecture.md) — コンポーネントとデータフロー
- [ドメインの落とし穴](./domain-pitfalls.md) — 検証済みの Core Audio / Speech / CI の罠
- [ADR](adr/README.md) — なぜその設計にしたか(製品 + 統治)

### 開発

- [開発ガイド](./development.md) — セットアップ・検証・CI・強制装置
- [実装計画](./plan/IMPLEMENTATION_PLAN.md) — 縦切りスライスと受け入れ条件
- [Claude Code kickoff](./plan/CLAUDE_CODE_KICKOFF.md) — 初回セッションに貼るプロンプト

## 関連

- `README.md`(リポジトリ直下)— 利用者向け入口
- `CHANGELOG.md`(リポジトリ直下)— リリースごとの変更点(release-please 自動生成)
- `AGENTS.md`(リポジトリ直下)— 規約の正典(人間 + AI)
