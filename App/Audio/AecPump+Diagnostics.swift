import AVFoundation
import MimizukuCore
import OSLog

// MARK: - 診断記録(#75 / ADR-0015)

/// AecPump の診断記録フック。すべて非ブロッキング投入のみで、diagnostics が nil の
/// 場合は RMS 計算も行わない(観測がタイミングを変えないため)。actor 分離が排他を
/// 担保する。
extension AecPump {
    func note(_ record: AecDiagnosticsRecord) {
        diagnostics?.enqueue(.record(record))
    }

    func noteInputChunk(
        _ stream: AecDiagnosticsRecord.ChunkStream,
        observed: TimeInterval,
        normalization: AecTimeline.Normalization,
        sampleCount: Int,
        driftPPM: Double?
    ) {
        guard diagnostics != nil else { return }
        note(.inputChunk(.init(
            stream: stream,
            observedHostTime: observed,
            normalizedHostTime: normalization.hostTime,
            sampleCount: sampleCount,
            timingDeltaMs: normalization.delta.map { $0 * 1000 },
            rebased: normalization.rebased,
            epoch: epoch,
            driftPPM: driftPPM
        )))
    }

    func noteAlignerEvents(_ events: [AecAligner.Event]) {
        guard diagnostics != nil else { return }
        for event in events {
            switch event {
            case let .lateRenderDropped(hostTime):
                note(.event(.init(kind: .lateRenderDropped, hostTime: hostTime, epoch: epoch)))
            case let .queueOverflowDropped(firstHostTime, frameCount):
                note(.event(.init(
                    kind: .renderQueueOverflowDropped,
                    firstHostTime: firstHostTime,
                    frameCount: frameCount,
                    epoch: epoch
                )))
            case let .leadRenderDropped(firstHostTime, lastHostTime, frameCount):
                note(.event(.init(
                    kind: .leadRenderDropped,
                    firstHostTime: firstHostTime,
                    lastHostTime: lastHostTime,
                    frameCount: frameCount,
                    epoch: epoch
                )))
            }
        }
    }

    /// 1 秒(100 処理フレーム)ごとに APM 内部統計を記録する。
    func noteApmStatsIfNeeded() {
        guard diagnostics != nil, processedFrames % 100 == 0 else { return }
        let stats = bridge.statistics()
        note(.apmStats(.init(
            hostTime: Self.currentHostSeconds(),
            echoReturnLoss: stats.hasEchoReturnLoss.boolValue ? stats.echoReturnLoss : nil,
            echoReturnLossEnhancement: stats.hasEchoReturnLossEnhancement.boolValue
                ? stats.echoReturnLossEnhancement : nil,
            delayMs: stats.hasDelayMs.boolValue ? stats.delayMs : nil,
            delayMedianMs: stats.hasDelayMedianMs.boolValue ? stats.delayMedianMs : nil,
            delayStdMs: stats.hasDelayStdMs.boolValue ? stats.delayStdMs : nil,
            divergentFilterFraction: stats.hasDivergentFilterFraction.boolValue
                ? stats.divergentFilterFraction : nil,
            residualEchoLikelihood: stats.hasResidualEchoLikelihood.boolValue
                ? stats.residualEchoLikelihood : nil
        )))
    }

    /// framer の持ち越し破棄(production 正常動作)を hostTime 付きで残す。
    func noteFramerDiscard(
        _ kind: AecDiagnosticsRecord.EventKind,
        _ discarded: AecFramer.DiscardedRemainder
    ) {
        note(.event(.init(
            kind: kind,
            hostTime: discarded.hostTime,
            sampleCount: discarded.sampleCount,
            epoch: epoch
        )))
    }

    /// framer 通過後の実参照フレーム(aligner へ入る前)を記録する。
    func recordRenderReceived(_ frame: AecFrame) {
        guard let diagnostics else { return }
        diagnostics.enqueue(.renderReceived(
            .init(
                renderFrameIndex: renderFrameIndex,
                hostTime: frame.hostTime,
                epoch: epoch,
                rmsDBFS: AecAudioMetrics.rmsDBFS(frame.samples)
            ),
            samples: frame.samples
        ))
    }

    /// APM へ給餌した参照フレーム(充填無音を含む)を記録する。
    func recordRenderFed(_ render: AecAligner.RenderFeed) {
        guard let diagnostics else { return }
        diagnostics.enqueue(.renderFed(
            .init(
                fedIndex: fedIndex,
                hostTime: render.frame.hostTime,
                epoch: epoch,
                provenance: render.provenance == .actual ? .actual : .gapFilled,
                fedBeforeCaptureFrameIndex: captureFrameIndex,
                rmsDBFS: AecAudioMetrics.rmsDBFS(render.frame.samples)
            ),
            samples: render.frame.samples
        ))
    }

    /// 無音置換フレームの記録。raw は無音置換中も原音を残す(開始待ち・復旧中の
    /// 実際の回り込み量を観測するため)。processed は正式出力どおりゼロ。
    func recordSilencedCapture(_ capture: AecFrame, zeros: [Int16]) {
        guard let diagnostics else { return }
        diagnostics.enqueue(.capture(
            .init(
                frameIndex: captureFrameIndex,
                outputFrameIndex: outputFrameIndex,
                speechTimeSeconds: Double(outputFrameIndex) * 0.01,
                hostTime: capture.hostTime,
                silenced: true,
                epoch: epoch,
                rawRMSDBFS: AecAudioMetrics.rmsDBFS(capture.samples),
                processedRMSDBFS: nil,
                renderFedCount: 0
            ),
            raw: capture.samples,
            processed: zeros
        ))
    }

    /// APM 処理済みフレームの記録(raw = APM 直前、processed = APM 出力)。
    func recordProcessedCapture(
        _ capture: AecFrame,
        processed: [Int16],
        renderFedCount: Int
    ) {
        guard let diagnostics else { return }
        diagnostics.enqueue(.capture(
            .init(
                frameIndex: captureFrameIndex,
                outputFrameIndex: outputFrameIndex,
                speechTimeSeconds: Double(outputFrameIndex) * 0.01,
                hostTime: capture.hostTime,
                silenced: false,
                epoch: epoch,
                rawRMSDBFS: AecAudioMetrics.rmsDBFS(capture.samples),
                processedRMSDBFS: AecAudioMetrics.rmsDBFS(processed),
                renderFedCount: renderFedCount
            ),
            raw: capture.samples,
            processed: processed
        ))
    }
}
