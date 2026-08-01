import AVFoundation
import Foundation
import Synchronization

/// pump / applyTranscript から診断 writer への非同期メッセージ。
/// 音声サンプルとレコードを同一メッセージで運び、CAF 位置と JSONL の対応を崩さない。
public enum AecDiagnosticsMessage: Sendable {
    case capture(AecDiagnosticsRecord.Capture, raw: [Int16], processed: [Int16])
    case renderReceived(AecDiagnosticsRecord.RenderReceived, samples: [Int16])
    case renderFed(AecDiagnosticsRecord.RenderFed, samples: [Int16])
    case record(AecDiagnosticsRecord)
    case speech(AecSpeechRecord)
}

/// 診断レコードの非ブロッキング投入口(#75 / ADR-0015)。
///
/// pump actor 上ではエンコードもファイル IO も行わない ―― 有限バッファへの
/// `yield` のみで、観測が capture/render の到着タイミングへ影響しないようにする。
/// バッファ溢れは数え、1 件でも落ちた試行は valid=false になる(CLI が正式数値を
/// 出さない)。
public final class AecDiagnosticsRecorder: Sendable {
    private let continuation: AsyncStream<AecDiagnosticsMessage>.Continuation
    private let dropped = Mutex(0)

    init(continuation: AsyncStream<AecDiagnosticsMessage>.Continuation) {
        self.continuation = continuation
    }

    public var droppedRecords: Int {
        dropped.withLock { $0 }
    }

    public func enqueue(_ message: AecDiagnosticsMessage) {
        if case .dropped = continuation.yield(message) {
            dropped.withLock { $0 += 1 }
        }
    }

    /// 文字起こしの写しを speech.jsonl へ投入する(#75)。正式なセッションデータ
    /// (ADR-0007)には書かない。start/end は TranscriptRun がセッション原点
    /// (runStreams 開始)へシフトした後の値 ―― mic 解析原点
    /// (`AecDiagnosticsRecord.Capture.speechTimeSeconds`)との対応は meta の
    /// `speechStartOffsets` で取る。呼び出しは各セッションのストリームループから
    /// 行い、UI の generation 判定に依存させない(stop 直後の start で旧試行の
    /// final が失われないように)。
    public func enqueueSpeech(_ segment: TranscriptSegment) {
        enqueue(.speech(AecSpeechRecord(
            stream: segment.stream.rawValue,
            text: segment.text,
            isFinal: segment.isFinal,
            start: segment.start,
            end: segment.end
        )))
    }

    fileprivate func finish() {
        continuation.finish()
    }
}

/// 1 診断試行の所有物(ディレクトリ + recorder + writer Task)。
///
/// 所有者はセッション制御層。AecPump は `pumpFinished` イベントを送るだけで
/// close しない(Speech の final は音声終了後の finalize でも届くため、close は
/// runStreams 完了後に所有者が一度だけ行う)。`close()` は冪等。
public final class AecDiagnosticsTrial: Sendable {
    public let recorder: AecDiagnosticsRecorder
    public let directory: URL
    private let mode: String
    private let startedAt: Date
    private let startHostTime: Double
    private let writerTask: Task<WriterOutcome, Never>
    /// 最初の close が作る確定 Task。以降の close はこれを待つだけ(meta の二重書き込みを
    /// 構造的に防ぐ exactly-once)。
    private let closeTask = Mutex<Task<AecDiagnosticsMeta, Never>?>(nil)

    fileprivate struct WriterOutcome: Sendable {
        var captureFrameCount = 0
        var renderReceivedFrameCount = 0
        var renderFedFrameCount = 0
        var writeErrors: [String] = []
    }

    /// - Parameters:
    ///   - directory: `AecDiagnosticsLayout.createTrialDirectory` で作成済みの
    ///     試行ディレクトリ(上書き禁止 ―― ADR-0015 の 2)。
    ///   - bufferCapacity: 有限バッファ長。既定 2048 ≒ 6 秒分の余裕。溢れたら最新を
    ///     落として数える(テストからは小さい値を注入できる)。
    public init(
        directory: URL,
        mode: String,
        startedAt: Date,
        startHostTime: Double,
        bufferCapacity: Int = 2048
    ) {
        self.directory = directory
        self.mode = mode
        self.startedAt = startedAt
        self.startHostTime = startHostTime
        let (stream, continuation) = AsyncStream.makeStream(
            of: AecDiagnosticsMessage.self,
            bufferingPolicy: .bufferingOldest(bufferCapacity)
        )
        recorder = AecDiagnosticsRecorder(continuation: continuation)
        writerTask = Task.detached(priority: .utility) {
            await Self.runWriter(stream: stream, directory: directory)
        }
    }

    /// writer を drain して close し、meta.json を確定して返す。冪等
    /// (2 回目以降は最初の close の確定結果を待って返すだけで何もしない)。
    @discardableResult
    public func close(speechStartOffsets: [String: Double] = [:]) async -> AecDiagnosticsMeta {
        let task = closeTask.withLock { existing in
            if let existing { return existing }
            let created = Task { await self.performClose(speechStartOffsets: speechStartOffsets) }
            existing = created
            return created
        }
        return await task.value
    }

    private func performClose(speechStartOffsets: [String: Double]) async -> AecDiagnosticsMeta {
        recorder.finish()
        let outcome = await writerTask.value
        var reasons = outcome.writeErrors
        let droppedRecords = recorder.droppedRecords
        if droppedRecords > 0 {
            reasons.append("writerOverflow: \(droppedRecords) records dropped")
        }
        let meta = AecDiagnosticsMeta(
            trialID: directory.lastPathComponent,
            mode: mode,
            startedAt: startedAt,
            startHostTime: startHostTime,
            valid: reasons.isEmpty,
            invalidReasons: reasons,
            droppedRecords: droppedRecords,
            captureFrameCount: outcome.captureFrameCount,
            renderReceivedFrameCount: outcome.renderReceivedFrameCount,
            renderFedFrameCount: outcome.renderFedFrameCount,
            speechStartOffsets: speechStartOffsets
        )
        do {
            let line = try AecDiagnosticsJSONL.encode(meta)
            let url = directory.appending(component: AecDiagnosticsLayout.metaFileName)
            try Data((line + "\n").utf8).write(to: url)
        } catch {
            // meta が書けない試行は CLI が「meta.json を読めません」として拒否する。
        }
        return meta
    }

    // MARK: - writer 本体(単一 Task、順次書き込み)

    private struct WriterFiles {
        let captureRaw: AudioFileWriter
        let captureProcessed: AudioFileWriter
        let renderReceived: AudioFileWriter
        let renderFed: AudioFileWriter
        let frames: AecJSONLFile
        let speech: AecJSONLFile

        init(directory: URL) {
            captureRaw = AudioFileWriter(
                url: directory.appending(component: AecDiagnosticsLayout.captureRawFileName)
            )
            captureProcessed = AudioFileWriter(
                url: directory.appending(
                    component: AecDiagnosticsLayout.captureProcessedFileName
                )
            )
            renderReceived = AudioFileWriter(
                url: directory.appending(component: AecDiagnosticsLayout.renderReceivedFileName)
            )
            renderFed = AudioFileWriter(
                url: directory.appending(component: AecDiagnosticsLayout.renderFedFileName)
            )
            frames = AecJSONLFile(
                url: directory.appending(component: AecDiagnosticsLayout.framesFileName)
            )
            speech = AecJSONLFile(
                url: directory.appending(component: AecDiagnosticsLayout.speechFileName)
            )
        }

        /// 全ファイルを閉じる。close 時のエラーも診断経路の欠損として返す(握りつぶさない)。
        func closeAll() async -> [String] {
            _ = await captureRaw.finish()
            _ = await captureProcessed.finish()
            _ = await renderReceived.finish()
            _ = await renderFed.finish()
            var errors: [String] = []
            do { try frames.close() } catch {
                errors.append("closeError(frames.jsonl): \(error.localizedDescription)")
            }
            do { try speech.close() } catch {
                errors.append("closeError(speech.jsonl): \(error.localizedDescription)")
            }
            return errors
        }
    }

    private static func runWriter(
        stream: AsyncStream<AecDiagnosticsMessage>,
        directory: URL
    ) async -> WriterOutcome {
        var outcome = WriterOutcome()
        let files = WriterFiles(directory: directory)
        for await message in stream {
            // 最初の書き込み失敗以降は drain のみ(CAF 位置と JSONL の対応を保ったまま
            // 打ち切る)。試行は invalid になり、CLI が理由付きで拒否する。
            guard outcome.writeErrors.isEmpty else { continue }
            do {
                try await write(message, to: files, outcome: &outcome)
            } catch {
                outcome.writeErrors.append("writeError: \(error.localizedDescription)")
            }
        }
        await outcome.writeErrors.append(contentsOf: files.closeAll())
        return outcome
    }

    private static func write(
        _ message: AecDiagnosticsMessage,
        to files: WriterFiles,
        outcome: inout WriterOutcome
    ) async throws {
        switch message {
        case let .capture(record, raw, processed):
            try await files.captureRaw.write(makeBuffer(from: raw))
            try await files.captureProcessed.write(makeBuffer(from: processed))
            try files.frames.append(AecDiagnosticsRecord.capture(record))
            outcome.captureFrameCount += 1
        case let .renderReceived(record, samples):
            try await files.renderReceived.write(makeBuffer(from: samples))
            try files.frames.append(AecDiagnosticsRecord.renderReceived(record))
            outcome.renderReceivedFrameCount += 1
        case let .renderFed(record, samples):
            try await files.renderFed.write(makeBuffer(from: samples))
            try files.frames.append(AecDiagnosticsRecord.renderFed(record))
            outcome.renderFedFrameCount += 1
        case let .record(record):
            try files.frames.append(record)
        case let .speech(record):
            try files.speech.append(record)
        }
    }

    private enum WriterError: Error {
        case bufferAllocationFailed
    }

    private static let format = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: 48000,
        channels: 1,
        interleaved: true
    )

    private static func makeBuffer(from samples: [Int16]) throws -> AVAudioPCMBuffer {
        guard let format,
              let buffer = AVAudioPCMBuffer(
                  pcmFormat: format,
                  frameCapacity: AVAudioFrameCount(samples.count)
              ),
              let channel = buffer.int16ChannelData
        else {
            throw WriterError.bufferAllocationFailed
        }
        samples.withUnsafeBufferPointer { source in
            if let base = source.baseAddress {
                channel[0].update(from: base, count: samples.count)
            }
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        return buffer
    }
}

/// JSONL の追記ファイル(writer Task 内でのみ使用 ―― 単一消費者)。
private final class AecJSONLFile {
    private let url: URL
    private var handle: FileHandle?
    private var opened = false

    init(url: URL) {
        self.url = url
    }

    func append(_ record: some Encodable) throws {
        if !opened {
            opened = true
            FileManager.default.createFile(atPath: url.path, contents: nil)
            handle = try FileHandle(forWritingTo: url)
        }
        guard let handle else {
            throw CocoaError(.fileWriteUnknown)
        }
        let line = try AecDiagnosticsJSONL.encode(record)
        try handle.write(contentsOf: Data((line + "\n").utf8))
    }

    func close() throws {
        defer { handle = nil }
        try handle?.close()
    }
}
