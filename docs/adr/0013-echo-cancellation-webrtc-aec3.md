# ADR-0013: エコーキャンセルは WebRTC AEC3 を採用し、処理後音声を録音・文字起こしの両方に使う

- ステータス: Accepted
- 日付: 2026-07-21
- 関連: #59(epic)/ #60(本判断)/ #61〜#64(実装スライス)/ ADR-0006(決定 1 を本 ADR で修正)/ docs/domain-pitfalls.md #12

番号について: ADR-0007〜0012 は実装計画の判断タスク D2〜D7 が予約済みのため、次の空き番号 0013 を使う。

## Context(背景)

会議等でスピーカー運用すると、システム音声(相手の声)がマイクへ回り込み、「自分」の議事ログに相手の発言が二重混入する。本アプリは会議利用が主用途であり、強力なエコーキャンセル(AEC)が必須要件となった。

本アプリ固有の好条件として、**AEC が必要とする far-end 参照信号(システム音声)を Core Audio process tap で既にクリーンなデジタル信号として取得している**(S3)。near-end(マイク)も取得済みで、ソフトウェア AEC の入力条件が揃っている。

検討した代替案(2026-07-21 に Web 調査 2 本を実施。一次情報の出典は #59 参照):

- **(a) Apple VPIO(`setVoiceProcessingEnabled`)**: S4 で実装・実測して撤退。VPIO はシステム全体で他アプリ音声をダッキングし、`duckingLevel: .min` でも tap の捕捉信号が約 20dB 減衰(実測: RMS 945 → 98)して「両方」モードのシステム文字起こしが死ぬ。完全無効化の公開手段は無い(WWDC23 10235 / API 仕様で確認)。却下(domain-pitfalls #12)。
- **(b) Voice Isolation マイクモード**: AUVoiceIO(= VPIO)採用が前提でありダッキング問題に逆戻り、かつユーザー制御(アプリから設定不可)、かつ「相手の声も音声として残す」ため原理的に本問題を解けない。却下。
- **(c) SpeexDSP(MDF)**: 公式マニュアルが「録音と再生が別サウンドカードでは動かない」と明言。マイクと出力デバイスが別クロックの本件構成でドリフト同期を自前実装する必要があり、品質も劣後。却下。
- **(d) NN ベース AEC(DTLN-aec、MIT)**: 用途一致・CoreML 先行事例あり・16kHz 動作。実用候補だが、AEC3 に業界実績(Chrome / PulseAudio)と 48kHz 対応で劣後。**AEC3 が AEC-1 のオフラインゲートで不合格になった場合の次候補**として温存。
- **(e) 文字起こし後のテキスト重複抑制**: ドリフト無関係で実装小だが、ASR 揺れによる取りこぼしと復唱の誤除去がある。信号レベルで解決すべき問題の後処理であり、単独解としては却下(AEC3 の実測後、残留があれば安全網として別途検討)。
- **(f) WebRTC audio_processing(AEC3)**: **採用**。理由は下記。

採用根拠:

- **ライセンス・費用**: BSD-3-Clause + 特許グラント(PATENTS)、無償。Apache-2.0 プロジェクトへの取り込みは ASF が公認(LEGAL-330)。義務は LICENSE / PATENTS の同梱・表示のみ。
- **実績**: Chrome / PulseAudio `module-echo-cancel` で長年の実運用。線形フィルタ + 非線形抑圧で 20〜40dB、遅延自動推定(数百 ms を吸収、1〜2 秒で収束)、NEON 最適化で CPU 負荷小。
- **同一構成の先行 OSS**: project-raven(macOS + システム音声 far-end + マイク + AEC3)が動作実績を示している。
- **入手性**: freedesktop 版 webrtc-audio-processing(v2.x、meson、活発にメンテ)。macOS arm64 xcframework のビルド前例あり。

## Decision(決定)

1. **WebRTC audio_processing(AEC3)を採用**する。有効化: AEC3・High Pass Filter・Noise Suppression。無効化: AGC・VAD・Beamforming。
2. **内部処理フォーマットは 48kHz / モノラル / 10ms(480 サンプル)固定**。参照(システム音声)はモノラルへダウンミックスして供給。毎 tick で `ProcessReverseStream()`(render)→ `ProcessStream()`(capture)の順序を厳守。
3. **処理後音声を文字起こしと録音の両方に使う**(mic.caf / mic.m4a は AEC + NS 処理後の音声になる)。**ADR-0006 の決定 1「native 品質で録音」をマイクストリームについて修正**する。システム音声ストリームの録音は従来どおり native。
4. **同期層を自前で持つ**(AEC 性能は同期精度で決まる)。ホストタイムスタンプ整列・双方リングバッファ・10ms フレーマ・ドリフト計測を `MimizukuCore` の純ロジックとして実装し CI でテストする。精密なレイテンシ推定(音波伝搬等)は行わない ―― AEC3 の遅延自動推定が吸収する範囲の粗整列で足りる。
5. **Swift から C++ を直接触らない**。Obj-C++(.mm)の `AudioProcessingBridge` で境界を切り、`AudioProcessor` プロトコルで抽象化する(将来の RNNoise / DeepFilterNet / Apple 純正 API への差し替え点)。APM とブリッジは App ターゲット、同期純ロジックは Core(Packages の UI/TCC 非依存規約を維持)。
6. **ベンダリング**: freedesktop webrtc-audio-processing を**ピン留めコミット**からビルドする `scripts/build-webrtc-apm.sh`(meson + ninja + abseil → arm64 静的ライブラリ。全 .a を `libwebrtc-apm-bundle.a` 1 本へ束ねる)。**ビルド成果物はコミットしない**(gitignore)。静的リンクされる全成分(WebRTC・abseil・rnnoise・pffft・Ooura fft)のライセンス原文を `third_party/` に同梱し、`third_party/README.md` を NOTICE の集約とする(AEC-1 の PR で追加)。
7. **段階ゲート**: ライブ統合(#63)の前に、実録音ペアによるオフライン実測(#61)で抑圧効果(目安 20dB 以上 + 試聴)を確認する。不合格なら統合へ進まず、DTLN-aec(代替案 d)を再評価する。

## Consequences(結果)

- 得るもの: スピーカー運用での二重混入の解消(会議用途の必須要件)。VPIO と違いダッキング副作用が無く、システム音声の聴取・捕捉・文字起こしと両立する。完全オンデバイス(ハード制約 2 を維持)。
- 失うもの・代償:
  - **C++ 依存とビルド複雑性**(meson / abseil / 静的ライブラリ)。ピン留めスクリプトと CI キャッシュで管理する。逃げ道として xcframework 配布フォークの一時利用が可能。
  - **マイク録音が処理済み音声になる**(NS 込みで帯域感が変わる)。原音が必要になった場合は AudioRouter の分岐で生録音の並行保存をオプション化できる(その際は ADR を更新)。
  - バージョン追従の保守負荷(freedesktop 版のリリースに追随)。
- リスクと監視条件:
  - **クロックドリフト**(マイクと出力デバイスが別クロック)による残留エコー。同期層 + オフラインゲートで検証し、AEC-3 の 60 分 soak を受け入れ条件とする。
  - CPU 目標 5% 以下 / 追加レイテンシ 20ms 以下(AEC-3 で計測)。
- 成立しなくなる条件: Apple がダッキングを伴わないシステムレベル AEC API を提供した場合は再評価する(`AudioProcessor` 抽象が差し替え点)。AEC3 がオフラインゲートで不合格の場合は DTLN-aec を再評価し、本 ADR を更新する。
