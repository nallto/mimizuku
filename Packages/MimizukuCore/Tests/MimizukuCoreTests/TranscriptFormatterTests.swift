import Foundation
import Testing

@testable import MimizukuCore

@Suite("TranscriptFormatter")
struct TranscriptFormatterTests {
    private let sessionID = UUID()
    private let runID = UUID()
    private let micID = UUID()
    private let systemID = UUID()

    @Test("句点で分割し、元の時間範囲を比例配分する")
    func splitsSentencesAndPreservesOuterRange() async throws {
        let blocks = try await DefaultTranscriptFormatter().format(entries: [
            entry(1, micID, "一文目です。二文目です。", 10, 14)
        ])

        #expect(blocks.map(\.text) == ["一文目です。", "二文目です。"])
        #expect(blocks.map(\.start) == [10, 12])
        #expect(blocks.map(\.end) == [12, 14])
        #expect(blocks.map(\.isComplete) == [true, true])
    }

    @Test("連続する終端記号だけのブロックを作らない")
    func keepsRepeatedTerminatorsTogether() async throws {
        let blocks = try await DefaultTranscriptFormatter().format(entries: [
            entry(1, micID, "本当？！次です。", 0, 2)
        ])
        #expect(blocks.map(\.text) == ["本当？！", "次です。"])
    }

    @Test("短い無音を跨ぐ未完文を統合する")
    func mergesAdjacentFragments() async throws {
        let blocks = try await DefaultTranscriptFormatter(maximumMergeGap: 1).format(entries: [
            entry(1, micID, "今日は", 0, 1),
            entry(2, micID, "晴れです。", 1.5, 2.5)
        ])

        #expect(blocks.count == 1)
        #expect(blocks[0].text == "今日は晴れです。")
        #expect(blocks[0].start == 0)
        #expect(blocks[0].end == 2.5)
    }

    @Test("異なるトラックは時刻が隣接しても混ぜない")
    func neverMergesTracks() async throws {
        let blocks = try await DefaultTranscriptFormatter().format(entries: [
            entry(1, micID, "自分の発話", 0, 1),
            entry(2, systemID, "相手の発話", 1, 2)
        ])

        #expect(blocks.map(\.trackID) == [micID, systemID])
        #expect(blocks.map(\.text) == ["自分の発話", "相手の発話"])
    }

    @Test("別トラックの到着を挟んでも各トラックの隣接断片を独立に統合する")
    func mergesTrackLocalAdjacency() async throws {
        let blocks = try await DefaultTranscriptFormatter().format(entries: [
            entry(1, micID, "今日は", 0, 1),
            entry(2, systemID, "はい。", 1, 2),
            entry(3, micID, "晴れです。", 1, 2)
        ])

        #expect(blocks.map(\.trackID) == [micID, systemID])
        #expect(blocks.map(\.text) == ["今日は晴れです。", "はい。"])
    }

    @Test("長い無音区間ではブロックを分ける")
    func longGapSeparatesBlocks() async throws {
        let blocks = try await DefaultTranscriptFormatter(maximumMergeGap: 1).format(entries: [
            entry(1, micID, "前半", 0, 1),
            entry(2, micID, "後半", 3, 4)
        ])
        #expect(blocks.count == 2)
    }

    @Test("未完了末尾を捨てず、未完了のまま保持する")
    func preservesIncompleteTail() async throws {
        let blocks = try await DefaultTranscriptFormatter().format(entries: [
            entry(1, micID, "確定。", 0, 1),
            entry(2, micID, "言いかけ", 1, 2, complete: false)
        ])
        #expect(blocks.map(\.text) == ["確定。", "言いかけ"])
        #expect(blocks.map(\.isComplete) == [true, false])
    }

    @Test("逆転した時間範囲を拒否する")
    func rejectsInvalidRange() async {
        await #expect(throws: TranscriptFormattingError.invalidTimeRange(sequence: 1)) {
            try await DefaultTranscriptFormatter().format(entries: [
                entry(1, micID, "逆転", 2, 1)
            ])
        }
    }

    @Test("非同期推論を行う将来の整形器も同じ契約へ適合できる")
    func supportsAsynchronousFormatterImplementations() async throws {
        let formatter: any TranscriptFormatting = SuspendingFormatter()
        let blocks = try await formatter.format(entries: [
            entry(1, micID, "非同期。", 0, 1)
        ])

        #expect(blocks.map(\.trackID) == [micID])
        #expect(blocks.map(\.text) == ["非同期。"])
        #expect(blocks.map(\.start) == [0])
        #expect(blocks.map(\.end) == [1])
    }

    private func entry(
        _ sequence: UInt64,
        _ trackID: UUID,
        _ text: String,
        _ start: TimeInterval,
        _ end: TimeInterval,
        complete: Bool = true
    ) -> TranscriptJournalEntry {
        TranscriptJournalEntry(
            sessionID: sessionID,
            runID: runID,
            sequence: sequence,
            sourceSegmentID: UUID(),
            trackID: trackID,
            text: text,
            start: start,
            end: end,
            isComplete: complete
        )
    }
}

private struct SuspendingFormatter: TranscriptFormatting {
    func format(entries: [TranscriptJournalEntry]) async throws -> [TranscriptBlock] {
        await Task.yield()
        return try await DefaultTranscriptFormatter().format(entries: entries)
    }
}
