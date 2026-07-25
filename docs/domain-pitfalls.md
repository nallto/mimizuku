# ドメインの落とし穴

現実の報告で検証済み。再発見しないこと。AGENTS.md(ハード制約)と計画から参照される。捕捉・文字起こしのコードに触れる前に再読する。

## Core Audio process taps(システム音声捕捉、macOS 14.2+ API)

1. **排他フラグの反転。** `CATapDescription(stereoGlobalTapButExcludeProcesses:)` は排他性を自動設定する。後から `isExclusive` を変更すると意味が反転し(「列挙 PID 以外すべて」→「列挙 PID のみ」)、無音になる。このイニシャライザの後で `isExclusive` に触らない。
2. **AVAudioEngine を tap 付き aggregate device に向け直せない。** デバイス設定は `noErr` を返すが、エンジンは既定入力を読み続ける。aggregate は `AudioDeviceCreateIOProcIDWithBlock`で直接消費する ―― AVAudioEngine ではない。
3. **長時間セッションのゼロサンプル劣化。** IOProc は正常に発火し続けるのに、サンプルがすべて厳密に `0.0f` になることがある。回復には process tap と aggregate device の**両方**を破棄・再作成する必要がある。IOProc の再起動だけでは直らない。`AudioSource` 実装はこれを検知して**ソース内部で**両方を破棄・再作成し、ストリームは切らずに継続する(S3 のゼロサンプル watchdog)。正当な無音と劣化はソースから区別できないため、発火間隔はバックオフさせ、無音だけではセッションを殺さない(`ZeroSampleWatchdog`)。
4. **TCC プロンプトは署名済みバイナリでのみ出る。** `NSAudioCaptureUsageDescription` のプロンプトは正しく署名されたビルドでのみ表示される。未署名 / ad-hoc デバッグビルドでは無言で何も録れないことがある。「音が録れない」の調査前に署名を確認する。

## SpeechAnalyzer / SpeechTranscriber(macOS 26+)

5. **モデルアセットはロケール単位で大きい。** 数百 MB。初回利用前に `AssetInventory` で導入を保証する必要がある。オンデマンドではなくアプリ起動時にバックグラウンドでダウンロードし、初回利用がダウンロードでブロックしないようにする。
6. **volatile と final。** `.volatileResults` は暫定セグメントを生み、後で確定版に置き換わる。確定セグメントのみ永続化し、volatile は薄く(dimmed)描画する。
11. **完全無音の入力から幻聴セグメントが出る。** 厳密ゼロのバッファ(システム音声 tap の無音)を供給し続けると、SpeechTranscriber が短い幻聴セグメント(「あ」1 文字等)を確定として生成することがある(S3 実装時に実機で観測、再現性あり)。厳密ゼロのバッファは解析へ供給しない。ただし単純にスキップすると解析タイムラインが圧縮されて `audioTimeRange` が録音とずれるため、**全バッファに `AnalyzerInput(buffer:bufferStartTime:)` で開始時刻を明示**して供給する。マイクはノイズフロアで厳密ゼロにならないため影響しない。さらに、スキップしたままだと認識器が発話終端の無音を観測できず **volatile が確定しないまま残る**(動画停止 = 完全無音で灰色行が残り続ける。#63 実機で観測)。ゼロ連続が閾値(1 秒)を超えたら `SpeechAnalyzer.finalize(through:)` で保留結果を明示的に確定させる。

7. **話者 diarization は無い(ただしマイク / システムの区別は保持される)。** 2 階層を分けて考える。(1) ストリーム同一性 ―― 音声がマイク由来かシステム音声 tap 由来かは常に判別可能で、`TranscriptSegment.stream`(`.microphone` / `.systemAudio`)に必ず載る。「自分 vs 相手」の振り分けや、並列表示・チャット形式表示はこの 1 フィールドで実現できる(将来チャット形式にしても、どちらのストリーム由来かは失われない)。(2) diarization ―― 1 つのストリーム内で複数話者を区別する機能は無い(例: システム音声に相手 A・B・C が混在していても分離できない)。UI や docs では「自分 / 相手」までは表明してよいが、相手側の話者分離は主張しない。

## AVAudioEngine(マイク捕捉)

10. **捕捉開始前の `inputNode.outputFormat(forBus:)` 事前照会はクラッシュしうる。** 使い捨ての `AVAudioEngine()` を作って init 時(MainActor 上)にフォーマットを先取りしたところ、`AVAudioIONodeImpl::GetOutputFormat` 内でクラッシュした(S2 実装時に実機で観測)。ハードウェア照会は `buffers()` 内で実際に使うエンジンに対してのみ行い、下流(録音ファイル・変換器)は**最初のバッファの `format` から遅延確定**させる(`AudioFileWriter` の遅延オープン、`AudioRouter` の遅延変換器生成)。HAL への同期照会は main thread では行わない。

12. **voice processing(VPIO の AEC)はシステム音声 tap と両立しない。** スピーカー再生音がマイクへ回り込む(「自分」として二重に文字起こしされる)対策に`inputNode.setVoiceProcessingEnabled(true)` を試したところ、次の 2 つが実機で判明した(S4)。(1) VPIO は**システム全体で他アプリ音声をダッキング**し、`voiceProcessingOtherAudioDuckingConfiguration` を `.min` にしても process tap の捕捉信号が約 20dB 減衰する(耳には「少し小さい」程度でも文字起こしには実質無音 ―― tap はダッキング後の信号を拾う)。FaceTime 等が AEC と相手音声を両立できるのは相手音声を自分の VPIO 出力から再生しているためで、他アプリの音を tap で拾う本アプリでは同じ手が使えない。(2) VPIO 有効化で入力フォーマットが多チャンネル化することがある(実測: 5ch Int16 discrete・全チャンネルがビット同一の複製。5ch discrete の CAF は AAC 変換できない)。結論: **VPIO の AEC は採用しない**。回り込み対策は **ソフトウェア AEC(WebRTC AEC3)を自前の同期層越しに適用**する方式へ移行した(ADR-0013、#59 で解決)。VPIO と違いシステム音声 tap をダッキングしないため両立する。

13. **マイク単体モードの AEC は「隠しシステム音声 tap」を要し、システム音声 TCC と結合する(AEC-4 / #64)。** WebRTC AEC3 は near-end(マイク)を消すために far-end 参照(スピーカー出力 = システム音声)を必要とする。そのため「マイクのみ」モードでも回り込みを消すには、録音・文字起こしに出さない参照専用の system tap を裏で起動する。帰結として、**マイク単体モードの初回起動でシステム音声の TCC プロンプトが出る**(ユーザーがマイクだけ選んでいてもシステム音声許可を求められる ―― 用途説明でカバー)。参照 tap が使えない(未許可・沈黙)場合は AEC が打ち消さないだけで、マイク録音・文字起こしは後述の安全弁で実時間継続する(graceful degradation)。診断表示は楽観的に「有効」とし、参照の実状態は権限診断の「システム音声」行で確認する。

    - **参照 tap の直前に process tap を事前プローブしてはいけない(実機で回り込みが残った)。** 可用性判定のつもりで `SystemAudioProbe`(`AudioHardwareCreateProcessTap` → 即 `Destroy`)を挟むと、その直後に作る本番の参照 tap が**無音になり AEC が何も打ち消せない**(診断は「有効」表示のまま回り込みが「自分」に混入する)。両方モードには事前プローブが無く打ち消せている ―― これが唯一の構造差だった。参照 tap は遅延ソースの中で**直接起動**し、両方モードと同一経路(本番 tap を直接消費)に揃える(create→destroy→create の連続が tap を壊す。#3 のゼロサンプル系と同根)。
    - **給餌スケジューラの「参照未着なら capture を APM に入れない」ゲートで、参照沈黙時にマイクが全損しうる。** `AecFeedScheduler` はこのゲートを持つ(#63 の 3 パターン分岐対策)。参照 tap が沈黙(IOProc 未発火)するとゲートで capture が永遠に保留され、**マイク発話がほぼ全損する**(セッション末に flush されるだけ)。`renderStartGrace`(既定 3 秒 ―― 両方モードの tap 起動遅延 +1.2 秒より十分大きく取り正常時は誤発動しない)を超えたら参照なしで実時間素通し解放する安全弁を必ず持たせる(#70 と同根)。

## CI

8. **ホスト型ランナーは TCC 権限を付与できない。** マイクやシステム音声 tap に触れるものはすべてローカル限定。CI は `macos-26` ランナーで純ロジックのパッケージテストを実行する。音声/権限挙動を「CI で検証した」という主張は定義上偽 ―― 代わりにローカル実行ログを要求する。

## Swift 6 concurrency

9. **`AVAudioPCMBuffer` は `Sendable` ではない。** アクター/ストリーム境界を跨ぐと、明示的なコピーか `sending` の判断が必要になる。実装時に明示的に解決し、正当化理由を書かずに`@unchecked Sendable` で覆い隠さない(ハード制約 #4)。
