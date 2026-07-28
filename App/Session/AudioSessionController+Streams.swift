import AVFoundation
import MimizukuCore

// MARK: - 捕捉ストリームの実行

extension AudioSessionController {
    /// 各ストリームの `Source → AudioRouter → SpeechEngine` を TaskGroup で並行実行し、
    /// セグメントをライブログへ合流させる。1 つでも失敗したら throw で全体を畳む
    /// (グループのキャンセルで他ストリームの捕捉・録音も解放される)。
    func runStreams(
        _ sessions: [StreamSession],
        inputs: [StreamKind: any AudioSource],
        targetFormat: AVAudioFormat,
        generation: UInt64
    ) async throws {
        let sessionStart = ContinuousClock.now
        let logger = logger
        try await withThrowingTaskGroup(of: Void.self) { group in
            for session in sessions {
                guard let source = inputs[session.stream] else {
                    // 到達しない想定(inputs と sessions は同じ streams から作られる)だが、
                    // 万一の欠損を無言skipにしない(録音・文字起こしの黙殺を許さない)。
                    throw CaptureError.inputUnavailable(session.stream)
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
                        await self?.apply(segment, generation: generation)
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
