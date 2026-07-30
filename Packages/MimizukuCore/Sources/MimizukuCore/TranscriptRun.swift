import Foundation

public enum TranscriptRunError: Error, Equatable {
    case missingTrack(StreamKind)
    case journalWriteFailed
}

public struct TranscriptRunSnapshot: Sendable, Equatable {
    public var finalized: [TranscriptJournalEntry]
    public var incomplete: [TranscriptJournalEntry]
    public var startOffsets: [StreamKind: TimeInterval]

    public init(
        finalized: [TranscriptJournalEntry],
        incomplete: [TranscriptJournalEntry],
        startOffsets: [StreamKind: TimeInterval]
    ) {
        self.finalized = finalized
        self.incomplete = incomplete
        self.startOffsets = startOffsets
    }
}

/// 1回の認識処理におけるwrite-throughジャーナルとvolatile末尾を直列化する。
///
/// 確定結果はUIへ渡す前に同期済みJSONLへ追記する。volatileはメモリ上だけで更新し、正常停止のfinalizeに失敗または期限超過した場合に限り、未完了末尾としてスナップショットへ渡す。
public actor TranscriptRun {
    public let sessionID: UUID
    public let runID: UUID

    private let trackIDs: [StreamKind: UUID]
    private let writer: TranscriptJournalWriter
    private var finalized: [TranscriptJournalEntry] = []
    private var volatileByStream: [StreamKind: TranscriptSegment] = [:]
    private var startOffsets: [StreamKind: TimeInterval] = [:]

    public init(
        sessionID: UUID,
        runID: UUID = UUID(),
        trackIDs: [StreamKind: UUID],
        journalURL: URL
    ) throws {
        self.sessionID = sessionID
        self.runID = runID
        self.trackIDs = trackIDs
        writer = try TranscriptJournalWriter(
            url: journalURL,
            sessionID: sessionID,
            runID: runID
        )
    }

    public func setStartOffset(_ offset: TimeInterval, for stream: StreamKind) {
        if startOffsets[stream] == nil {
            startOffsets[stream] = max(0, offset)
        }
    }

    /// 確定結果の場合は、返る前にジャーナルへの追記と同期が完了している。
    @discardableResult
    public func apply(_ segment: TranscriptSegment) async throws -> TranscriptSegment {
        guard let trackID = trackIDs[segment.stream] else {
            throw TranscriptRunError.missingTrack(segment.stream)
        }
        let offset = startOffsets[segment.stream] ?? 0
        var normalized = segment
        normalized.start = segment.start.map { $0 + offset }
        normalized.end = segment.end.map { $0 + offset }
        let hasText = !segment.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if segment.isFinal {
            if hasText {
                let entry: TranscriptJournalEntry
                do {
                    entry = try await writer.append(
                        sourceSegmentID: segment.id,
                        trackID: trackID,
                        text: segment.text,
                        start: normalized.start,
                        end: normalized.end
                    )
                } catch {
                    throw TranscriptRunError.journalWriteFailed
                }
                finalized.append(entry)
            }
            volatileByStream[segment.stream] = nil
        } else {
            volatileByStream[segment.stream] = hasText ? normalized : nil
        }
        return normalized
    }

    public func snapshot() -> TranscriptRunSnapshot {
        var nextSequence = (finalized.last?.sequence ?? 0) + 1
        let incomplete = StreamKind.allCases.compactMap { stream -> TranscriptJournalEntry? in
            guard
                let segment = volatileByStream[stream],
                let trackID = trackIDs[stream]
            else {
                return nil
            }
            defer { nextSequence += 1 }
            return TranscriptJournalEntry(
                sessionID: sessionID,
                runID: runID,
                sequence: nextSequence,
                sourceSegmentID: segment.id,
                trackID: trackID,
                text: segment.text,
                start: segment.start,
                end: segment.end,
                isComplete: false
            )
        }
        return TranscriptRunSnapshot(
            finalized: finalized,
            incomplete: incomplete,
            startOffsets: startOffsets
        )
    }
}
