import AVFoundation
import Foundation
import MimizukuCore
import Observation
import OSLog

/// 捕捉 → 録音(CAF)+ 文字起こし → ライブ議事ログの 1 セッションを束ねる
/// @MainActor の状態。
///
/// - 選択された各ストリーム(マイク / システム音声 / 両方、`CaptureSelection`)ごとに
///   `Source → AudioRouter(ファンアウト)→ SpeechEngine + AudioFileWriter` の系を
///   TaskGroup で並行実行し、セグメントを 1 本の `TranscriptLog` へ合流させる。
///   捕捉/ルーティングの具象は App 層、録音・レイアウト・集約は Core(UI/TCC 非依存)。
/// - `SpeechEngine` はストリームごとに 1 インスタンス(actor 分離で給餌ループを並列化)。
///   `prepare` は AssetInventory 操作の並行を避けるため直列に呼ぶ。
/// - UI が観測する状態(`log` / `assetStatus` / `isRunning` / `lastError`)は MainActor に閉じる。
/// - 通常停止は音声入力だけを閉じてSpeechのfinalizeを待つ。5秒の期限を超えた場合だけ
///   セッションTaskをcancelし、最後のvolatileを未完了末尾として保存する。
/// - 録音の書き込み失敗・片方のストリームの失敗はセッション全体を止めてエラー表示する
///   (無言の欠損を許さない)。
@MainActor
@Observable
final class AudioSessionController {
    /// 追記されていく確定行 + 現在の volatile 行。
    private(set) var log = TranscriptLog()
    /// モデルアセットの導入状態(UI バナー用)。
    private(set) var assetStatus: ModelAssetStatus = .notInstalled
    /// 捕捉中か。
    private(set) var isRunning = false
    /// 直近のセッション/変換エラー(メニューバー表示用)。次の開始でクリアされる。
    private(set) var lastError: String?
    /// 捕捉する入力ソースの選択(マイクのみ / システム音声のみ / 両方)。
    /// 実行中の変更はメニュー側で無効化する。
    var selection: CaptureSelection = .microphone
    /// 直近のセッションで AEC が効いているか(権限診断画面の表示用、#64)。
    /// 外部からは読み取り専用。配線層(`AudioSessionController+Inputs`)からは
    /// `applyAecStatus(_:)` 経由でのみ更新する(UI からの書き換えを防ぐ)。
    private(set) var aecStatus: AecStatus = .notApplicable

    /// これ未満の録音は停止時に破棄する(誤操作・空セッション対策、ADR-0006 の 8)。
    static let minimumSessionDuration: TimeInterval = 2.0

    let locale = Locale(identifier: "ja-JP")
    let engine = SpeechEngine()
    let layout = SessionLayout.defaultLayout()
    @ObservationIgnored
    lazy var store = SessionStore(layout: layout)
    /// 配線層 extension(別ファイル)からも使うため internal(この型の実装内に限る)。
    let logger = Logger(subsystem: "dev.nallto.Mimizuku", category: "session")
    var sessionTask: Task<Void, Never>?
    /// 通常停止を捕捉ストリームへ伝える。準備中はnilなので、stopはTaskを直接cancelする。
    var activeStopSignal: SessionStopSignal?
    /// AEC 診断試行(#75 / ADR-0015)。揮発性起動引数 `-AecDiagnosticsEnabled YES` で
    /// 有効化された場合のみ生成される。所有と exactly-once close は `runSession` が担う
    /// (pump は `pumpFinished` イベントを送るだけで close しない)。書き込みは
    /// `runSession` と `+Diagnostics` extension に限る。
    var aecDiagnosticsTrial: AecDiagnosticsTrial?
    /// 起動引数キー(argument domain のみを読む ―― 永続 defaults では有効化させない)。
    static let aecDiagnosticsDefaultsKey = "AecDiagnosticsEnabled"
    /// start/stopをまたいで遅延到着する旧セッションの通知・後始末を識別する。
    /// 世代が一致しない処理は録音ファイルのクローズ以外のUI状態を変更しない。
    private var sessionGeneration: UInt64 = 0
    /// 進行中のアセット準備。並行呼び出し(起動時プリフェッチと開始時)を 1 本に束ねる。
    private var prepareTask: Task<Void, Never>?

    init() {
        // 起動時にモデルアセットをバックグラウンド導入し、初回利用のブロックを避ける
        // (docs/domain-pitfalls.md #5)。
        Task { [weak self] in await self?.prepareAssets() }
        // 前回クラッシュ等で残った文字起こしジャーナルを先に確定し、その後AAC変換を
        // 回復する。transcript→metaの順序をAACのパス更新より先に完了させる。
        Task { [weak self] in
            await self?.recoverPendingTranscripts()
            await self?.recoverPendingRecordings()
        }
    }

    /// モデルアセットを導入済みにする。未導入ならダウンロードして待つ。並行呼び出しは
    /// 進行中の 1 本にコアレスされ、全呼び出し元が同じ完了を待つ。
    func prepareAssets() async {
        if case .ready = assetStatus { return }
        if let prepareTask {
            await prepareTask.value
            return
        }
        let task = Task { [weak self] in
            guard let self else { return }
            await performPrepare()
        }
        prepareTask = task
        await task.value
        prepareTask = nil
    }

    private func performPrepare() async {
        let installed = await engine.isModelInstalled(for: locale)
        assetStatus = installed ? .ready : .downloading
        do {
            try await engine.prepare(locale: locale)
            assetStatus = .ready
        } catch {
            logger.error("asset prepare failed: \(error.localizedDescription, privacy: .public)")
            assetStatus = .failed(reason: error.localizedDescription)
        }
    }

    /// 捕捉・録音・文字起こしを開始する。ログは新規セッションとしてリセットする。
    func start() {
        guard !isRunning else { return }
        let predecessor = sessionTask
        sessionGeneration &+= 1
        let generation = sessionGeneration
        isRunning = true
        lastError = nil
        log = TranscriptLog()
        sessionTask = Task { [weak self] in
            guard let self else { return }
            // stop直後の再開でも旧engine/tapの解放完了を待ち、音声デバイスを重複起動しない。
            await predecessor?.value
            guard isCurrentSession(generation), !Task.isCancelled else { return }
            await runSession(generation: generation)
        }
    }

    /// 停止する。捕捉開始済みなら入力を正常終了させ、Speech finalizeと結果完了を待つ。
    /// 5秒を超えたときだけTaskをcancelし、最後のvolatileを未完了として保存する。
    func stop() {
        guard isRunning else { return }
        isRunning = false
        guard let signal = activeStopSignal else {
            // 権限・モデル・捕捉準備中はSpeechへ渡した入力がまだ無いため即時cancelでよい。
            sessionTask?.cancel()
            return
        }
        signal.request()
        let stoppingTask = sessionTask
        Task {
            try? await Task.sleep(for: .seconds(Self.speechFinalizationTimeout))
            stoppingTask?.cancel()
        }
    }

    func fail(_ message: String, for generation: UInt64) {
        guard isCurrentSession(generation) else { return }
        lastError = message
        isRunning = false
    }

    func finishSessionState(for generation: UInt64) {
        guard isCurrentSession(generation) else { return }
        isRunning = false
        sessionTask = nil
        activeStopSignal = nil
    }

    func discardTranscriptLog(for generation: UInt64) {
        guard isCurrentSession(generation) else { return }
        log = TranscriptLog()
    }

    func applyRecordingError(_ message: String, generation: UInt64? = nil) {
        if let generation, !isCurrentSession(generation) { return }
        lastError = message
    }

    func isCurrentSession(_ generation: UInt64) -> Bool {
        generation == sessionGeneration
    }

    func applyTranscript(_ segment: TranscriptSegment, generation: UInt64) {
        guard isCurrentSession(generation) else { return }
        log.apply(segment)
    }

    /// AEC 状態を更新する(配線層 `AudioSessionController+Inputs` からの唯一の書き込み口)。
    func applyAecStatus(_ status: AecStatus, for generation: UInt64) {
        guard isCurrentSession(generation) else { return }
        aecStatus = status
    }
}
