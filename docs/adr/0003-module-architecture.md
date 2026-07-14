# ADR-0003: App ターゲット + ローカル SPM パッケージ 1 つ(MimizukuCore)で開始し、契約で疎結合に保つ

- ステータス: Accepted
- 日付: 2026-07-10(2026-07-13 に単一パッケージ開始へ改訂)

## Context(背景)

モジュール構成を規定する 2 つの力:

1. **CI は TCC 権限を付与できない。** ホスト型ランナーはマイクやシステム音声 tap を決して実行できないため、テスト可能なロジックを権限依存の I/O から分離する必要がある。
2. **リアルタイム要件。** 文字起こしはファイルではなくライブストリームを消費する。捕捉と文字起こしは別スライスで作られ、互いをブロックしない。両者の間の契約を先に固定する。

これを根拠に **2 パッケージ**(捕捉層 / 文字起こし層)へ分割する案も検討したが、次の理由から **単一パッケージ開始**を採る:

- 小規模アプリに 2 パッケージ + App ターゲットはやや重い。
- 捕捉層と文字起こし層の結合は共有型(`StreamKind`)のみで薄く、分割の実益が現時点では小さい。
- **契約(protocol)さえ固定できていれば**、後から捕捉層を別パッケージへ切り出すのは低コスト(型を別モジュールへ移すだけ)。初期の軽さを優先し、必要になった時点で割る。

## Decision(決定)

```
┌──────────────────────────────────────────────────────┐
│ Mimizuku(Xcode App ターゲット)                      │
│  SwiftUI MenuBarExtra、設定、TCC オンボーディング、    │
│  AudioRouter(ファンアウト)、ライブ議事ログ UI、       │
│  JSONL/TXT エクスポート                               │
└───────────────┬──────────────────────────────────────┘
                │ AudioSource / TranscriptionEngine(契約)
┌───────────────▼──────────────────────────────────────┐
│ MimizukuCore(ローカル SPM パッケージ・単一)          │
│  AudioSource / StreamKind                             │
│  TranscriptionEngine / TranscriptSegment              │
│  実装(Mic/SystemTap source, SpeechEngine, watchdog)  │
└──────────────────────────────────────────────────────┘
```

- 当面はローカル SPM パッケージ 1 つ(`MimizukuCore`)。UI 非依存・TCC 非依存に保つ。
- 契約(コードで stub 済み):
  - `AudioSource`: cold・単一消費者の `AsyncThrowingStream<AVAudioPCMBuffer, Error>` + `format` + `kind`。
  - `TranscriptionEngine`: `prepare(locale:)` + `segments(from:) -> AsyncThrowingStream<...>`。
- ファンアウト(1 捕捉ストリームを文字起こしと任意のファイル録音へ)は App ターゲットの`AudioRouter` が持つ。ソースは単一消費者のまま。
- 話者帰属 = ストリーム同一性。マイク / systemAudio の 2 エンジンセッションを並行実行し、UI がウォールクロックでマージする。

## Consequences(結果)

- (+) `swift test` がモデル・エンコード・ルーティング・watchdog ロジックを TCC なしで CI 検証。権限依存の経路は薄く、ローカル検証。
- (+) `TranscriptionEngine` は差し替え可能(fake engine で UI テスト、将来のエンジン変更が捕捉コードに波及しない)。
- (+) 単一パッケージで初期の構成が軽い。契約が固定されているため、後の分割は型の移動で済む。
- (−) `AVAudioPCMBuffer` は `Sendable` でないため、ストリーム契約は実装時に明示的なコピー/`sending` 判断を迫る(`AudioSource.swift` に記載)。`@unchecked Sendable` で無言に解決しない。

## 2 パッケージへ分割する条件(該当したら新 ADR で移行を決定)

1. 捕捉層または文字起こし層が独立してリリース/再利用される必要が出た。
2. ビルド時間やモジュール境界の都合で、分割の実益がコストを上回った。
