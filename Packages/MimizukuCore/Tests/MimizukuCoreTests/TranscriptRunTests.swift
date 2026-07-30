import Foundation
import Testing

@testable import MimizukuCore

@Suite("TranscriptRun")
struct TranscriptRunTests {
    @Test("finalは返却前にjournalへ同期し、時刻をセッション原点へ補正する")
    func finalIsWriteThroughWithSessionTime() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let run = try fixture.makeRun()
        await run.setStartOffset(1.25, for: .microphone)

        let normalized = try await run.apply(TranscriptSegment(
            stream: .microphone,
            text: "確定",
            isFinal: true,
            start: 2,
            end: 3
        ))

        #expect(normalized.start == 3.25)
        #expect(normalized.end == 4.25)
        let contents = try TranscriptJournalReader().read(from: fixture.journal)
        #expect(contents.entries.count == 1)
        #expect(contents.entries[0].start == 3.25)
        #expect(contents.entries[0].end == 4.25)
    }

    @Test("volatileはjournalへ書かず最新版だけを未完了末尾として保持する")
    func volatileRemainsInMemoryAsIncompleteTail() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let run = try fixture.makeRun()

        _ = try await run.apply(TranscriptSegment(
            stream: .microphone,
            text: "古い",
            isFinal: false,
            start: 0,
            end: 1
        ))
        _ = try await run.apply(TranscriptSegment(
            stream: .microphone,
            text: "新しい途中",
            isFinal: false,
            start: 0,
            end: 2
        ))
        let snapshot = await run.snapshot()

        #expect(snapshot.finalized.isEmpty)
        #expect(snapshot.incomplete.map(\.text) == ["新しい途中"])
        #expect(snapshot.incomplete.map(\.isComplete) == [false])
        #expect(try Data(contentsOf: fixture.journal).isEmpty)
    }

    @Test("一方のfinalは他トラックのvolatileを消さない")
    func streamsRemainIndependent() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let run = try fixture.makeRun()

        _ = try await run.apply(TranscriptSegment(
            stream: .systemAudio,
            text: "相手の途中",
            isFinal: false
        ))
        _ = try await run.apply(TranscriptSegment(
            stream: .microphone,
            text: "自分の確定",
            isFinal: true
        ))
        let snapshot = await run.snapshot()

        #expect(snapshot.finalized.map(\.text) == ["自分の確定"])
        #expect(snapshot.incomplete.map(\.text) == ["相手の途中"])
    }

    private struct Fixture {
        let directory: URL
        let journal: URL
        let sessionID = UUID()
        let microphoneID = UUID()
        let systemID = UUID()

        init() throws {
            directory = FileManager.default.temporaryDirectory
                .appending(component: "TranscriptRunTests-\(UUID().uuidString)")
            journal = directory.appending(component: "transcript.journal.jsonl")
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        }

        func makeRun() throws -> TranscriptRun {
            try TranscriptRun(
                sessionID: sessionID,
                trackIDs: [
                    .microphone: microphoneID,
                    .systemAudio: systemID
                ],
                journalURL: journal
            )
        }

        func cleanup() {
            try? FileManager.default.removeItem(at: directory)
        }
    }
}
