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
/// - start/stop の反復で audio engine 状態が漏れないよう、停止はセッション Task の
///   キャンセルに集約する(ストリーム終了で捕捉・解析・ルーターが確実に解放される)。
/// - 録音の書き込み失敗・片方のストリームの失敗はセッション全体を止めてエラー表示する
///   (無言の欠損を許さない)。
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
    /// 捕捉する入力ソースの選択(マイクのみ / システム音声のみ / 両方)。
    /// 実行中の変更はメニュー側で無効化する。
    var selection: CaptureSelection = .microphone

    var menuState: MenuState {
        if lastError != nil { return .error }
        if case .failed = assetStatus { return .error }
        return isRunning ? .recording : .idle
    }

    /// これ未満の録音は停止時に破棄する(誤操作・空セッション対策、ADR-0006 の 8)。
    private static let minimumSessionDuration: TimeInterval = 2.0

    private let locale = Locale(identifier: "ja-JP")
    private let engine = SpeechEngine()
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

    /// 1 ストリーム分の実行単位(捕捉ソースはストリーム種別から生成する)。
    private struct StreamSession {
        let stream: StreamKind
        let engine: SpeechEngine
        let recorder: AudioFileWriter
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

        let streams = selection.streams
        // T5 修正: マイク権限は開始前に確認する。拒否のまま捕捉すると無音ファイルが
        // できるだけでエラーにならないため、明示エラーに変える。
        if streams.contains(.microphone) {
            guard await ensureMicrophonePermission() else { return }
        }
        // ストリームごとのエンジン。prepare は AssetInventory 操作を並行させないため
        // 直列に呼ぶ(モデル導入済みのため 2 回目以降は即時完了する)。
        guard let engines = await makeEngines(for: streams) else { return }

        // セッションディレクトリとストリーム毎の録音ファイル(mic.caf / system.caf、
        // ADR-0006)。ファイル自体は最初のバッファで遅延オープンされる(捕捉前の
        // ハードウェア照会をしない)。
        let sessionDirectory: URL
        do {
            sessionDirectory = try layout.createSessionDirectory(startedAt: Date())
        } catch {
            fail("セッションディレクトリを作成できませんでした: \(error.localizedDescription)")
            return
        }
        let sessions: [StreamSession] = streams.compactMap { stream in
            guard let streamEngine = engines[stream] else { return nil }
            let url = sessionDirectory.appending(
                component: SessionLayout.recordingFileName(for: stream)
            )
            return StreamSession(
                stream: stream,
                engine: streamEngine,
                recorder: AudioFileWriter(url: url)
            )
        }

        do {
            try await runStreams(sessions, targetFormat: targetFormat)
        } catch is CancellationError {
            // 通常停止(stop によるキャンセル)。無視。
        } catch {
            logger.error("session failed: \(error.localizedDescription, privacy: .public)")
            fail(error.localizedDescription)
        }
        isRunning = false
        await finalizeRecordings(sessions.map(\.recorder), in: sessionDirectory)
    }

    /// T5 修正(#37): マイク TCC の事前確認。未決定なら要求し、拒否なら明示エラー。
    private func ensureMicrophonePermission() async -> Bool {
        switch MicrophonePermission.status() {
        case .granted:
            return true
        case .undetermined:
            if await MicrophonePermission.request() { return true }
            fail("マイクへのアクセスが許可されませんでした。「権限診断」から設定を確認してください。")
            return false
        case .denied:
            fail("マイクへのアクセスが拒否されています。「権限診断」からシステム設定で許可してください。")
            return false
        }
    }

    /// ストリームごとの `SpeechEngine` を用意する。失敗したら `fail` して `nil`。
    private func makeEngines(for streams: [StreamKind]) async -> [StreamKind: SpeechEngine]? {
        var engines: [StreamKind: SpeechEngine] = [:]
        for stream in streams {
            let streamEngine = SpeechEngine()
            do {
                try await streamEngine.prepare(locale: locale)
            } catch {
                fail("文字起こしエンジンの準備に失敗しました: \(error.localizedDescription)")
                return nil
            }
            engines[stream] = streamEngine
        }
        return engines
    }

    /// 各ストリームの `Source → AudioRouter → SpeechEngine` を TaskGroup で並行実行し、
    /// セグメントをライブログへ合流させる。1 つでも失敗したら throw で全体を畳む
    /// (グループのキャンセルで他ストリームの捕捉・録音も解放される)。
    private func runStreams(
        _ sessions: [StreamSession],
        targetFormat: AVAudioFormat
    ) async throws {
        let sessionStart = ContinuousClock.now
        let logger = logger
        try await withThrowingTaskGroup(of: Void.self) { group in
            for session in sessions {
                let source: any AudioSource = switch session.stream {
                case .microphone: MicrophoneSource()
                case .systemAudio: SystemAudioTapSource()
                }
                let label = session.stream.rawValue
                let streamEngine = session.engine
                let routed = AudioRouter.route(
                    source: source,
                    transcriptionFormat: targetFormat,
                    recorder: session.recorder
                ) {
                    // 捕捉開始オフセットの計測(S4 の時刻同期確認)。ストリーム間の
                    // 差分が録音ファイル先頭のずれの目安になる。
                    let ms = Int((sessionStart.duration(to: .now) / .milliseconds(1)).rounded())
                    logger.notice(
                        "first buffer (\(label, privacy: .public)): +\(ms, privacy: .public)ms"
                    )
                }
                group.addTask { [weak self] in
                    for try await segment in streamEngine.segments(from: routed) {
                        await self?.apply(segment)
                    }
                }
            }
            try await group.waitForAll()
        }
    }

    /// セグメントをライブログへ適用する(TaskGroup の子タスクから MainActor へ合流)。
    private func apply(_ segment: TranscriptSegment) {
        log.apply(segment)
    }

    /// 録音を閉じ、短すぎる/空のセッションは破棄する(全ストリームの**最長**で判定、
    /// ADR-0006 の 8)。保持する場合は書き込まれたファイルだけを AAC 変換する。
    private func finalizeRecordings(
        _ recorders: [AudioFileWriter],
        in sessionDirectory: URL
    ) async {
        var durations: [TimeInterval] = []
        for recorder in recorders {
            _ = await recorder.finish()
            await durations.append(recorder.duration)
        }
        if SessionRetention.shouldDiscard(
            durations: durations,
            minimumDuration: Self.minimumSessionDuration
        ) {
            let longest = durations.max() ?? 0
            logger.notice("discarding short session (\(longest, format: .fixed(precision: 2))s)")
            try? FileManager.default.removeItem(at: sessionDirectory)
        } else {
            for (recorder, duration) in zip(recorders, durations) where duration > 0 {
                convertInBackground(caf: recorder.url)
            }
        }
    }

    /// 停止後の AAC 変換(ADR-0006 の 2)。失敗しても CAF は温存され、次回起動の
    /// 回復スキャンで再変換される。
    private func convertInBackground(caf: URL) {
        Task { [weak self] in
            do {
                _ = try await Self.convertOffMain(caf: caf)
            } catch {
                let reason = error.localizedDescription
                self?.logger.error("aac conversion failed: \(reason, privacy: .public)")
                self?.lastError = "録音の圧縮に失敗しました(元データは保持): \(reason)"
            }
        }
    }

    private func recoverPendingRecordings() async {
        let pending = layout.pendingRecordings()
        guard !pending.isEmpty else { return }
        logger.notice("recovering \(pending.count) unconverted recording(s)")
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
