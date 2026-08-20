import AVFoundation
import Foundation
import MimizukuCore

extension AudioSessionController {
    struct StreamSession {
        let stream: StreamKind
        let engine: SpeechEngine
        let recorder: AudioFileWriter
    }

    struct StreamExecution {
        let sessions: [StreamSession]
        let inputs: [StreamKind: any AudioSource]
        let targetFormat: AVAudioFormat
        let transcriptRun: TranscriptRun
        let stopSignal: SessionStopSignal
        let generation: UInt64
        /// この実行が属する診断試行の sink(#75)。UI の generation 判定と独立に
        /// ストリームループから転送するため、実行単位で保持する(stop 直後の start で
        /// 旧 generation になっても、旧試行の Speech final は旧試行へ届く)。
        let diagnostics: AecDiagnosticsRecorder?
    }

    private struct Preparation {
        let streams: [StreamKind]
        let engines: [StreamKind: SpeechEngine]
        let targetFormat: AVAudioFormat
    }

    private struct PreparedSession {
        let streams: [StreamKind]
        let sessions: [StreamSession]
        let targetFormat: AVAudioFormat
        let directory: URL
        let metadata: SessionMetadata
        let transcriptRun: TranscriptRun
        let stopSignal: SessionStopSignal
    }

    private struct PersistenceCommit: Sendable {
        let store: SessionStore
        let metadata: SessionMetadata
        let journalEntries: [TranscriptJournalEntry]
        let incompleteEntries: [TranscriptJournalEntry]
        let sourceRunID: UUID
        let finalStatus: SessionStatus
        let directory: URL
    }

    private enum CaptureSessionOutcome: Equatable {
        case completed
        case interrupted
        case failedStart
        case persistenceFailed
    }

    static let speechFinalizationTimeout: TimeInterval = 5

    func runSession(generation: UInt64) async {
        defer { finishSession(generation: generation) }
        guard let prepared = await prepareSession(generation: generation) else { return }
        // 診断試行(#75)は runSession がローカルに所有する(旧 generation になっても
        // close を省略しない)。生成失敗は診断なしで続行する(正式セッションを止めない)。
        let trial = makeAecDiagnosticsTrial(streams: prepared.streams)
        aecDiagnosticsTrial = trial
        let outcome = await runCaptureSession(
            prepared,
            generation: generation,
            diagnostics: trial?.recorder
        )
        // runStreams 完了後 = Speech results の消費完了後に一度だけ drain/close する
        // (キャンセル・開始失敗・通常終了のすべてがこの経路を通る)。startOffsets は
        // Speech 時刻(セッション原点)と mic 解析原点の対応付けに使う。
        aecDiagnosticsTrial = nil
        if let trial {
            let offsets = await prepared.transcriptRun.snapshot().startOffsets
            await closeAecDiagnostics(trial, speechStartOffsets: offsets)
        }
        if case .failedStart = outcome {
            await discardFailedStart(prepared, generation: generation)
            return
        }
        await finalize(prepared, outcome: outcome, generation: generation)
    }

    private func finishSession(generation: UInt64) {
        finishSessionState(for: generation)
    }

    private func discardFailedStart(
        _ prepared: PreparedSession,
        generation: UInt64
    ) async {
        await discardRecordings(prepared.sessions.map(\.recorder), in: prepared.directory)
        // 参照の開始待ち中にsystem側で生成された結果も正式セッションと一緒に破棄する。
        discardTranscriptLog(for: generation)
    }

    private func finalize(
        _ prepared: PreparedSession,
        outcome: CaptureSessionOutcome,
        generation: UInt64
    ) async {
        let recordings = await closeRecordings(
            prepared.sessions.map(\.recorder),
            in: prepared.directory
        )
        guard recordings.kept, outcome != .persistenceFailed else { return }
        let snapshot = await prepared.transcriptRun.snapshot()
        let metadata = finalizedMetadata(
            prepared.metadata,
            sessions: prepared.sessions,
            durations: recordings.durations,
            fallbackDuration: recordings.longestDuration,
            snapshot: snapshot
        )
        let commit = await PersistenceCommit(
            store: store,
            metadata: metadata,
            journalEntries: snapshot.finalized,
            incompleteEntries: snapshot.incomplete,
            sourceRunID: prepared.transcriptRun.runID,
            finalStatus: outcome == .completed ? .completed : .interrupted,
            directory: prepared.directory
        )
        do {
            _ = try await Self.finalizePersistenceOffMain(commit)
            startConversions(prepared, durations: recordings.durations, generation: generation)
        } catch {
            logger
                .error(
                    "session persistence failed: \(error.localizedDescription, privacy: .public)"
                )
            applyRecordingError(
                "文字起こしの保存に失敗しました(ジャーナルと録音は保持): \(error.localizedDescription)",
                generation: generation
            )
        }
    }

    private func finalizedMetadata(
        _ source: SessionMetadata,
        sessions: [StreamSession],
        durations: [TimeInterval],
        fallbackDuration: TimeInterval,
        snapshot: TranscriptRunSnapshot
    ) -> SessionMetadata {
        var metadata = source
        metadata.duration = zip(sessions, durations).map { session, duration in
            (snapshot.startOffsets[session.stream] ?? 0) + duration
        }.max() ?? fallbackDuration
        metadata.tracks = metadata.tracks.map { track in
            var updated = track
            if let stream = track.origin.streamKind {
                if let offset = snapshot.startOffsets[stream] {
                    updated.startOffset = offset
                }
            }
            return updated
        }
        return metadata
    }

    private func startConversions(
        _ prepared: PreparedSession,
        durations: [TimeInterval],
        generation: UInt64
    ) {
        let completed = zip(prepared.sessions.map(\.recorder), durations)
            .filter { $0.1 > 0 }
        for (recorder, _) in completed {
            convertInBackground(
                caf: recorder.url,
                sessionDirectory: prepared.directory,
                generation: generation
            )
        }
    }

    private nonisolated static func finalizePersistenceOffMain(
        _ commit: PersistenceCommit
    ) async throws -> (metadata: SessionMetadata, transcript: TranscriptDocument) {
        try await commit.store.finalize(
            metadata: commit.metadata,
            journalEntries: commit.journalEntries,
            incompleteEntries: commit.incompleteEntries,
            sourceRunID: commit.sourceRunID,
            finalStatus: commit.finalStatus,
            in: commit.directory
        )
    }

    private func prepareSession(generation: UInt64) async -> PreparedSession? {
        guard let preparation = await preparePrerequisites(generation: generation) else {
            return nil
        }
        let startedAt = Date()
        guard let directory = createSessionDirectory(
            startedAt: startedAt,
            generation: generation
        ) else {
            return nil
        }
        do {
            let prepared = try makePreparedSession(
                preparation: preparation,
                directory: directory,
                startedAt: startedAt
            )
            try store.saveInitialMetadata(prepared.metadata, in: directory)
            activeStopSignal = prepared.stopSignal
            return prepared
        } catch {
            try? FileManager.default.removeItem(at: directory)
            fail(
                "セッションの初期メタデータを保存できませんでした: \(error.localizedDescription)",
                for: generation
            )
            return nil
        }
    }

    private func preparePrerequisites(generation: UInt64) async -> Preparation? {
        await prepareAssets()
        guard isCurrentSession(generation), !Task.isCancelled else { return nil }
        guard case .ready = assetStatus else { return nil }
        guard let targetFormat = await engine.bestInputFormat() else {
            fail("文字起こしに対応する音声フォーマットが取得できませんでした。", for: generation)
            return nil
        }
        guard isCurrentSession(generation), !Task.isCancelled else { return nil }
        let streams = selection.streams
        if streams.contains(.microphone) {
            guard await ensureMicrophonePermission(for: generation) else { return nil }
        }
        guard isCurrentSession(generation), !Task.isCancelled else { return nil }
        guard let engines = await makeEngines(for: streams, generation: generation) else {
            return nil
        }
        guard isCurrentSession(generation), !Task.isCancelled else { return nil }
        return Preparation(streams: streams, engines: engines, targetFormat: targetFormat)
    }

    private func createSessionDirectory(
        startedAt: Date,
        generation: UInt64
    ) -> URL? {
        do {
            return try layout.createSessionDirectory(startedAt: startedAt)
        } catch {
            fail(
                "セッションディレクトリを作成できませんでした: \(error.localizedDescription)",
                for: generation
            )
            return nil
        }
    }

    private func makePreparedSession(
        preparation: Preparation,
        directory: URL,
        startedAt: Date
    ) throws -> PreparedSession {
        let sessionID = UUID()
        let tracks = preparation.streams.map { stream in
            SessionTrack(
                origin: stream.trackOrigin,
                label: stream.displayLabel,
                relativeAudioPath: SessionLayout.recordingFileName(for: stream)
            )
        }
        let trackIDs = Dictionary(uniqueKeysWithValues: zip(preparation.streams, tracks.map(\.id)))
        let metadata = SessionMetadata(
            id: sessionID,
            title: "録音 \(SessionLayout.directoryName(for: startedAt))",
            startedAt: startedAt,
            tracks: tracks
        )
        let stopSignal = SessionStopSignal()
        let transcriptRun = try TranscriptRun(
            sessionID: sessionID,
            trackIDs: trackIDs,
            journalURL: store.journalURL(in: directory)
        )
        let sessions = makeStreamSessions(
            preparation: preparation,
            directory: directory
        )
        return PreparedSession(
            streams: preparation.streams,
            sessions: sessions,
            targetFormat: preparation.targetFormat,
            directory: directory,
            metadata: metadata,
            transcriptRun: transcriptRun,
            stopSignal: stopSignal
        )
    }

    private func makeStreamSessions(
        preparation: Preparation,
        directory: URL
    ) -> [StreamSession] {
        preparation.streams.compactMap { stream in
            guard let streamEngine = preparation.engines[stream] else { return nil }
            let recording = directory.appending(
                component: SessionLayout.recordingFileName(for: stream)
            )
            return StreamSession(
                stream: stream,
                engine: streamEngine,
                recorder: AudioFileWriter(url: recording)
            )
        }
    }

    private func runCaptureSession(
        _ prepared: PreparedSession,
        generation: UInt64,
        diagnostics: AecDiagnosticsRecorder?
    ) async -> CaptureSessionOutcome {
        do {
            let inputs = try await makeInputs(for: prepared.streams, generation: generation)
            guard isCurrentSession(generation), !Task.isCancelled else { return .completed }
            try await runStreams(StreamExecution(
                sessions: prepared.sessions,
                inputs: inputs,
                targetFormat: prepared.targetFormat,
                transcriptRun: prepared.transcriptRun,
                stopSignal: prepared.stopSignal,
                generation: generation,
                diagnostics: diagnostics
            ))
            return .completed
        } catch is CancellationError {
            return .completed
        } catch {
            if Task.isCancelled { return .completed }
            logger.error("session failed: \(error.localizedDescription, privacy: .public)")
            fail(error.localizedDescription, for: generation)
            if error is TranscriptRunError { return .persistenceFailed }
            guard let captureError = error as? CaptureError else { return .interrupted }
            if case .aecReferenceStartTimedOut = captureError { return .failedStart }
            return .interrupted
        }
    }

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
}
