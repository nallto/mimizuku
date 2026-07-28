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

    private let locale = Locale(identifier: "ja-JP")
    private let engine = SpeechEngine()
    let layout = SessionLayout.defaultLayout()
    /// 配線層 extension(別ファイル)からも使うため internal(この型の実装内に限る)。
    let logger = Logger(subsystem: "dev.nallto.Mimizuku", category: "session")
    private var sessionTask: Task<Void, Never>?
    /// start/stopをまたいで遅延到着する旧セッションの通知・後始末を識別する。
    /// 世代が一致しない処理は録音ファイルのクローズ以外のUI状態を変更しない。
    private var sessionGeneration: UInt64 = 0
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

    /// 停止する。セッション Task のキャンセルで捕捉・解析・ルーターが畳まれ、
    /// マイク engine と tap が解放される。録音ファイルの close と AAC 変換は
    /// `runSession` の後始末が行う。
    func stop() {
        sessionGeneration &+= 1
        sessionTask?.cancel()
        isRunning = false
    }

    /// 1 ストリーム分の実行単位(捕捉ソースはストリーム種別から生成する)。
    struct StreamSession {
        let stream: StreamKind
        let engine: SpeechEngine
        let recorder: AudioFileWriter
    }

    private struct PreparedSession {
        let streams: [StreamKind]
        let sessions: [StreamSession]
        let targetFormat: AVAudioFormat
        let directory: URL
    }

    private func runSession(generation: UInt64) async {
        defer {
            if isCurrentSession(generation) {
                isRunning = false
                sessionTask = nil
            }
        }
        guard let prepared = await prepareSession(generation: generation) else { return }
        let discardFailedStart = await runCaptureSession(
            prepared.sessions,
            streams: prepared.streams,
            targetFormat: prepared.targetFormat,
            generation: generation
        )
        if discardFailedStart {
            await discardRecordings(prepared.sessions.map(\.recorder), in: prepared.directory)
            // 5秒の開始待ち中にsystem側で生成されたfinal/volatileも含め、
            // 正式セッションとして成立しなかったログを全て破棄する。
            if isCurrentSession(generation) {
                log = TranscriptLog()
            }
        } else {
            await finalizeRecordings(
                prepared.sessions.map(\.recorder),
                in: prepared.directory,
                generation: generation
            )
        }
    }

    private func prepareSession(generation: UInt64) async -> PreparedSession? {
        // 進行中の起動時プリフェッチがあればそれに合流する。
        await prepareAssets()
        guard isCurrentSession(generation), !Task.isCancelled else { return nil }
        guard case .ready = assetStatus else { return nil }
        guard let targetFormat = await engine.bestInputFormat() else {
            fail("文字起こしに対応する音声フォーマットが取得できませんでした。", for: generation)
            return nil
        }
        guard isCurrentSession(generation), !Task.isCancelled else { return nil }

        let streams = selection.streams
        // T5 修正: マイク権限は開始前に確認する。拒否のまま捕捉すると無音ファイルが
        // できるだけでエラーにならないため、明示エラーに変える。
        if streams.contains(.microphone) {
            guard await ensureMicrophonePermission(for: generation) else { return nil }
        }
        guard isCurrentSession(generation), !Task.isCancelled else { return nil }
        // ストリームごとのエンジン。prepare は AssetInventory 操作を並行させないため
        // 直列に呼ぶ(モデル導入済みのため 2 回目以降は即時完了する)。
        guard let engines = await makeEngines(for: streams, generation: generation) else {
            return nil
        }
        guard isCurrentSession(generation), !Task.isCancelled else { return nil }

        // セッションディレクトリとストリーム毎の録音ファイル(mic.caf / system.caf、
        // ADR-0006)。ファイル自体は最初のバッファで遅延オープンされる(捕捉前の
        // ハードウェア照会をしない)。
        let directory: URL
        do {
            directory = try layout.createSessionDirectory(startedAt: Date())
        } catch {
            fail(
                "セッションディレクトリを作成できませんでした: \(error.localizedDescription)",
                for: generation
            )
            return nil
        }
        return makePreparedSession(
            streams: streams,
            engines: engines,
            targetFormat: targetFormat,
            directory: directory
        )
    }

    private func makePreparedSession(
        streams: [StreamKind],
        engines: [StreamKind: SpeechEngine],
        targetFormat: AVAudioFormat,
        directory: URL
    ) -> PreparedSession {
        let sessions = streams.compactMap { stream -> StreamSession? in
            guard let streamEngine = engines[stream] else { return nil }
            let recording = directory.appending(
                component: SessionLayout.recordingFileName(for: stream)
            )
            return StreamSession(
                stream: stream,
                engine: streamEngine,
                recorder: AudioFileWriter(url: recording)
            )
        }
        return PreparedSession(
            streams: streams,
            sessions: sessions,
            targetFormat: targetFormat,
            directory: directory
        )
    }

    /// 捕捉本体を実行し、正式なマイク音源を開始できずセッション全体を破棄すべき場合は
    /// `true`を返す。
    private func runCaptureSession(
        _ sessions: [StreamSession],
        streams: [StreamKind],
        targetFormat: AVAudioFormat,
        generation: UInt64
    ) async -> Bool {
        do {
            // マイクを含むモードはAECポンプを必須とし、初期化失敗時にrawへ戻さない。
            let inputs = try await makeInputs(for: streams, generation: generation)
            guard isCurrentSession(generation), !Task.isCancelled else { return false }
            try await runStreams(
                sessions,
                inputs: inputs,
                targetFormat: targetFormat,
                generation: generation
            )
            return false
        } catch is CancellationError {
            // 通常停止(stop によるキャンセル)。無視。
            return false
        } catch {
            // watchdog期限と利用者停止が競合した場合は、通常停止を優先して
            // lastErrorやfailed-start cleanupを発生させない。
            if Task.isCancelled { return false }
            logger.error("session failed: \(error.localizedDescription, privacy: .public)")
            fail(error.localizedDescription, for: generation)
            guard let captureError = error as? CaptureError else { return false }
            if case .aecReferenceStartTimedOut = captureError { return true }
            return false
        }
    }

    /// T5 修正(#37): マイク TCC の事前確認。未決定なら要求し、拒否なら明示エラー。
    private func ensureMicrophonePermission(for generation: UInt64) async -> Bool {
        switch MicrophonePermission.status() {
        case .granted:
            return true
        case .undetermined:
            let granted = await MicrophonePermission.request()
            guard isCurrentSession(generation), !Task.isCancelled else { return false }
            if granted { return true }
            fail(
                "マイクへのアクセスが許可されませんでした。「権限診断」から設定を確認してください。",
                for: generation
            )
            return false
        case .denied:
            fail(
                "マイクへのアクセスが拒否されています。「権限診断」からシステム設定で許可してください。",
                for: generation
            )
            return false
        }
    }

    /// ストリームごとの `SpeechEngine` を用意する。失敗したら `fail` して `nil`。
    private func makeEngines(
        for streams: [StreamKind],
        generation: UInt64
    ) async -> [StreamKind: SpeechEngine]? {
        var engines: [StreamKind: SpeechEngine] = [:]
        for stream in streams {
            let streamEngine = SpeechEngine()
            do {
                try await streamEngine.prepare(locale: locale)
            } catch {
                fail(
                    "文字起こしエンジンの準備に失敗しました: \(error.localizedDescription)",
                    for: generation
                )
                return nil
            }
            guard isCurrentSession(generation), !Task.isCancelled else { return nil }
            engines[stream] = streamEngine
        }
        return engines
    }

    private func fail(_ message: String, for generation: UInt64) {
        guard isCurrentSession(generation) else { return }
        lastError = message
        isRunning = false
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
