import AVFoundation
import MimizukuCore

// MARK: - 捕捉ストリームの実行

extension AudioSessionController {
    /// 各ストリームの `Source → AudioRouter → SpeechEngine` を TaskGroup で並行実行し、
    /// セグメントをライブログへ合流させる。1 つでも失敗したら throw で全体を畳む
    /// (グループのキャンセルで他ストリームの捕捉・録音も解放される)。
    func runStreams(_ execution: StreamExecution) async throws {
        let sessionStart = ContinuousClock.now
        let logger = logger
        var routedSessions: [(session: StreamSession, source: RoutedAudioSource)] = []
        for session in execution.sessions {
            guard let source = execution.inputs[session.stream] else {
                throw CaptureError.inputUnavailable(session.stream)
            }
            let label = session.stream.rawValue
            let stream = session.stream
            let routed = AudioRouter.route(
                source: source,
                transcriptionFormat: execution.targetFormat,
                recorder: session.recorder
            ) {
                // 全Speech時刻の原点をrunStreams開始へ揃え、ストリーム開始差を保持する。
                let offset = sessionStart.duration(to: .now) / .seconds(1)
                await execution.transcriptRun.setStartOffset(offset, for: stream)
                let ms = Int((offset * 1000).rounded())
                logger.notice(
                    "first buffer (\(label, privacy: .public)): +\(ms, privacy: .public)ms"
                )
            }
            routedSessions.append((session, routed))
        }
        let stopTask = Task {
            for await _ in execution.stopSignal.events {
                for routed in routedSessions {
                    routed.source.stop()
                }
                break
            }
        }
        defer { stopTask.cancel() }

        try await withThrowingTaskGroup(of: Void.self) { group in
            for routedSession in routedSessions {
                let session = routedSession.session
                let streamEngine = session.engine
                let routed = routedSession.source
                group.addTask { [weak self] in
                    for try await segment in streamEngine.segments(from: routed) {
                        // finalはwrite-through同期後にだけUIへ反映する。kill -9で表示済みの
                        // 確定行だけが失われる状態を作らない。
                        let persisted = try await execution.transcriptRun.apply(segment)
                        // 診断への転送は generation 非依存(この実行の試行へ届ける。
                        // stop 直後の start で旧 generation になっても final を失わない)。
                        execution.diagnostics?.enqueueSpeech(persisted)
                        await self?.apply(persisted, generation: execution.generation)
                    }
                }
            }
            try await group.waitForAll()
        }
    }

    /// セグメントをライブログへ適用する(TaskGroup の子タスクからMainActorへ合流)。
    private func apply(_ segment: TranscriptSegment, generation: UInt64) {
        applyTranscript(segment, generation: generation)
    }
}
