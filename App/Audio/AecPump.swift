import AVFoundation
import MimizukuCore
import OSLog

/// WebRTC AEC3 のライブ適用ポンプ(#63、ADR-0013)。「両方」モード専用。
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

    /// ブリッジ契約の内部フォーマット。
    private static let aecFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: 48000,
        channels: 1,
        interleaved: true
    )

    /// APM を初期化する。失敗時は false(呼び出し側が従来経路へフォールバックする)。
    func start() -> Bool {
        guard Self.aecFormat != nil, bridge.initializeProcessing() else {
            logger.error("aec bridge initialization failed")
            return false
        }
        started = true
        return true
    }

    // MARK: - ストリーム配線(nonisolated アダプタ)

    /// far-end 参照の tee: システム音声を取り込みつつ、バッファをそのまま下流
    /// (相手側の文字起こし・録音)へ流す。取り込みは読み取りのみ(独立コピーへ変換)で、
    /// 下流も読み取りのみのため共有読み取りは安全。
    nonisolated func referenceTee(
        _ upstream: AsyncThrowingStream<TimestampedAudioBuffer, Error>
    ) -> AsyncThrowingStream<AVAudioPCMBuffer, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await item in upstream {
                        await self.ingestRender(item)
                        // バッファは独立コピーの単一系列(TimestampedAudioBuffer の
                        // 正当化コメント参照)。
                        nonisolated(unsafe) let buffer = item.buffer
                        continuation.yield(buffer)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// near-end(マイク)を AEC 処理し、処理後バッファ(48kHz/mono/int16)を流す。
    nonisolated func processedCapture(
        from upstream: AsyncThrowingStream<TimestampedAudioBuffer, Error>
    ) -> AsyncThrowingStream<AVAudioPCMBuffer, Error> {
        let (frames, framesContinuation) = AsyncThrowingStream.makeStream(of: AecFrame.self)
        // 給餌タスク: 出力先を登録してから取り込む(登録前のフレーム欠落を防ぐ順序)。
        let feedTask = Task {
            await self.setOutput(framesContinuation)
            do {
                for try await item in upstream {
                    await self.ingestCapture(item)
                }
                await self.finishCapture(error: nil)
            } catch {
                await self.finishCapture(error: error)
            }
        }
        return AsyncThrowingStream { continuation in
            let mapTask = Task {
                do {
                    for try await frame in frames {
                        guard let buffer = Self.makeBuffer(from: frame) else {
                            throw CaptureError.aecProcessingFailed
                        }
                        continuation.yield(buffer)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                mapTask.cancel()
                feedTask.cancel()
            }
        }
    }

    // MARK: - 取り込み(actor 内)

    private func setOutput(_ continuation: AsyncThrowingStream<AecFrame, Error>.Continuation) {
        output = continuation
    }

    private func ingestRender(_ item: TimestampedAudioBuffer) {
        guard started, let format = Self.aecFormat else { return }
        if renderConverter == nil {
            renderConverter = BufferConverter(from: item.buffer.format, to: format)
        }
        guard let converter = renderConverter,
              let converted = converter.convertedCopy(of: item.buffer),
              let samples = Self.int16Samples(of: converted)
        else {
            // 参照の欠落は aligner の無音充填で吸収される(致命にしない)。
            return
        }
        renderDrift.record(sampleCount: samples.count, hostTime: item.hostTime)
        let time = renderTimeline.normalize(hostTime: item.hostTime, sampleCount: samples.count)
        let frames = renderFramer.append(samples: samples, hostTime: time)
        guard let last = frames.last else { return }
        for frame in frames {
            aligner.appendRender(frame)
        }
        scheduler.advanceRenderFrontier(to: last.hostTime)
        releaseAndProcess()
    }

    private func ingestCapture(_ item: TimestampedAudioBuffer) {
        guard started, let format = Self.aecFormat else { return }
        if captureConverter == nil {
            captureConverter = BufferConverter(from: item.buffer.format, to: format)
        }
        guard let converter = captureConverter,
              let converted = converter.convertedCopy(of: item.buffer),
              let samples = Self.int16Samples(of: converted)
        else {
            // マイク経路の欠損は許さない(録音は処理後ストリームから作られる)。
            finishCapture(error: CaptureError.aecProcessingFailed)
            return
        }
        captureDrift.record(sampleCount: samples.count, hostTime: item.hostTime)
        let time = captureTimeline.normalize(hostTime: item.hostTime, sampleCount: samples.count)
        let now = Self.currentHostSeconds()
        for frame in captureFramer.append(samples: samples, hostTime: time) {
            scheduler.hold(frame, arrivedAt: now)
        }
        releaseAndProcess()
    }

    private func releaseAndProcess(flush: Bool = false) {
        let now = flush ? .infinity : Self.currentHostSeconds()
        for capture in scheduler.release(now: now) {
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
                finishCapture(error: CaptureError.aecProcessingFailed)
                return
            }
            processedFrames += 1
            logDriftIfNeeded()
            output?.yield(AecFrame(samples: samples, hostTime: capture.hostTime))
        }
    }

    private func finishCapture(error: (any Error)?) {
        guard started else {
            output?.finish(throwing: error)
            output = nil
            return
        }
        if error == nil {
            releaseAndProcess(flush: true)
        }
        // Logger の補間は escaping autoclosure でプロパティ直接参照が使えないため、
        // ローカルへ写してから記録する。
        let frames = processedFrames
        let filled = aligner.filledSilenceFrames
        let dropped = aligner.droppedRenderFrames
        let held = scheduler.heldCount
        let captureDiscarded = captureFramer.discardedSamples
        let renderDiscarded = renderFramer.discardedSamples
        let captureRebases = captureTimeline.rebases
        let renderRebases = renderTimeline.rebases
        logger.notice(
            """
            aec finished: frames=\(frames, privacy: .public) \
            filled=\(filled, privacy: .public) \
            droppedRender=\(dropped, privacy: .public) \
            held=\(held, privacy: .public) \
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

    // MARK: - Helpers

    private func feedRender(_ frame: AecFrame) -> Bool {
        frame.samples.withUnsafeBufferPointer { pointer -> Bool in
            guard let base = pointer.baseAddress else { return false }
            return bridge.processRenderFrame(base)
        }
    }

    /// 30 秒(3000 フレーム)ごとにドリフト計測値を残す(補正判断の材料。ADR-0013)。
    private func logDriftIfNeeded() {
        guard processedFrames % 3000 == 0 else { return }
        let capture = captureDrift.driftPPM.map { String(format: "%.1f", $0) } ?? "n/a"
        let render = renderDrift.driftPPM.map { String(format: "%.1f", $0) } ?? "n/a"
        logger.notice(
            "aec drift ppm: capture=\(capture, privacy: .public) render=\(render, privacy: .public)"
        )
    }

    private static func currentHostSeconds() -> TimeInterval {
        AVAudioTime.seconds(forHostTime: mach_absolute_time())
    }

    private static func int16Samples(of buffer: AVAudioPCMBuffer) -> [Int16]? {
        guard let data = buffer.int16ChannelData else { return nil }
        return Array(UnsafeBufferPointer(start: data[0], count: Int(buffer.frameLength)))
    }

    private static func makeBuffer(from frame: AecFrame) -> AVAudioPCMBuffer? {
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
