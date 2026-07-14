# アーキテクチャ

Mimizuku の現在の設計とデータフロー。これは「設計の正」であり、コードおよびテストと一致した状態に保つ。根拠は ADR-0003。

## 全体像

2 つの音声ストリーム(`AVAudioEngine` によるマイク、Core Audio process tap によるシステム出力)を捕捉し、ソースで文字起こし器の推奨フォーマットへ変換して、2 つの並行する`SpeechAnalyzer` / `SpeechTranscriber` セッションに流す。両ストリームの認識セグメントをアプリ側で 1 本のウォールクロックのタイムラインにマージし、ライブの追記型議事ログとして描画する。すべてオンデバイスで、ネットワークには何も送らない。

```text
   ┌──────────────────────────────────────────────────────┐
   │ Mimizuku(Xcode App ターゲット)                     │
   │  SwiftUI MenuBarExtra、設定、TCC オンボーディング、    │
   │  AudioRouter(ファンアウト: エンジン + 任意の録音)、   │
   │  ライブ議事ログ UI、JSONL/TXT エクスポート            │
   └───────────────┬──────────────────────────────────────┘
                   │ AudioSource / TranscriptionEngine(契約)
   ┌───────────────▼──────────────────────────────────────┐
   │ MimizukuCore(ローカル SPM パッケージ)                │
   │  AudioSource / StreamKind(捕捉契約)                  │
   │  TranscriptionEngine / TranscriptSegment(文字起こし契約)│
   │  ※ 実装(MicrophoneSource, SystemAudioTapSource,      │
   │     SpeechEngine, format 変換, ゼロサンプル watchdog)  │
   │     は各スライスで追加。契約は先に固定する。            │
   └──────────────────────────────────────────────────────┘
```

> パッケージ構成: 当面は単一パッケージ `MimizukuCore` で開始する。捕捉と文字起こしを別
> パッケージに分割する必要が生じたら、その時点で分割する(ADR-0003)。分割しても契約
> (AudioSource / TranscriptionEngine)はそのまま移せるよう、両者は互いに疎結合を保つ。

## コンポーネント

| 場所 | 役割 | 動作環境 |
|---|---|---|
| `Mimizuku/`(App ターゲット) | UI、配線、TCC オンボーディング、AudioRouter、エクスポート | macOS 26、署名済みアプリ |
| `Packages/MimizukuCore` | マイク+システム音声捕捉、文字起こしラッパ、モデル管理、契約 | UI 非依存・TCC 非依存のライブラリ |

## 主要な契約(安易に変えない。捕捉と文字起こしを疎結合にする)

- `MimizukuCore.AudioSource` — cold・単一消費者の`AsyncThrowingStream<AVAudioPCMBuffer, Error>` + `format` + `kind`。
- `MimizukuCore.TranscriptionEngine` / `TranscriptSegment` — `prepare(locale:)` + `segments(from:)`。テストで fake engine を使い、エンジンを差し替え可能にするため、Speech 型を含めない。
- ファンアウト(1 捕捉ストリームを文字起こしと任意のファイル録音へ)は App ターゲットの`AudioRouter` が担う。ソースは単一消費者のまま。
- 話者帰属 = ストリーム同一性(domain-pitfalls #7 を参照)。

## ディレクトリ構成

```text
mimizuku/
├── AGENTS.md            # 規約(SSOT)
├── CLAUDE.md            # Claude Code 用 import(@AGENTS.md)
├── justfile             # 検証の単一入口(just check = CI)
├── mise.toml            # ツール版数の SSOT(補助ツール)
├── .claude/             # permissions / hooks / skills / commands / verifier
├── docs/                # 設計 docs、ADR、ドメイン落とし穴、計画
├── Packages/            # MimizukuCore(ローカル SPM)
└── Mimizuku/            # Xcode App ターゲット(Slice 0 で作成)
```
