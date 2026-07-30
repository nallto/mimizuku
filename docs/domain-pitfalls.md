# ドメインの落とし穴

現実の報告で検証済み。再発見しないこと。AGENTS.md(ハード制約)と計画から参照される。捕捉・文字起こしのコードに触れる前に再読する。

## Core Audio process taps(システム音声捕捉、macOS 14.2+ API)

- **#1 排他フラグの反転。** `CATapDescription(stereoGlobalTapButExcludeProcesses:)` は排他性を自動設定する。後から `isExclusive` を変更すると意味が反転し(「列挙 PID 以外すべて」→「列挙 PID のみ」)、無音になる。このイニシャライザの後で `isExclusive` に触らない。
- **#2 AVAudioEngine を tap 付き aggregate device に向け直せない。** デバイス設定は `noErr` を返すが、エンジンは既定入力を読み続ける。aggregate は `AudioDeviceCreateIOProcIDWithBlock`で直接消費する ―― AVAudioEngine ではない。
- **#3 長時間セッションのゼロサンプル劣化。** IOProc は正常に発火し続けるのに、サンプルがすべて厳密に `0.0f` になることがある。回復には process tap と aggregate device の**両方**を破棄・再作成する必要がある。IOProc の再起動だけでは直らない。`AudioSource` 実装はこれを検知して**ソース内部で**両方を破棄・再作成し、ストリームは切らずに継続する(S3 のゼロサンプル watchdog)。正当な無音と劣化はソースから区別できないため、発火間隔はバックオフさせ、無音だけではセッションを殺さない(`ZeroSampleWatchdog`)。
- **#4 TCC プロンプトは署名済みバイナリでのみ出る。** `NSAudioCaptureUsageDescription` のプロンプトは正しく署名されたビルドでのみ表示される。未署名 / ad-hoc デバッグビルドでは無言で何も録れないことがある。「音が録れない」の調査前に署名を確認する。

## SpeechAnalyzer / SpeechTranscriber(macOS 26+)

- **#5 モデルアセットはロケール単位で大きい。** 数百 MB。初回利用前に `AssetInventory` で導入を保証する必要がある。オンデマンドではなくアプリ起動時にバックグラウンドでダウンロードし、初回利用がダウンロードでブロックしないようにする。
- **#6 volatile と final。** `.volatileResults` は暫定セグメントを生み、後で確定版に置き換わる。確定セグメントのみwrite-throughジャーナルへ永続化し、volatileは薄く(dimmed)描画する。利用者の停止でセッションTask全体を即時cancelすると最後のvolatileが確定する機会を失うため、入力ストリームだけを正常終了させて`finalizeAndFinishThroughEndOfInput()`と結果列の完了を待つ。5秒を超えた場合だけTaskをcancelし、メモリ上の最後のvolatileを未完了末尾としてスナップショットへ残す(#38)。
- **#11 完全無音の入力から幻聴セグメントが出る。** 厳密ゼロのバッファ(システム音声 tap の無音)を供給し続けると、SpeechTranscriber が短い幻聴セグメント(「あ」1 文字等)を確定として生成することがある(S3 実装時に実機で観測、再現性あり)。厳密ゼロのバッファは解析へ供給しない。ただし単純にスキップすると解析タイムラインが圧縮されて `audioTimeRange` が録音とずれるため、**全バッファに `AnalyzerInput(buffer:bufferStartTime:)` で開始時刻を明示**して供給する。マイクはノイズフロアで厳密ゼロにならないため影響しない。さらに、スキップしたままだと認識器が発話終端の無音を観測できず **volatile が確定しないまま残る**(動画停止 = 完全無音で灰色行が残り続ける。#63 実機で観測)。ゼロ連続が閾値(1 秒)を超えたら `SpeechAnalyzer.finalize(through:)` で保留結果を明示的に確定させる。

- **#7 話者 diarization は無い(ただしマイク / システムの区別は保持される)。** 2 階層を分けて考える。(1) ストリーム同一性 ―― 音声がマイク由来かシステム音声 tap 由来かは常に判別可能で、`TranscriptSegment.stream`(`.microphone` / `.systemAudio`)に必ず載る。「自分 vs 相手」の振り分けや、並列表示・チャット形式表示はこの 1 フィールドで実現できる(将来チャット形式にしても、どちらのストリーム由来かは失われない)。(2) diarization ―― 1 つのストリーム内で複数話者を区別する機能は無い(例: システム音声に相手 A・B・C が混在していても分離できない)。UI や docs では「自分 / 相手」までは表明してよいが、相手側の話者分離は主張しない。

## AVAudioEngine(マイク捕捉)

- **#10 捕捉開始前の `inputNode.outputFormat(forBus:)` 事前照会はクラッシュしうる。** 使い捨ての `AVAudioEngine()` を作って init 時(MainActor 上)にフォーマットを先取りしたところ、`AVAudioIONodeImpl::GetOutputFormat` 内でクラッシュした(S2 実装時に実機で観測)。ハードウェア照会は `buffers()` 内で実際に使うエンジンに対してのみ行い、下流(録音ファイル・変換器)は**最初のバッファの `format` から遅延確定**させる(`AudioFileWriter` の遅延オープン、`AudioRouter` の遅延変換器生成)。HAL への同期照会は main thread では行わない。

- **#12 voice processing(VPIO の AEC)はシステム音声 tap と両立しない。** スピーカー再生音がマイクへ回り込む(「自分」として二重に文字起こしされる)対策に`inputNode.setVoiceProcessingEnabled(true)` を試したところ、次の 2 つが実機で判明した(S4)。(1) VPIO は**システム全体で他アプリ音声をダッキング**し、`voiceProcessingOtherAudioDuckingConfiguration` を `.min` にしても process tap の捕捉信号が約 20dB 減衰する(耳には「少し小さい」程度でも文字起こしには実質無音 ―― tap はダッキング後の信号を拾う)。FaceTime 等が AEC と相手音声を両立できるのは相手音声を自分の VPIO 出力から再生しているためで、他アプリの音を tap で拾う本アプリでは同じ手が使えない。(2) VPIO 有効化で入力フォーマットが多チャンネル化することがある(実測: 5ch Int16 discrete・全チャンネルがビット同一の複製。5ch discrete の CAF は AAC 変換できない)。結論: **VPIO の AEC は採用しない**。回り込み対策は **ソフトウェア AEC(WebRTC AEC3)を自前の同期層越しに適用**する方式へ移行した(ADR-0013、#59 で解決)。VPIO と違いシステム音声 tap をダッキングしないため両立する。

- **#13 マイク単体モードの AEC は「隠しシステム音声 tap」を要し、システム音声 TCC と結合する(AEC-4 / #64 / ADR-0014)。** WebRTC AEC3 は near-end(マイク)を消すために far-end 参照(スピーカー出力 = システム音声)を必要とする。そのため「マイクのみ」モードでも回り込みを消すには、録音・文字起こしに出さない参照専用の system tap を裏で起動する。帰結として、**マイク単体モードの初回起動でシステム音声の TCC プロンプトが出る**(ユーザーがマイクだけ選んでいてもシステム音声許可を求められる ―― 用途説明でカバー)。マイク原音にはシステム音声が回り込み得るため、参照 tap が使えない場合に原音へフォールバックしてはいけない。初回 render 前と復旧中は原音を同長の無音へ置換し、5 秒以内に開始・復旧できなければセッションを失敗させる。診断表示は「参照待ち / 有効 / 復旧中 / 失敗」とする(#76)。

  - **参照 tap の直前に process tap を事前プローブしてはいけない(実機で回り込みが残った)。** 可用性判定のつもりで `SystemAudioProbe`(`AudioHardwareCreateProcessTap` → 即 `Destroy`)を挟むと、その直後に作る本番の参照 tap が**無音になり AEC が何も打ち消せない**(診断は「有効」表示のまま回り込みが「自分」に混入する)。両方モードには事前プローブが無く打ち消せている ―― これが唯一の構造差だった。参照 tap は遅延ソースの中で**直接起動**し、両方モードと同一経路(本番 tap を直接消費)に揃える(create→destroy→create の連続が tap を壊す。#3 のゼロサンプル系と同根)。
  - **参照未着のcaptureを保留し続けたり、原音bypassで救済してはいけない。** 保留は参照沈黙時に全損・恒久遅延を招き、原音bypassはシステム音声を正式なマイク音源へ混入させる。初回render前のcaptureは即時に同長の無音へ置換して時間軸だけを維持し、到着と独立したwatchdogで5秒後に開始失敗させる。終了時drainはwatchdogと別APIにし、状態遷移や失敗通知を発生させない(#74 / #76)。
  - **初回 render 到着後に、参照開始前の capture を APM へ遡及投入してはいけない。** 両方モードはマイク側ルーターが先に起動し、system tap が約 +1.2 秒遅れることがある。対応参照のないnear-endを先にAPMへ流すと初期収束を崩す。開始前captureは原音を無音へ置換し、参照開始後のcaptureからAECを開始する。actorへの到着順は入れ替わるため、初回renderのhost timeより古いcaptureも同様に無音化する。診断の「有効」は最初のcaptureを実際にAPMへ入れた後に表示する(#76)。
  - **render一時停止時に無音参照でcaptureをAPMへ通し続けてはいけない。** 形式上は処理済みでもAECが打ち消せない原音相当になり得る。対応renderを200ms待っても得られなければrecoveringへ移り、マイク原音を同長の無音へ置換する。renderが戻ったらAPM・aligner・render framerを新しい同期epochへリセットし、5秒以内に戻らなければセッションを失敗させる。capture framerはリセットせず、復旧境界を跨ぐフレームをhost timeで無音化して10ms未満の欠落も避ける。隠し参照tapのストリーム終了は500ms backoffで新しいtapを生成して復旧を試す(#76)。
  - **system tap がマイクより「先に」起動すると、先行 render が貯まって AEC3 が打ち消せない(両方モードでも起動順で発生。実機で確認)。** 通常は tap がマイクの +1.2 秒後に起動するが、起動順は環境で入れ替わる。tap 先行だとマイク到着までに render が貯まり、最初の capture 供給時に**貯まった全 render を一気に APM へ流す** → AEC3 から見た far-end↔near-end 遅延が探索窓を超え、エコー遅延を推定できず**打ち消せない**(テレメトリ上は同期健全:filled=0・droppedRender=0 なのに実機で回り込みが残る。録音の回帰係数 α で 0.34 = 漏れ、マイク先行時は 0.02〜0.08)。`AecAligner.maxRenderLead`(既定 0.25 秒)で **capture より先行しすぎる render を APM に流さず捨て**、先行量を AEC3 の窓内に抑える(既存の「render 未開始まで capture を流さない」= capture 先行対策の**対称版**。診断は `aec finished` の `leadDropped` に出る)。

## CI

- **#8 ホスト型ランナーは TCC 権限を付与できない。** マイクやシステム音声 tap に触れるものはすべてローカル限定。CI は `macos-26` ランナーで純ロジックのパッケージテストを実行する。音声/権限挙動を「CI で検証した」という主張は定義上偽 ―― 代わりにローカル実行ログを要求する。

## Swift 6 concurrency

- **#9 `AVAudioPCMBuffer` は `Sendable` ではない。** アクター/ストリーム境界を跨ぐと、明示的なコピーか `sending` の判断が必要になる。実装時に明示的に解決し、正当化理由を書かずに`@unchecked Sendable` で覆い隠さない(ハード制約 #4)。
