import AVFoundation
import Foundation
import MimizukuCore
import Observation
import OSLog

/// マイク捕捉 → 文字起こし → ライブ議事ログの 1 セッションを束ねる @MainActor の状態。
///
/// - `MicrophoneSource`(捕捉)→ `SpeechEngine`(文字起こし)→ `TranscriptLog`(集約)を
///   配線する。捕捉/文字起こしの具象は App 層、集約は Core(UI/TCC 非依存)。
/// - UI が観測する状態(`log` / `assetStatus` / `isRunning`)は MainActor に閉じる。
/// - start/stop の反復で audio engine 状態が漏れないよう、停止はセッション Task の
///   キャンセルに集約する(ストリーム終了で捕捉・解析が確実に解放される)。
@MainActor
@Observable
final class AudioSessionController {
    /// 追記されていく確定行 + 現在の volatile 行。
    private(set) var log = TranscriptLog()
    /// モデルアセットの導入状態(UI バナー用)。
    private(set) var assetStatus: ModelAssetStatus = .notInstalled
    /// 捕捉中か。
    private(set) var isRunning = false

    private let locale = Locale(identifier: "ja-JP")
    private let engine = SpeechEngine(stream: .microphone)
    private let logger = Logger(subsystem: "dev.nallto.Mimizuku", category: "session")
    private var sessionTask: Task<Void, Never>?
    /// 進行中のアセット準備。並行呼び出し(起動時プリフェッチと開始時)を 1 本に束ねる。
    private var prepareTask: Task<Void, Never>?

    init() {
        // 起動時にモデルアセットをバックグラウンド導入し、初回利用のブロックを避ける
        // (docs/domain-pitfalls.md #5)。
        Task { [weak self] in await self?.prepareAssets() }
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

    /// 捕捉と文字起こしを開始する。ログは新規セッションとしてリセットする。
    func start() {
        guard !isRunning else { return }
        isRunning = true
        log = TranscriptLog()
        sessionTask = Task { [weak self] in
            guard let self else { return }
            await runSession()
        }
    }

    /// 停止する。セッション Task のキャンセルで捕捉・解析ストリームが畳まれ、
    /// マイク engine と tap が解放される。
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
        guard let format = await engine.bestInputFormat() else {
            logger.error("no compatible audio format for transcription")
            assetStatus = .failed(reason: "文字起こしに対応する音声フォーマットが取得できませんでした。")
            isRunning = false
            return
        }

        let source = MicrophoneSource(targetFormat: format)
        do {
            for try await segment in engine.segments(from: source) {
                log.apply(segment)
            }
        } catch is CancellationError {
            // 通常停止(stop によるキャンセル)。無視。
        } catch {
            logger.error("session failed: \(error.localizedDescription, privacy: .public)")
        }
        isRunning = false
    }
}
