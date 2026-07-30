import Foundation
import Testing

@testable import MimizukuCore

@Suite("TranscriptJournal")
struct TranscriptJournalTests {
    @Test("追記ごとにsequenceを増やし同期済みJSONLとして読める")
    func roundTrip() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let writer = try TranscriptJournalWriter(
            url: fixture.url,
            sessionID: fixture.sessionID,
            runID: fixture.runID
        )

        let first = try await writer.append(
            sourceSegmentID: UUID(),
            trackID: fixture.trackID,
            text: "一",
            start: 0,
            end: 1
        )
        let second = try await writer.append(
            sourceSegmentID: UUID(),
            trackID: fixture.trackID,
            text: "二",
            start: 1,
            end: 2
        )
        let contents = try TranscriptJournalReader().read(from: fixture.url)

        #expect(first.sequence == 1)
        #expect(second.sequence == 2)
        #expect(contents.entries.map(\.text) == ["一", "二"])
        #expect(!contents.ignoredIncompleteTrailingLine)
    }

    @Test("クラッシュで切れた末尾行だけを無視する")
    func ignoresOnlyIncompleteTrailingLine() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let writer = try TranscriptJournalWriter(
            url: fixture.url,
            sessionID: fixture.sessionID,
            runID: fixture.runID
        )
        _ = try await writer.append(
            sourceSegmentID: UUID(),
            trackID: fixture.trackID,
            text: "保存済み",
            start: 0,
            end: 1
        )
        let handle = try FileHandle(forWritingTo: fixture.url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(#"{"schemaVersion":1"#.utf8))
        try handle.close()

        let contents = try TranscriptJournalReader().read(from: fixture.url)
        #expect(contents.entries.map(\.text) == ["保存済み"])
        #expect(contents.ignoredIncompleteTrailingLine)
    }

    @Test("途中の破損行は黙って欠落させない")
    func rejectsMiddleCorruption() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let entry = TranscriptJournalEntry(
            sessionID: fixture.sessionID,
            runID: fixture.runID,
            sequence: 1,
            sourceSegmentID: UUID(),
            trackID: fixture.trackID,
            text: "正常",
            start: 0,
            end: 1
        )
        var data = try JSONEncoder().encode(entry)
        data.append(Data("\n壊れた行\n".utf8))
        try data.write(to: fixture.url)

        #expect(throws: TranscriptJournalError.corruptLine(2)) {
            try TranscriptJournalReader().read(from: fixture.url)
        }
    }

    @Test("未知のschema versionを拒否する")
    func rejectsUnknownVersion() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let entry = TranscriptJournalEntry(
            schemaVersion: 99,
            sessionID: fixture.sessionID,
            runID: fixture.runID,
            sequence: 1,
            sourceSegmentID: UUID(),
            trackID: fixture.trackID,
            text: "未来",
            start: 0,
            end: 1
        )
        var data = try JSONEncoder().encode(entry)
        data.append(0x0A)
        try data.write(to: fixture.url)

        #expect(throws: TranscriptJournalError.unsupportedSchemaVersion(99)) {
            try TranscriptJournalReader().read(from: fixture.url)
        }
    }

    @Test("sequenceの欠落を破損として報告する")
    func rejectsSequenceGap() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let entry = TranscriptJournalEntry(
            sessionID: fixture.sessionID,
            runID: fixture.runID,
            sequence: 2,
            sourceSegmentID: UUID(),
            trackID: fixture.trackID,
            text: "二",
            start: 1,
            end: 2
        )
        var data = try JSONEncoder().encode(entry)
        data.append(0x0A)
        try data.write(to: fixture.url)

        #expect(
            throws: TranscriptJournalError.invalidSequence(line: 1, expected: 1, actual: 2)
        ) {
            try TranscriptJournalReader().read(from: fixture.url)
        }
    }

    private struct Fixture {
        let directory: URL
        let url: URL
        let sessionID = UUID()
        let runID = UUID()
        let trackID = UUID()

        init() throws {
            directory = FileManager.default.temporaryDirectory
                .appending(component: "TranscriptJournalTests-\(UUID().uuidString)")
            url = directory.appending(component: "transcript.journal.jsonl")
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        }

        func cleanup() {
            try? FileManager.default.removeItem(at: directory)
        }
    }
}
