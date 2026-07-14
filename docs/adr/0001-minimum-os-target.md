# ADR-0001: 最小デプロイターゲットは macOS 26(Tahoe)、Apple Silicon 限定

- ステータス: Accepted
- 日付: 2026-07-10(2026-07-13 に方針再確認)

## Context(背景)

本製品の核は、2 つの音声ストリーム(マイク + システム音声)のリアルタイム・完全オンデバイス文字起こし。

- Apple フレームワークでのリアルタイム・オンデバイス文字起こしは `SpeechAnalyzer` / `SpeechTranscriber`(Speech framework、macOS 26 / iOS 26 以降)を要する。旧来の`SFSpeechRecognizer` は、長尺・低遅延・日本語品質の文字起こしの現実的な代替にならない(短時間ディクテーション向け)。
- システム音声捕捉は Core Audio process taps(`CATapDescription` + `AudioHardwareCreateProcessTap`、macOS 14.2 以降)を要する。これは律速ではない。律速は Speech。
- `SpeechTranscriber` はハードウェア依存で、OS 26 でも `isAvailable == false` を返す端末がありうる(コミュニティ分析では 16 コア Neural Engine と相関)。Mac では全 Apple Silicon 機が条件を満たす見込み。Intel Mac は対象外。
- GitHub ホスト型 `macos-26`(Apple Silicon)ランナーは GA 済み(2026-02-26)。CI がデプロイターゲットに一致する。

これは技術判断であると同時に製品戦略の賭けでもある。macOS 26 は登場から日が浅く、OSS 公開時の到達ユーザーを絞る。方針の再確認(2026-07-13): **「広く配る」より「自分と近い環境で最高品質」を優先する**とユーザーが確定。この前提で macOS 26 限定を維持する。

## Decision(決定)

- `MACOSX_DEPLOYMENT_TARGET = 26.0`(App と全パッケージ)。
- Apple Silicon(arm64)のみ。Intel スライス・Rosetta 対応の主張はしない。
- 起動時に `SpeechTranscriber` の可用性を実行時チェックし、利用不可ならクラッシュせず実行可能なエラー表示を出す。

## Consequences(結果)

- (+) 単一コードパス: Speech API の可用性分岐が不要、Swift 6 ツールチェーン前提が全域で成立、CI が本番を反映。
- (−) macOS ≤ 15 と Intel Mac のユーザーを除外。OSS としては母数が縮む。README の最初の画面で要件を明示し、誤インストールを防ぐ。
- (−) 初期 OS の API 不安定リスク: 既知の process-tap 劣化(長時間セッションのゼロサンプル化)はOS 修正を待たずアプリ内で対処する(domain-pitfalls #3)。

## Alternatives considered(検討した代替案)

- **macOS 14.4+ + whisper.cpp**
  OS-26 制約を外せるが「Apple フレームワーク・同梱モデルなし」の設計目標を捨て、GGML モデル配布と GPU/ANE チューニングの負担が増える。却下。
- **macOS 26 + `DictationTranscriber` フォールバックで旧ハード対応**
  列挙できないハードウェアクラスのために品質階層とテスト行列が増える。具体的なユーザー報告が出るまで却下。
