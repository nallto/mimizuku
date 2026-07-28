import AVFoundation
import MimizukuCore
import OSLog

/// AEC ポンプからセッション制御層へ通知する実行時状態。
enum AecRuntimeStatus: Sendable, Equatable {
    /// 有効な render フレームを初めて受信し、AEC 給餌を開始した。
    case active
    /// 参照を利用できず、マイク原音の素通しへ切り替えた。
    case degraded(AecFeedScheduler.BypassReason)
}

/// WebRTC AEC3 のライブ適用ポンプ(#63 / #64、ADR-0013)。
///
/// far-end(システム音声 tap)を参照として取り込みつつ、near-end(マイク)を
/// 処理して「処理後ストリーム」を返す。処理後音声が文字起こしと録音の両方に流れる
/// (ADR-0013 の 3)。
///
/// - 内部フォーマットは 48kHz / mono / int16 / 10ms(ブリッジ契約)。入出力の変換は
///   遅延生成の `BufferConverter`(最初のバッファのフォーマットから確定)。
/// - 給餌順はホストタイムでマージする(`AecFeedScheduler` ―― 到着順給餌だと実 render が
///   系統的に破棄される。#63 の申し送り)。
/// - tap 再構築中は `AecAligner` の無音充填 + AEC3 の自動再収束(1〜2 秒)で継続する。
/// - ドリフトは計測して notice ログに残すのみ。補正の適用は soak で残留エコーの増悪が
///   観測された場合の後続対応(単点推定のフラッピング回避 ―― #63 の申し送り)。
/// - マイク経路の処理失敗は無言で欠損させず、処理後ストリームを throw で畳んで
///   セッション全体を止める(既存原則)。
actor AecPump {
    private let bridge = AudioProcessingBridge()
    private let logger = Logger(subsystem: "dev.nallto.Mimizuku", category: "aec")
    private let statusHandler: @MainActor @Sendable (AecRuntimeStatus) -> Void

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
    private var renderDrift = AecDriftEstimator()
    private var captureDrift = AecDriftEstimator()
    private var renderConverter: BufferConverter?
    private var captureConverter: BufferConverter?
    private var output: AsyncThrowingStream<AecFrame, Error>.Continuation?
    private var started = false
    private var processedFrames = 0
    private var bypassedFrames = 0
    /// `.active` は初回 render 受信時ではなく、対応する capture を実際に APM へ
    /// 入れた時点で一度だけ通知する。
    private var reportedActive = false
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

    /// APM を初期化する。失敗時は false(呼び出し側が従来経路へフォールバックする)。
    func start() -> Bool {
        guard Self.aecFormat != nil, bridge.initializeProcessing() else {
            logger.error("aec bridge initialization failed")
            return false
        }
        started = true
        return true
    }

    // MARK: - 取り込み(actor 内)

    func setOutput(_ continuation: AsyncThrowingStream<AecFrame, Error>.Continuation) {
        output = continuation
    }

    /// 隠し参照 tap のストリームが失敗して終わった(mic-only)。マイク経路は止めず、
    /// 以後は参照なしで継続する(scheduler の安全弁が実時間で素通し解放する)。
    /// error でなく notice: TCC 未許可等は想定内の劣化で、マイク録音・文字起こしは継続する。
    func noteReferenceFailed(_ error: (any Error)?) async {
        guard started else { return }
        let transitioned = scheduler.markReferenceUnavailable()
        guard transitioned else { return }
        if let error {
            logger.notice(
                "aec hidden reference ended: \(error.localizedDescription, privacy: .public)"
            )
        } else {
            logger.notice("aec hidden reference ended without error")
        }
        await releaseAndProcess()
        await statusHandler(.degraded(.referenceUnavailable))
    }

    func ingestRender(_ item: TimestampedAudioBuffer) async {
        guard started, let format = Self.aecFormat else { return }
        // bypass はセッション中ラッチする。遅れて届いた参照は変換・APM 給餌もしない。
        if case .bypass = scheduler.state { return }
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
        renderDrift.record(sampleCount: samples.count, hostTime: item.hostTime)
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
        scheduler.advanceRenderFrontier(startingAt: first.hostTime, to: last.hostTime)
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
        captureDrift.record(sampleCount: samples.count, hostTime: item.hostTime)
        let time = captureTimeline.normalize(hostTime: item.hostTime, sampleCount: samples.count)
        captureFrontierTime = time + Double(samples.count) / 48000
        let now = Self.currentHostSeconds()
        for frame in captureFramer.append(samples: samples, hostTime: time) {
            scheduler.hold(frame, arrivedAt: now)
        }
        await releaseAndProcess()
    }

    private func releaseAndProcess(flush: Bool = false) async {
        let now = flush ? .infinity : Self.currentHostSeconds()
        let previousState = scheduler.state
        let releases = scheduler.release(now: now)
        let degradedReason = newlyEnteredBypass(after: previousState)
        var becameActive = false
        for release in releases {
            let capture = release.frame
            if release.processing != .aec {
                bypassedFrames += 1
                output?.yield(capture)
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
        if let degradedReason {
            await statusHandler(.degraded(degradedReason))
        }
    }

    func finishCapture(error: (any Error)?) async {
        guard started else {
            output?.finish(throwing: error)
            output = nil
            return
        }
        if error == nil {
            await releaseAndProcess(flush: true)
            // flush 中の APM 失敗は内側の finishCapture が後始末済み。
            guard started else { return }
        }
        // Logger の補間は escaping autoclosure でプロパティ直接参照が使えないため、
        // ローカルへ写してから記録する。
        let frames = processedFrames
        let bypassed = bypassedFrames
        let filled = aligner.filledSilenceFrames
        let dropped = aligner.droppedRenderFrames
        let leadDropped = aligner.droppedLeadRenderFrames
        let held = scheduler.heldCount
        let captureDiscarded = captureFramer.discardedSamples
        let renderDiscarded = renderFramer.discardedSamples
        let captureRebases = captureTimeline.rebases
        let renderRebases = renderTimeline.rebases
        let timeouts = scheduler.timeoutReleases
        let droppedHeld = scheduler.droppedHeldFrames
        let stalled = scheduler.renderStalledReleases
        let warmupBypassed = scheduler.warmupBypassReleases
        logger.notice(
            """
            aec finished: frames=\(frames, privacy: .public) \
            bypassed=\(bypassed, privacy: .public) \
            filled=\(filled, privacy: .public) \
            droppedRender=\(dropped, privacy: .public) \
            leadDropped=\(leadDropped, privacy: .public) \
            held=\(held, privacy: .public) \
            timeoutReleases=\(timeouts, privacy: .public) \
            droppedHeld=\(droppedHeld, privacy: .public) \
            renderStalled=\(stalled, privacy: .public) \
            warmupBypassed=\(warmupBypassed, privacy: .public) \
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

    func newlyEnteredBypass(
        after previousState: AecFeedScheduler.State
    ) -> AecFeedScheduler.BypassReason? {
        guard previousState != scheduler.state else { return nil }
        guard case let .bypass(reason) = scheduler.state else { return nil }
        return reason
    }

    /// 30 秒(3000 フレーム)ごとにドリフト計測値と滞留診断を残す(補正判断の材料。
    /// timeout が render 稼働中に増え続けるならアンカー異常のサイン。ADR-0013 / #63)。
    func logDriftIfNeeded() {
        guard processedFrames % 3000 == 0 else { return }
        let capture = captureDrift.driftPPM.map { String(format: "%.1f", $0) } ?? "n/a"
        let render = renderDrift.driftPPM.map { String(format: "%.1f", $0) } ?? "n/a"
        let timeouts = scheduler.timeoutReleases
        logger.notice(
            """
            aec drift ppm: capture=\(capture, privacy: .public) \
            render=\(render, privacy: .public) timeoutReleases=\(timeouts, privacy: .public)
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
