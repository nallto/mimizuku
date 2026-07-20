import AVFoundation
import Foundation
import MimizukuCore
import Observation
import OSLog

/// マイク捕捉 → 録音(CAF)+ 文字起こし → ライブ議事ログの 1 セッションを束ねる
/// @MainActor の状態。
///
/// - `MicrophoneSource`(捕捉)→ `AudioRouter`(ファンアウト)→ `SpeechEngine`(文字起こし)
///   + `AudioFileWriter`(録音)を配線する。捕捉/ルーティングの具象は App 層、
///   録音・レイアウト・集約は Core(UI/TCC 非依存)。
/// - UI が観測する状態(`log` / `assetStatus` / `isRunning` / `lastError`)は MainActor に閉じる。
/// - start/stop の反復で audio engine 状態が漏れないよう、停止はセッション Task の
///   キャンセルに集約する(ストリーム終了で捕捉・解析・ルーターが確実に解放される)。
/// - 録音の書き込み失敗はセッション全体を止めてエラー表示する(無言の欠損を許さない)。
@MainActor
@Observable
final class AudioSessionController {
    /// メニューバーアイコンが表す動作状況(#35: 待機 / 録音中 / エラーの 3 状態)。
    enum MenuState {
        case idle
        case recording
        case error
    }

    /// 追記されていく確定行 + 現在の volatile 行。
    private(set) var log = TranscriptLog()
    /// モデルアセットの導入状態(UI バナー用)。
    private(set) var assetStatus: ModelAssetStatus = .notInstalled
    /// 捕捉中か。
    private(set) var isRunning = false
    /// 直近のセッション/変換エラー(メニューバー表示用)。次の開始でクリアされる。
    private(set) var lastError: String?

    var menuState: MenuState {
        if lastError != nil { return .error }
        if case .failed = assetStatus { return .error }
        return isRunning ? .recording : .idle
    }

    /// これ未満の録音は停止時に破棄する(誤操作・空セッション対策、ADR-0006 の 8)。
    private static let minimumSessionDuration: TimeInterval = 2.0

    private let locale = Locale(identifier: "ja-JP")
    private let engine = SpeechEngine(stream: .microphone)
    private let layout = SessionLayout.defaultLayout()
    private let logger = Logger(subsystem: "dev.nallto.Mimizuku", category: "session")
    private var sessionTask: Task<Void, Never>?
    /// 進行中のアセット準備。並行呼び出し(起動時プリフェッチと開始時)を 1 本に束ねる。
    private var prepareTask: Task<Void, Never>?

    init() {
        // 起動時にモデルアセットをバックグラウンド導入し、初回利用のブロックを避ける
        // (docs/domain-pitfalls.md #5)。
        Task { [weak self] in await self?.prepareAssets() }
        // 前回クラッシュ等で AAC 変換されずに残った CAF を回復する(ADR-0006 の 6)。
        Task { [weak self] in await self?.recoverPendingRecordings() }
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

    func toggle() {
        if isRunning { stop() } else { start() }
    }

    /// 捕捉・録音・文字起こしを開始する。ログは新規セッションとしてリセットする。
    func start() {
        guard !isRunning else { return }
        isRunning = true
        lastError = nil
        log = TranscriptLog()
        sessionTask = Task { [weak self] in
            guard let self else { return }
            await runSession()
        }
    }

    /// 停止する。セッション Task のキャンセルで捕捉・解析・ルーターが畳まれ、
    /// マイク engine と tap が解放される。録音ファイルの close と AAC 変換は
    /// `runSession` の後始末が行う。
    func stop() {
        sessionTask?.cancel()
        sessionTask = nil
        isRunning = false
    }

    private func runSession() async {
        // アセット準備を待つ(進行中の起動時プリフェッチがあればそれに合流する)。
        await prepareAssets()
        guard case .ready = assetStatus else {
            isRunning = false
            return
        }
        guard let targetFormat = await engine.bestInputFormat() else {
            fail("文字起こしに対応する音声フォーマットが取得できませんでした。")
            return
        }

        // セッションディレクトリと録音ファイル(mic.caf、ADR-0006)。ファイル自体は
        // 最初のバッファで遅延オープンされる(捕捉前のハードウェア照会をしない)。
        let sessionDirectory: URL
        do {
            sessionDirectory = try layout.createSessionDirectory(startedAt: Date())
        } catch {
            fail("セッションディレクトリを作成できませんでした: \(error.localizedDescription)")
            return
        }
        let source = MicrophoneSource()
        let recorder = AudioFileWriter(
            url: sessionDirectory.appending(
                component: SessionLayout.recordingFileName(for: .microphone)
            )
        )

        let routed = AudioRouter.route(
            source: source,
            transcriptionFormat: targetFormat,
            recorder: recorder
        )
        do {
            for try await segment in engine.segments(from: routed) {
                log.apply(segment)
            }
        } catch is CancellationError {
            // 通常停止(stop によるキャンセル)。無視。
        } catch {
            logger.error("session failed: \(error.localizedDescription, privacy: .public)")
            fail(error.localizedDescription)
        }
        isRunning = false

        // 録音を閉じる。短すぎる/空のセッションは破棄し(ADR-0006 の 8)、
        // 実用的な長さがあれば AAC 変換をバックグラウンドで行う。
        _ = await recorder.finish()
        let duration = await recorder.duration
        if duration < Self.minimumSessionDuration {
            logger.info("discarding short session (\(duration, format: .fixed(precision: 2))s)")
            try? FileManager.default.removeItem(at: sessionDirectory)
        } else {
            convertInBackground(caf: recorder.url)
        }
    }

    /// 停止後の AAC 変換(ADR-0006 の 2)。失敗しても CAF は温存され、次回起動の
    /// 回復スキャンで再変換される。
    private func convertInBackground(caf: URL) {
        Task { [weak self] in
            do {
                _ = try await Self.convertOffMain(caf: caf)
            } catch {
                self?.lastError = "録音の圧縮に失敗しました(元データは保持): \(error.localizedDescription)"
            }
        }
    }

    private func recoverPendingRecordings() async {
        let pending = layout.pendingRecordings()
        guard !pending.isEmpty else { return }
        logger.info("recovering \(pending.count) unconverted recording(s)")
        for caf in pending {
            do {
                _ = try await Self.convertOffMain(caf: caf)
            } catch {
                logger.error("recovery failed: \(error.localizedDescription, privacy: .public)")
                lastError = "前回の録音の変換に失敗しました(元データは保持)。"
            }
        }
    }

    /// AAC 変換を MainActor の外で実行する(数分の録音でも UI を塞がない)。
    private nonisolated static func convertOffMain(caf: URL) async throws -> URL {
        try AacConverter().convert(caf: caf)
    }

    private func fail(_ message: String) {
        lastError = message
        isRunning = false
    }
}
