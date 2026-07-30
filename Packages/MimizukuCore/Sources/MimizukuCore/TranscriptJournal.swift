import Foundation

public enum TranscriptJournalError: Error, Equatable {
    case unsupportedSchemaVersion(Int)
    case corruptLine(Int)
    case inconsistentSession(line: Int)
    case inconsistentRun(line: Int)
    case invalidSequence(line: Int, expected: UInt64, actual: UInt64)
}

public struct TranscriptJournalContents: Sendable, Equatable {
    public var entries: [TranscriptJournalEntry]
    public var ignoredIncompleteTrailingLine: Bool

    public init(
        entries: [TranscriptJournalEntry],
        ignoredIncompleteTrailingLine: Bool
    ) {
        self.entries = entries
        self.ignoredIncompleteTrailingLine = ignoredIncompleteTrailingLine
    }
}

public struct TranscriptJournalReader: Sendable {
    public init() {}

    public func read(from url: URL) throws -> TranscriptJournalContents {
        let data = try Data(contentsOf: url)
        guard !data.isEmpty else {
            return TranscriptJournalContents(
                entries: [],
                ignoredIncompleteTrailingLine: false
            )
        }
        let complete = Self.completeLines(in: data)
        let decoder = JSONDecoder()
        var entries: [TranscriptJournalEntry] = []
        for (offset, bytes) in complete.lines.enumerated() {
            let line = offset + 1
            let entry = try Self.decode(bytes, line: line, using: decoder)
            try Self.validate(entry, against: entries.first, count: entries.count, line: line)
            entries.append(entry)
        }
        return TranscriptJournalContents(
            entries: entries,
            ignoredIncompleteTrailingLine: complete.ignoredTrailing
        )
    }

    private static func completeLines(
        in data: Data
    ) -> (lines: [Data.SubSequence], ignoredTrailing: Bool) {
        let endsWithNewline = data.last == newline
        var lines = data.split(separator: newline, omittingEmptySubsequences: false)
        if endsWithNewline {
            lines.removeLast()
        } else {
            lines.removeLast()
        }
        return (lines, !endsWithNewline)
    }

    private static func decode(
        _ bytes: Data.SubSequence,
        line: Int,
        using decoder: JSONDecoder
    ) throws -> TranscriptJournalEntry {
        guard !bytes.isEmpty else { throw TranscriptJournalError.corruptLine(line) }
        do {
            return try decoder.decode(TranscriptJournalEntry.self, from: Data(bytes))
        } catch {
            throw TranscriptJournalError.corruptLine(line)
        }
    }

    private static func validate(
        _ entry: TranscriptJournalEntry,
        against first: TranscriptJournalEntry?,
        count: Int,
        line: Int
    ) throws {
        guard entry.schemaVersion == SessionSchema.currentJournalVersion else {
            throw TranscriptJournalError.unsupportedSchemaVersion(entry.schemaVersion)
        }
        if let first {
            guard entry.sessionID == first.sessionID else {
                throw TranscriptJournalError.inconsistentSession(line: line)
            }
            guard entry.runID == first.runID else {
                throw TranscriptJournalError.inconsistentRun(line: line)
            }
        }
        let expected = UInt64(count + 1)
        guard entry.sequence == expected else {
            throw TranscriptJournalError.invalidSequence(
                line: line,
                expected: expected,
                actual: entry.sequence
            )
        }
    }

    private static let newline: UInt8 = 0x0A
}

public actor TranscriptJournalWriter {
    public let url: URL
    public let sessionID: UUID
    public let runID: UUID

    private var nextSequence: UInt64
    private let encoder = JSONEncoder()

    public init(
        url: URL,
        sessionID: UUID,
        runID: UUID = UUID(),
        nextSequence: UInt64 = 1
    ) throws {
        self.url = url
        self.sessionID = sessionID
        self.runID = runID
        self.nextSequence = nextSequence
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: url.path) {
            guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
                throw CocoaError(.fileWriteUnknown)
            }
        }
    }

    @discardableResult
    public func append(
        sourceSegmentID: UUID,
        trackID: UUID,
        text: String,
        start: TimeInterval?,
        end: TimeInterval?,
        isComplete: Bool = true
    ) throws -> TranscriptJournalEntry {
        let entry = TranscriptJournalEntry(
            sessionID: sessionID,
            runID: runID,
            sequence: nextSequence,
            sourceSegmentID: sourceSegmentID,
            trackID: trackID,
            text: text,
            start: start,
            end: end,
            isComplete: isComplete
        )
        var data = try encoder.encode(entry)
        data.append(0x0A)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
        try handle.synchronize()
        nextSequence += 1
        return entry
    }

    public var lastSequence: UInt64 {
        nextSequence - 1
    }
}
