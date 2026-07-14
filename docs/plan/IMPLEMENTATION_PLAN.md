# 実装計画

確定済みのスコープ判断(蒸し返さない。ADR 参照):

- 順序: 音声 + 文字起こしを最優先で進める。
- 配布: OSS 公開、Developer ID + notarization(当面 App Store ではない)。
- 利用形態: リアルタイム文字起こし(録音後一括ではなく、ライブ更新の議事ログ)。副次的にセッションのディスク録音。
- 最小ターゲット: macOS 26、Apple Silicon(ADR-0001)。
- 構成: App ターゲット + 単一 SPM パッケージ `MimizukuCore`(ADR-0003)。契約は先に固定し、必要になったら分割する。

ビルド順序は**縦切りスライス**。マイル→マイルではなく、マイク→文字起こしの薄い経路をまず端から端まで通し、そこから広げる。最もリスクの高い統合(Speech ストリーミング)を前倒しし、未検証の消費側に対して捕捉の配管を作る事態を避ける。

---

## Slice 0 — リポジトリ立ち上げ

タスク:

1. 名称は `Mimizuku`(確定。正式な商標クリアランスは保留、ADR-0002)。旧仮名の残存が無いか確認: `grep -ri menuscribe .` が何も返さないこと。
2. リポジトリ直下に Xcode App プロジェクトを作成: SwiftUI、`MenuBarExtra`、`LSUIElement = YES`、bundle id は開発者チーム配下、デプロイターゲット 26.0、Swift 6 言語モード、strict concurrency = complete。
3. `Packages/MimizukuCore` をローカルパッケージ依存として App ターゲットに追加する。
4. Info.plist の usage string を今のうちに追加(後段すべての前提になる): `NSMicrophoneUsageDescription`、`NSAudioCaptureUsageDescription`(Xcode のドロップダウンに無い ―― キーを手入力する)、Speech API が要求するなら `NSSpeechRecognitionUsageDescription`。
5. CI が `macos-26` で green であることを確認(パッケージテストのみ)。

受け入れ: 空のアプリが起動しメニューバーアイコンを出す。`swift test` がローカルと CI で green。

## Slice 1 — マイク → ライブ文字起こし(薄い端から端まで)

タスク:

1. `MicrophoneSource: AudioSource` を `AVAudioEngine` の入力 tap で実装。ソースで`SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith:)` へ変換する。
2. `SpeechEngine: TranscriptionEngine` を `SpeechAnalyzer` + `SpeechTranscriber(locale: ja-JP)`でラップ:
   - `prepare(locale:)` は `SpeechTranscriber.installedLocales` / `AssetInventory.assetInstallationRequest` + `downloadAndInstall()`。
   - `.volatileResults` を有効化し、結果を `TranscriptSegment` にマップ(volatile → `isFinal = false`、確定セグメントが置き換える)。
3. 最小のライブ議事ログウィンドウ: 確定行を追記し、現在の volatile 行を下部に薄く描画。メニューバーから開始/停止。
4. モデルアセットの状態を UI に表示(未導入 / ダウンロード中 / 準備完了)。

受け入れ: 日本語で 5 分以上話す。数秒以内に文字起こしが更新される。volatile が確定へ収束する様子が見える。開始/停止を繰り返しても audio engine 状態が漏れない。

> ここで一区切り: Slice 2 に進む前に、実会議音声で日本語の品質を評価する判断を挟む。

## Slice 2 — システム音声 tap + デュアルストリーム

タスク:

1. `SystemAudioTapSource: AudioSource`:
   - `CATapDescription(stereoGlobalTapButExcludeProcesses: [])`。以後 `isExclusive` に触らない(意味反転の罠、domain-pitfalls #1)。
   - `AudioHardwareCreateProcessTap` → tap をサブ tap とする aggregate device (`kAudioAggregateDeviceTapListKey`、private aggregate、tap 自動開始)を現在の既定出力デバイスに紐付ける。
   - `AudioDeviceCreateIOProcIDWithBlock` で消費(AVAudioEngine ではない ―― 向け直しは無言で失敗、domain-pitfalls #2)。
2. ゼロサンプル watchdog: tap が名目上稼働中に N 秒連続で厳密に 0.0f のサンプルなら、ストリームから throw。ルーターは tap と aggregate device の**両方**を破棄・再作成して再購読する(domain-pitfalls #3)。
3. 既定出力デバイスの変更(サンプルレート再交渉、AirPods の sleep/wake)に再構築で対応(watchdog と同じ経路)。
4. 音声捕捉の TCC 事前プローブ + 権限診断画面(マイク / システム音声 / モデルアセットを、状態と修正アクションつきで)。
5. システムストリーム用の 2 つ目の `SpeechEngine` セッション。UI は 2 つのセグメントストリームを1 本のタイムラインでマージし、「自分」/「相手」でラベル付け。

受け入れ: ビデオ通話(または任意の音声)を再生しながら話す。両者が正しくラベル付けされて議事ログに出る。セッション中のヘッドホン抜き差しから自動回復する。60 分の soak run で無音の欠落が無い。

## Slice 3 — 永続化とエクスポート

タスク:

1. セッションモデル: `~/Library/Application Support/<app>/sessions/<timestamp>/` にセッション毎に1 ディレクトリ。
2. 確定 `TranscriptSegment` の append-only JSONL(クラッシュ安全: write-through)。
3. ストリーム毎の生音声録音(任意、AVAudioFile、既定オフ。設定は明示ラベル ―― 既定の姿勢は「文字起こしのみ」)。
4. エクスポート: タイムスタンプと話者ラベル付きの Markdown / プレーンテキスト。
5. 保持設定: N 日より古いセッションを自動削除(既定: 削除しない)。

受け入れ: セッション中の `kill -9` で失うのは最大でも現在のセグメントのみ。60 分セッションのエクスポートが整形されている。

## Slice 4 — OSS リリース

タスク:

1. README(公開向け英語版): 要件(macOS 26 / Apple Silicon を最初の画面で)、スクリーンショット付き権限ウォークスルー、プライバシー声明(全オンデバイス・ネットワークなし)、既知の制約(diarization なし)、録音同意の免責。
2. CONTRIBUTING + DCO、Issue テンプレート(バグ報告は `sw_vers`・音声デバイス・診断画面のスクリーンショットを要求)。
3. 法務レビュー後に ADR-0002 を Accepted へ倒し、LICENSE を追加。
4. リリース workflow: タグ → ビルド → Developer ID 署名(証明書は GitHub Secrets)→ `notarytool` 提出 + staple → GitHub Release アセット。注意: TCC プロンプトは正しく署名されたビルドでのみ機能する。未署名成果物を出荷しない。
5. Homebrew cask。

受け入れ: 新品の macOS 26 マシンの見知らぬ人が `brew install --cask` でインストールし、アプリの案内で権限を付与し、ソースを読まずに文字起こしを得られる。

---

## リスク登録簿

| リスク | 可能性 | 影響 | 緩和策 |
|---|---|---|---|
| macOS 26 の tap が長時間でゼロサンプル劣化 | 実地で観測 | 無言のデータ欠落 | watchdog + 完全再構築(Slice 2 task 2)、受け入れで soak test |
| Swift 6 での `AVAudioPCMBuffer` sendability | 必ず表面化 | ビルド摩擦 / 不安全な近道 | Slice 1 で copy vs `sending` を決定、無言の `@unchecked` を禁止 |
| ja-JP 文字起こし品質が期待未満 | 不明 | プロダクト価値 | Slice 1 終了時に実会議音声で評価してから Slice 2 へ |
| 未署名 dev ビルドで TCC プロンプトが出ない | よくある罠 | デバッグ時間の浪費 | domain-pitfalls #4 に記載、診断画面で TCC 状態を明示 |
| 副業への雇用・IP 主張 | 不明 | 公開のブロック | ADR-0002 の残タスクが初回公開 push のゲート |
| OS 更新で Speech/tap 挙動が壊れる | 中 | 全ユーザーに影響 | `macos-26` CI がコンパイル破壊を検知、README で既知良好 OS ビルドを明記 |
