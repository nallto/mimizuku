import AVFoundation
import MimizukuCore
import OSLog
import Synchronization

/// actor hopなしで通常停止を刻み、実行待ちwatchdogの失敗通知を抑止する。
final class AecShutdownGate: Sendable {
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

// MARK: - 処理ヘルパー(AecPump 本体から分離。actor 分離が排他を担保する)

extension AecPump {
    /// 無音置換フレームの出力。raw は原音のまま診断へ残し、正式出力はゼロにする。
    func emitSilenced(_ capture: AecFrame) {
        silencedFrames += 1
        let zeros = [Int16](repeating: 0, count: capture.samples.count)
        recordSilencedCapture(capture, zeros: zeros)
        captureFrameIndex += 1
        output?.yield(AecFrame(samples: zeros, hostTime: capture.hostTime))
        outputFrameIndex += 1
    }

    /// 1 capture を APM へ通して出力する。処理失敗時はストリームを畳み false を返す。
    func processAndEmit(_ capture: AecFrame) async -> Bool {
        let step = aligner.appendCapture(capture)
        noteAlignerEvents(step.events)
        var fedCount = 0
        for render in step.render {
            // render-fed の記録は「APM が実際に受け付けた信号」に限る ―― 受付失敗した
            // フレームを記録すると fed 列と APM 内部時間の 1:1 が崩れる。
            if feedRender(render.frame) {
                recordRenderFed(render)
                fedIndex += 1
                fedCount += 1
            } else {
                logger.error("aec render feed failed")
            }
        }
        var samples = capture.samples
        let processed = samples.withUnsafeMutableBufferPointer { pointer -> Bool in
            guard let base = pointer.baseAddress else { return false }
            return bridge.processCaptureFrame(base)
        }
        guard processed else {
            await finishCapture(error: CaptureError.aecProcessingFailed)
            return false
        }
        recordProcessedCapture(capture, processed: samples, renderFedCount: fedCount)
        captureFrameIndex += 1
        processedFrames += 1
        logDriftIfNeeded()
        noteApmStatsIfNeeded()
        output?.yield(AecFrame(samples: samples, hostTime: capture.hostTime))
        outputFrameIndex += 1
        return true
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
        // pump 終了は writer の close を意味しない ―― Speech の final は音声終了後の
        // finalize でも届くため、close は runStreams 完了後に controller が行う。
        note(.event(.init(
            kind: .pumpFinished,
            hostTime: Self.currentHostSeconds(),
            frameCount: frames,
            epoch: epoch
        )))
        output?.finish(throwing: error)
        output = nil
        started = false
        bridge.shutdown()
    }

    nonisolated func requestShutdown() {
        shutdownGate.set()
    }

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
        epoch += 1
        note(.event(.init(
            kind: .epochReset,
            hostTime: Self.currentHostSeconds(),
            epoch: epoch
        )))
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
