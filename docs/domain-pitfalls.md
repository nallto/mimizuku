# ドメインの落とし穴

現実の報告で検証済み。再発見しないこと。AGENTS.md(ハード制約)と計画から参照される。捕捉・文字起こしのコードに触れる前に再読する。

## Core Audio process taps(システム音声捕捉、macOS 14.2+ API)

1. **排他フラグの反転。** `CATapDescription(stereoGlobalTapButExcludeProcesses:)` は排他性を自動設定する。後から `isExclusive` を変更すると意味が反転し(「列挙 PID 以外すべて」→「列挙 PID のみ」)、無音になる。このイニシャライザの後で `isExclusive` に触らない。
2. **AVAudioEngine を tap 付き aggregate device に向け直せない。** デバイス設定は `noErr` を返すが、エンジンは既定入力を読み続ける。aggregate は `AudioDeviceCreateIOProcIDWithBlock`で直接消費する ―― AVAudioEngine ではない。
3. **長時間セッションのゼロサンプル劣化。** IOProc は正常に発火し続けるのに、サンプルがすべて厳密に `0.0f` になることがある。回復には process tap と aggregate device の**両方**を破棄・再作成する必要がある。IOProc の再起動だけでは直らない。`AudioSource` 実装はこれを検知して error として表面化させ、ルーターが完全再構築を起動できるようにする(S3 のゼロサンプル watchdog)。
4. **TCC プロンプトは署名済みバイナリでのみ出る。** `NSAudioCaptureUsageDescription` のプロンプトは正しく署名されたビルドでのみ表示される。未署名 / ad-hoc デバッグビルドでは無言で何も録れないことがある。「音が録れない」の調査前に署名を確認する。

## SpeechAnalyzer / SpeechTranscriber(macOS 26+)

5. **モデルアセットはロケール単位で大きい。** 数百 MB。初回利用前に `AssetInventory` で導入を保証する必要がある。オンデマンドではなくアプリ起動時にバックグラウンドでダウンロードし、初回利用がダウンロードでブロックしないようにする。
6. **volatile と final。** `.volatileResults` は暫定セグメントを生み、後で確定版に置き換わる。確定セグメントのみ永続化し、volatile は薄く(dimmed)描画する。
7. **話者 diarization は無い(ただしマイク / システムの区別は保持される)。** 2 階層を分けて考える。(1) ストリーム同一性 ―― 音声がマイク由来かシステム音声 tap 由来かは常に判別可能で、`TranscriptSegment.stream`(`.microphone` / `.systemAudio`)に必ず載る。「自分 vs 相手」の振り分けや、並列表示・チャット形式表示はこの 1 フィールドで実現できる(将来チャット形式にしても、どちらのストリーム由来かは失われない)。(2) diarization ―― 1 つのストリーム内で複数話者を区別する機能は無い(例: システム音声に相手 A・B・C が混在していても分離できない)。UI や docs では「自分 / 相手」までは表明してよいが、相手側の話者分離は主張しない。

## AVAudioEngine(マイク捕捉)

10. **捕捉開始前の `inputNode.outputFormat(forBus:)` 事前照会はクラッシュしうる。** 使い捨ての `AVAudioEngine()` を作って init 時(MainActor 上)にフォーマットを先取りしたところ、`AVAudioIONodeImpl::GetOutputFormat` 内でクラッシュした(S2 実装時に実機で観測)。ハードウェア照会は `buffers()` 内で実際に使うエンジンに対してのみ行い、下流(録音ファイル・変換器)は**最初のバッファの `format` から遅延確定**させる(`AudioFileWriter` の遅延オープン、`AudioRouter` の遅延変換器生成)。HAL への同期照会は main thread では行わない。

## CI

8. **ホスト型ランナーは TCC 権限を付与できない。** マイクやシステム音声 tap に触れるものはすべてローカル限定。CI は `macos-26` ランナーで純ロジックのパッケージテストを実行する。音声/権限挙動を「CI で検証した」という主張は定義上偽 ―― 代わりにローカル実行ログを要求する。

## Swift 6 concurrency

9. **`AVAudioPCMBuffer` は `Sendable` ではない。** アクター/ストリーム境界を跨ぐと、明示的なコピーか `sending` の判断が必要になる。実装時に明示的に解決し、正当化理由を書かずに`@unchecked Sendable` で覆い隠さない(ハード制約 #4)。
