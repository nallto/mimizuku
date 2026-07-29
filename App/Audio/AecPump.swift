import AVFoundation
import MimizukuCore
import OSLog
import Synchronization

/// actor hopなしで通常停止を刻み、実行待ちwatchdogの失敗通知を抑止する。
private final class AecShutdownGate: Sendable {
    private let flag = Mutex(false)

    var isSet: Bool {
        flag.withLock { $0 }
    }

    func set() {
        flag.withLock { $0 = true }
    }
}

/// AEC ポンプからセッション制御層へ通知する実行時状態。
enum AecRuntimeStatus: Sendable, Equatable {
    /// 対応するrender/captureをAPMへ実際に給餌し、処理後音声を出力した。
    case active
    /// render が一時的に途切れ、原音を無音へ置き換えながら復旧を待っている。
    case recovering
    /// 開始または復旧期限を超え、正式なマイク音源を生成できない。
    case failed(AecFeedScheduler.FailureReason)
}

/// WebRTC AEC3 のライブ適用ポンプ(#63 / #64、ADR-0013)。
///
/// far-end(システム音声 tap)を参照として取り込みつつ、near-end(マイク)を
/// 処理して「処理後ストリーム」を返す。処理後音声が文字起こしと録音の両方に流れる
///
/// - 内部フォーマットは 48kHz / mono / int16 / 10ms(ブリッジ契約)。入出力の変換は
///   遅延生成の `BufferConverter`(最初のバッファのフォーマットから確定)。
/// - 給餌順はホストタイムでマージする(`AecFeedScheduler` ―― 到着順給餌だと実 render が
///   系統的に破棄される。#63 の申し送り)。
/// - tap 中断中はマイク原音を同長の無音へ置換し、参照復帰時に同期epochとAPMを
///   リセットして再収束させる。期限超過はセッション失敗とする。
/// - ドリフトは計測して notice ログに残すのみ。補正の適用は soak で残留エコーの増悪が
///   観測された場合の後続対応(単点推定のフラッピング回避 ―― #63 の申し送り)。
/// - マイク経路の処理失敗は無言で欠損させず、処理後ストリームを throw で畳んで
///   セッション全体を止める(既存原則)。
actor AecPump {
    private let bridge = AudioProcessingBridge()
    private let logger = Logger(subsystem: "dev.nallto.Mimizuku", category: "aec")
    private let statusHandler: @MainActor @Sendable (AecRuntimeStatus) -> Void
    private let shutdownGate = AecShutdownGate()

    private var renderFramer = AecFramer()
    private var captureFramer = AecFramer()
    // 実測ホストタイムはジッタを持つため、サンプルクロック由来の連続タイムラインへ
    // 正規化してから使う(AecTimeline のコメント参照 ―― ジッタをそのまま framer へ
    // 渡すと不連続破棄が頻発し、マイクが約 5% 欠けて AEC がロックしない実測)。
    // 閾値: capture(マイク)はエンジン継続中に本物の欠落が起きない前提で緩め、
    // render(tap)は再構築の欠落(数十 ms〜)をリベースとして検出できるよう狭める。
    private var captureTimeline = AecTimeline(rebaseThreshold: 0.25)
    private var renderTimeline = AecTimeline(rebaseThreshold: 0.05)
    private var aligner = AecAligner()
    private var scheduler = AecFeedScheduler()
    private var drift = AecDriftDiagnostics()
    private var renderConverter: BufferConverter?
    private var captureConverter: BufferConverter?
    private var output: AsyncThrowingStream<AecFrame, Error>.Continuation?
    private var started = false
    private var processedFrames = 0
    private var silencedFrames = 0
    /// `.active` は初回 render 受信時ではなく、対応する capture を実際に APM へ
    /// 入れた時点で一度だけ通知する。
    private var reportedActive = false
    /// 復旧時に古い同期epochをAPMへ持ち越さないため、次の有効render受信前に
    /// bridge/aligner/framerを一度だけ初期化する。
    private var recoveryResetPending = false
    private var reportedFailure = false
    /// 診断: capture 側の正規化タイムラインの現在端(初回 render とのオフセット計測用)。
    private var captureFrontierTime: TimeInterval?
    private var loggedFirstRender = false

    /// ブリッジ契約の内部フォーマット。
    private static let aecFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: 48000,
        channels: 1,
        interleaved: true
    )

    init(
        statusHandler: @escaping @MainActor @Sendable (AecRuntimeStatus) -> Void = { _ in }
    ) {
        self.statusHandler = statusHandler
    }

    /// APM を初期化する。失敗時はfalse(呼び出し側はrawへ戻さず開始失敗にする)。
    func start() -> Bool {
        guard Self.aecFormat != nil, bridge.initializeProcessing() else {
            logger.error("aec bridge initialization failed")
            return false
        }
        scheduler.begin(at: Self.currentHostSeconds())
        started = true
        return true
    }

    // MARK: - 取り込み(actor 内)

    func setOutput(_ continuation: AsyncThrowingStream<AecFrame, Error>.Continuation) {
        output = continuation
    }

    nonisolated func requestShutdown() {
        shutdownGate.set()
    }

    /// 隠し参照tapのストリーム中断(mic-only)。開始待ちでは期限まで再生成を許し、
    /// 稼働後はrecoveringへ移る。いずれもマイク原音は正式出力へ流さない。
    func noteReferenceInterrupted(_ error: (any Error)?) async {
        guard started else { return }
        if let error {
            logger.notice(
                "aec hidden reference interrupted: \(error.localizedDescription, privacy: .public)"
            )
        } else {
            logger.notice("aec hidden reference interrupted without error")
        }
        let transition = scheduler.markReferenceInterrupted(at: Self.currentHostSeconds())
        if transition == .recovering {
            recoveryResetPending = true
            reportedActive = false
            await statusHandler(.recovering)
        }
        await releaseAndProcess()
    }

    func shouldRetryReference() -> Bool {
        guard started else { return false }
        if case .failed = scheduler.state { return false }
        return true
    }

    /// capture到着と独立して期限超過を検出し、rawへ戻さず明示エラーで終了する。
    func checkReferenceDeadline() async -> Bool {
        guard started, !shutdownGate.isSet, !Task.isCancelled else { return false }
        let transition = scheduler.checkDeadline(now: Self.currentHostSeconds())
        guard case let .failed(reason) = transition else { return true }
        // deadline判定と同時に利用者停止が入った場合は、failed通知より停止を優先する。
        guard !shutdownGate.isSet, !Task.isCancelled else { return false }
        await failForUnavailableReference(reason)
        return false
    }

    func ingestRender(_ item: TimestampedAudioBuffer) async {
        guard started, let format = Self.aecFormat else { return }
        if case .failed = scheduler.state { return }
        if recoveryResetPending {
            resetForRecovery()
            recoveryResetPending = false
        }
        if renderConverter == nil {
            renderConverter = BufferConverter(from: item.buffer.format, to: format)
        }
        guard let converter = renderConverter,
              let converted = converter.convertedCopy(of: item.buffer),
              let samples = Self.int16Samples(of: converted)
        else {
            // 参照の単発欠落は aligner の無音充填で吸収される(致命にしない)。
            return
        }
        drift.recordRender(sampleCount: samples.count, hostTime: item.hostTime)
        let time = renderTimeline.normalize(hostTime: item.hostTime, sampleCount: samples.count)
        if !loggedFirstRender {
            loggedFirstRender = true
            // セッション先頭のストリーム間アンカー差の実測(#63 のパターン切り分け用)。
            // 0 近傍が期待値。大きな正負はタイムスタンプ意味差/ウォームアップ誤差のサイン。
            let deltaMs = Int(((captureFrontierTime ?? time) - time) * 1000)
            let held = scheduler.heldCount
            logger.notice(
                """
                aec first render: capture frontier vs render start = \
                \(deltaMs, privacy: .public)ms held=\(held, privacy: .public)
                """
            )
        }
        let frames = renderFramer.append(samples: samples, hostTime: time)
        guard let first = frames.first, let last = frames.last else { return }
        for frame in frames {
            aligner.appendRender(frame)
        }
        let transition = scheduler.advanceRenderFrontier(
            startingAt: first.hostTime,
            to: last.hostTime
        )
        if transition == .recovered {
            logger.notice("aec reference recovered; waiting for processed capture")
        }
        await releaseAndProcess()
    }

    func ingestCapture(_ item: TimestampedAudioBuffer) async {
        guard started, let format = Self.aecFormat else { return }
        if captureConverter == nil {
            captureConverter = BufferConverter(from: item.buffer.format, to: format)
        }
        guard let converter = captureConverter,
              let converted = converter.convertedCopy(of: item.buffer),
              let samples = Self.int16Samples(of: converted)
        else {
            // マイク経路の欠損は許さない(録音は処理後ストリームから作られる)。
            await finishCapture(error: CaptureError.aecProcessingFailed)
            return
        }
        drift.recordCapture(sampleCount: samples.count, hostTime: item.hostTime)
        let time = captureTimeline.normalize(hostTime: item.hostTime, sampleCount: samples.count)
        captureFrontierTime = time + Double(samples.count) / 48000
        let now = Self.currentHostSeconds()
        for frame in captureFramer.append(samples: samples, hostTime: time) {
            scheduler.hold(frame, arrivedAt: now)
        }
        await releaseAndProcess()
    }

    private func releaseAndProcess() async {
        let now = Self.currentHostSeconds()
        let previousState = scheduler.state
        let releases = scheduler.release(now: now)
        if previousState == .active, scheduler.state == .recovering {
            recoveryResetPending = true
            reportedActive = false
        }
        var becameActive = false
        for release in releases {
            let capture = release.frame
            if release.processing == .silence {
                silencedFrames += 1
                output?.yield(AecFrame(
                    samples: [Int16](repeating: 0, count: capture.samples.count),
                    hostTime: capture.hostTime
                ))
                continue
            }

            let step = aligner.appendCapture(capture)
            for render in step.render where !feedRender(render) {
                logger.error("aec render feed failed")
            }
            var samples = capture.samples
            let processed = samples.withUnsafeMutableBufferPointer { pointer -> Bool in
                guard let base = pointer.baseAddress else { return false }
                return bridge.processCaptureFrame(base)
            }
            guard processed else {
                await finishCapture(error: CaptureError.aecProcessingFailed)
                return
            }
            processedFrames += 1
            logDriftIfNeeded()
            output?.yield(AecFrame(samples: samples, hostTime: capture.hostTime))
            if !reportedActive {
                reportedActive = true
                becameActive = true
            }
        }
        // 音声フレームを順序どおり出力してから MainActor へ通知する。通知 await 中の
        // actor 再入で後続 capture が先に出力される逆転を防ぐ。
        if becameActive {
            await statusHandler(.active)
        }
        if previousState == .active, scheduler.state == .recovering {
            await statusHandler(.recovering)
        }
        if case let .failed(reason) = scheduler.state, !reportedFailure {
            await failForUnavailableReference(reason)
        }
    }

    func finishCapture(error: (any Error)?) async {
        if error is CancellationError {
            shutdownGate.set()
        }
        guard started else {
            output?.finish(throwing: error)
            output = nil
            return
        }
        // 終了drainは実行時timeoutと完全に分離する。残余rawは出力せず破棄し、
        // waiting/recoveringからfailedへ遷移させない。
        _ = scheduler.drainForShutdown()
        // Logger の補間は escaping autoclosure でプロパティ直接参照が使えないため、
        // ローカルへ写してから記録する。
        let frames = processedFrames
        let silenced = silencedFrames
        let filled = aligner.filledSilenceFrames
        let dropped = aligner.droppedRenderFrames
        let leadDropped = aligner.droppedLeadRenderFrames
        let held = scheduler.heldCount
        let captureDiscarded = captureFramer.discardedSamples
        let renderDiscarded = renderFramer.discardedSamples
        let captureRebases = captureTimeline.rebases
        let renderRebases = renderTimeline.rebases
        let droppedHeld = scheduler.droppedHeldFrames
        let discarded = scheduler.discardedFrames
        let recoveries = scheduler.recoveryCount
        logger.notice(
            """
            aec finished: frames=\(frames, privacy: .public) \
            silenced=\(silenced, privacy: .public) \
            filled=\(filled, privacy: .public) \
            droppedRender=\(dropped, privacy: .public) \
            leadDropped=\(leadDropped, privacy: .public) \
            held=\(held, privacy: .public) \
            droppedHeld=\(droppedHeld, privacy: .public) \
            discardedRaw=\(discarded, privacy: .public) \
            recoveries=\(recoveries, privacy: .public) \
            capDiscard=\(captureDiscarded, privacy: .public) \
            renDiscard=\(renderDiscarded, privacy: .public) \
            capRebase=\(captureRebases, privacy: .public) \
            renRebase=\(renderRebases, privacy: .public)
            """
        )
        output?.finish(throwing: error)
        output = nil
        started = false
        bridge.shutdown()
    }
}

// MARK: - Helpers

private extension AecPump {
    func feedRender(_ frame: AecFrame) -> Bool {
        frame.samples.withUnsafeBufferPointer { pointer -> Bool in
            guard let base = pointer.baseAddress else { return false }
            return bridge.processRenderFrame(base)
        }
    }

    func resetForRecovery() {
        bridge.reset()
        aligner = AecAligner()
        renderFramer = AecFramer()
        renderTimeline = AecTimeline(rebaseThreshold: 0.05)
        drift.resetRenderForRecovery()
        reportedActive = false
    }

    func failForUnavailableReference(_ reason: AecFeedScheduler.FailureReason) async {
        guard started, !reportedFailure, !shutdownGate.isSet, !Task.isCancelled else { return }
        reportedFailure = true
        await statusHandler(.failed(reason))
        let error: CaptureError = switch reason {
        case .referenceStartTimedOut:
            .aecReferenceStartTimedOut
        case .referenceRecoveryTimedOut:
            .aecReferenceRecoveryTimedOut
        }
        await finishCapture(error: error)
    }

    /// 30秒(3000フレーム)ごとにドリフト計測値を残す(補正判断の材料)。
    func logDriftIfNeeded() {
        guard processedFrames % 3000 == 0 else { return }
        let capture = drift.capturePPM.map { String(format: "%.1f", $0) } ?? "n/a"
        let render = drift.renderPPM.map { String(format: "%.1f", $0) } ?? "n/a"
        logger.notice(
            """
            aec drift ppm: capture=\(capture, privacy: .public) \
            render=\(render, privacy: .public)
            """
        )
    }

    static func currentHostSeconds() -> TimeInterval {
        AVAudioTime.seconds(forHostTime: mach_absolute_time())
    }

    static func int16Samples(of buffer: AVAudioPCMBuffer) -> [Int16]? {
        guard let data = buffer.int16ChannelData else { return nil }
        return Array(UnsafeBufferPointer(start: data[0], count: Int(buffer.frameLength)))
    }
}

extension AecPump {
    static func makeBuffer(from frame: AecFrame) -> AVAudioPCMBuffer? {
        guard let format = aecFormat,
              let buffer = AVAudioPCMBuffer(
                  pcmFormat: format,
                  frameCapacity: AVAudioFrameCount(frame.samples.count)
              ),
              let channel = buffer.int16ChannelData
        else {
            return nil
        }
        frame.samples.withUnsafeBufferPointer { source in
            if let base = source.baseAddress {
                channel[0].update(from: base, count: frame.samples.count)
            }
        }
        buffer.frameLength = AVAudioFrameCount(frame.samples.count)
        return buffer
    }
}
