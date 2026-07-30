import Foundation

@testable import MimizukuCore

struct Fixture {
    let root: URL
    let directory: URL
    let store: SessionStore
    let metadata: SessionMetadata
    let runID = UUID()
    let micID = UUID()
    let systemID = UUID()

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appending(component: "SessionStoreTests-\(UUID().uuidString)")
        let layout = SessionLayout(root: root)
        directory = try layout.createSessionDirectory(
            startedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        store = SessionStore(layout: layout)
        metadata = SessionMetadata(
            id: UUID(),
            title: "テスト",
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            tracks: [
                SessionTrack(
                    id: micID,
                    origin: .microphone,
                    label: "自分",
                    relativeAudioPath: "mic.caf"
                ),
                SessionTrack(
                    id: systemID,
                    origin: .systemAudio,
                    label: "相手",
                    relativeAudioPath: "system.caf"
                )
            ]
        )
    }

    func entries() -> [TranscriptJournalEntry] {
        [
            TranscriptJournalEntry(
                sessionID: metadata.id,
                runID: runID,
                sequence: 1,
                sourceSegmentID: UUID(),
                trackID: micID,
                text: "こんにちは。",
                start: 0,
                end: 1
            ),
            TranscriptJournalEntry(
                sessionID: metadata.id,
                runID: runID,
                sequence: 2,
                sourceSegmentID: UUID(),
                trackID: systemID,
                text: "こんにちは。",
                start: 1,
                end: 2
            )
        ]
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }
}

struct LegacyMetadataV0: Encodable {
    let schemaVersion: Int
    let id: UUID
    let title: String
    let startedAt: Date
    let duration: TimeInterval
    let tags: [String]
    let status: SessionStatus
    let tracks: [SessionTrack]
}

struct LegacyTranscriptV0: Encodable {
    let schemaVersion: Int
    let sessionID: UUID
    let blocks: [TranscriptBlock]
}
