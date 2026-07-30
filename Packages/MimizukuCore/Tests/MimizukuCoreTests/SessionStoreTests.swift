import Foundation
import Testing

@testable import MimizukuCore

@Suite("SessionStore")
struct SessionStoreTests {
    @Test("初期metaを保存し同じ値を読み戻す")
    func metadataRoundTrip() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }

        try fixture.store.saveInitialMetadata(fixture.metadata, in: fixture.directory)
        let loaded = try fixture.store.loadMetadata(from: fixture.directory)

        #expect(loaded == fixture.metadata)
    }

    @Test("停止確定はtranscriptとmetaを書いてからjournalを削除する")
    func finalizationCreatesSnapshotsAndDeletesJournal() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.store.saveInitialMetadata(fixture.metadata, in: fixture.directory)
        try Data().write(to: fixture.store.journalURL(in: fixture.directory))
        let entries = fixture.entries()

        let result = try await fixture.store.finalize(
            metadata: fixture.metadata,
            journalEntries: entries,
            in: fixture.directory
        )

        #expect(result.metadata.status == .completed)
        #expect(result.metadata.duration == 2)
        #expect(result.transcript.appliedSequence == 2)
        #expect(!FileManager.default.fileExists(
            atPath: fixture.store.journalURL(in: fixture.directory).path
        ))
        #expect(try fixture.store.loadTranscript(from: fixture.directory) == result.transcript)
        #expect(try fixture.store.loadMetadata(from: fixture.directory) == result.metadata)
    }

    @Test("transcript確定後meta更新前の回復で派生値を再計算する")
    func recoversStaleMetadataWithoutDuplicatingTranscript() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.store.saveInitialMetadata(fixture.metadata, in: fixture.directory)
        let entries = fixture.entries()
        let finalized = try await fixture.store.finalize(
            metadata: fixture.metadata,
            journalEntries: entries,
            in: fixture.directory
        )

        // transcript置換直後・meta更新前・journal削除前の異常終了を再現する。
        try fixture.store.saveInitialMetadata(fixture.metadata, in: fixture.directory)
        let writer = try TranscriptJournalWriter(
            url: fixture.store.journalURL(in: fixture.directory),
            sessionID: fixture.metadata.id,
            runID: fixture.runID
        )
        for entry in entries {
            _ = try await writer.append(
                sourceSegmentID: entry.sourceSegmentID,
                trackID: entry.trackID,
                text: entry.text,
                start: entry.start,
                end: entry.end
            )
        }

        let recoveredValue = try await fixture.store.recoverJournal(in: fixture.directory)
        let recovered = try #require(recoveredValue)
        #expect(recovered.transcript == finalized.transcript)
        #expect(recovered.metadata.status == .completed)
        #expect(recovered.metadata.duration == 2)
        #expect(!FileManager.default.fileExists(
            atPath: fixture.store.journalURL(in: fixture.directory).path
        ))
    }

    @Test("空journal削除前の異常終了でも既存の未完了末尾を消さない")
    func emptyJournalRecoveryPreservesIncompleteSnapshot() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.store.saveInitialMetadata(fixture.metadata, in: fixture.directory)
        var incomplete = fixture.entries()[0]
        incomplete.isComplete = false
        let finalized = try await fixture.store.finalize(
            metadata: fixture.metadata,
            journalEntries: [],
            incompleteEntries: [incomplete],
            sourceRunID: fixture.runID,
            in: fixture.directory
        )

        // transcript置換直後・meta更新前・空journal削除前の異常終了を再現する。
        try fixture.store.saveInitialMetadata(fixture.metadata, in: fixture.directory)
        try Data().write(to: fixture.store.journalURL(in: fixture.directory))

        let recoveredValue = try await fixture.store.recoverJournal(in: fixture.directory)
        let recovered = try #require(recoveredValue)
        #expect(recovered.transcript == finalized.transcript)
        #expect(recovered.transcript.blocks.map(\.isComplete) == [false])
        #expect(recovered.transcript.blocks.map(\.text) == [incomplete.text])
    }

    @Test("セッションID不一致では自動的に組み合わせずjournalを保持する")
    func rejectsMismatchedSession() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.store.saveInitialMetadata(fixture.metadata, in: fixture.directory)
        let journal = fixture.store.journalURL(in: fixture.directory)
        try Data().write(to: journal)
        var entry = fixture.entries()[0]
        entry.sessionID = UUID()

        await #expect(throws: SessionStoreError.sessionIDMismatch) {
            try await fixture.store.finalize(
                metadata: fixture.metadata,
                journalEntries: [entry],
                in: fixture.directory
            )
        }
        #expect(FileManager.default.fileExists(atPath: journal.path))
    }

    @Test("存在しないトラック参照では自動確定しない")
    func rejectsUnknownTrack() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        var entry = fixture.entries()[0]
        entry.trackID = UUID()

        await #expect(throws: SessionStoreError.unknownTrack(entry.trackID)) {
            try await fixture.store.finalize(
                metadata: fixture.metadata,
                journalEntries: [entry],
                in: fixture.directory
            )
        }
    }
}

extension SessionStoreTests {
    @Test("セッション外を指す音声相対パスを拒否する")
    func rejectsEscapingAudioPath() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        var metadata = fixture.metadata
        metadata.tracks[0].relativeAudioPath = "../outside.caf"

        #expect(throws: SessionStoreError.invalidMetadata) {
            try fixture.store.saveInitialMetadata(metadata, in: fixture.directory)
        }
    }

    @Test("未知のmeta schemaを破壊的に書き戻さない")
    func unknownMetadataVersionRemainsUntouched() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let url = fixture.store.metadataURL(in: fixture.directory)
        let future = Data(#"{"schemaVersion":99,"future":"preserve"}"#.utf8)
        try future.write(to: url)

        #expect(throws: SessionStoreError.unsupportedMetaVersion(99)) {
            try fixture.store.loadMetadata(from: fixture.directory)
        }
        #expect(try Data(contentsOf: url) == future)
    }

    @Test("既知のmeta version 0をversion 1へ原子的に移行する")
    func migratesKnownMetadataVersion() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let legacy = LegacyMetadataV0(
            schemaVersion: 0,
            id: fixture.metadata.id,
            title: fixture.metadata.title,
            startedAt: fixture.metadata.startedAt,
            duration: 12,
            tags: ["旧"],
            status: .completed,
            tracks: fixture.metadata.tracks
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(legacy).write(
            to: fixture.store.metadataURL(in: fixture.directory)
        )

        let migrated = try fixture.store.loadMetadata(from: fixture.directory)

        #expect(migrated.schemaVersion == 1)
        #expect(migrated.revision == 1)
        #expect(migrated.input == .liveRecording)
        #expect(migrated.duration == 12)
        #expect(try fixture.store.loadMetadata(from: fixture.directory) == migrated)
    }

    @Test("未知のtranscript schemaを破壊的に書き戻さない")
    func unknownTranscriptVersionRemainsUntouched() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let url = fixture.store.transcriptURL(in: fixture.directory)
        let future = Data(#"{"schemaVersion":99,"future":"preserve"}"#.utf8)
        try future.write(to: url)

        #expect(throws: SessionStoreError.unsupportedTranscriptVersion(99)) {
            try fixture.store.loadTranscript(from: fixture.directory)
        }
        #expect(try Data(contentsOf: url) == future)
    }

    @Test("未知のtranscript schemaがある状態では確定処理でも上書きしない")
    func finalizationPreservesUnknownTranscriptVersion() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.store.saveInitialMetadata(fixture.metadata, in: fixture.directory)
        let url = fixture.store.transcriptURL(in: fixture.directory)
        let future = Data(#"{"schemaVersion":99,"future":"preserve"}"#.utf8)
        try future.write(to: url)
        let journal = fixture.store.journalURL(in: fixture.directory)
        try Data().write(to: journal)

        await #expect(throws: SessionStoreError.unsupportedTranscriptVersion(99)) {
            try await fixture.store.finalize(
                metadata: fixture.metadata,
                journalEntries: fixture.entries(),
                in: fixture.directory
            )
        }
        #expect(try Data(contentsOf: url) == future)
        #expect(FileManager.default.fileExists(atPath: journal.path))
    }

    @Test("既知のtranscript version 0をversion 1へ原子的に移行する")
    func migratesKnownTranscriptVersion() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let legacy = LegacyTranscriptV0(
            schemaVersion: 0,
            sessionID: fixture.metadata.id,
            blocks: [
                TranscriptBlock(
                    trackID: fixture.micID,
                    text: "旧形式",
                    start: 0,
                    end: 1,
                    isComplete: true
                )
            ]
        )
        try JSONEncoder().encode(legacy).write(
            to: fixture.store.transcriptURL(in: fixture.directory)
        )

        let migrated = try fixture.store.loadTranscript(from: fixture.directory)
        let reloaded = try fixture.store.loadTranscript(from: fixture.directory)

        #expect(migrated.schemaVersion == 1)
        #expect(migrated.revision == 1)
        #expect(migrated.appliedSequence == 0)
        #expect(reloaded == migrated)
    }
}

extension SessionStoreTests {
    @Test("metaとtranscriptのセッションID不一致は救済対象として列挙する")
    func listsMismatchedSnapshotsForRecovery() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.store.saveInitialMetadata(fixture.metadata, in: fixture.directory)
        _ = try await fixture.store.finalize(
            metadata: fixture.metadata,
            journalEntries: fixture.entries(),
            in: fixture.directory
        )
        var other = fixture.metadata
        other.id = UUID()
        other.status = .completed
        try fixture.store.saveMetadata(other, in: fixture.directory)

        let sessions = fixture.store.listSessions()
        guard case .recoveryNeeded = sessions.first else {
            Issue.record("ID不一致のスナップショットがavailableとして扱われた")
            return
        }
    }

    @Test("破損したセッションも救済対象として列挙する")
    func listsCorruptSessionForRecovery() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try Data("broken".utf8).write(to: fixture.store.metadataURL(in: fixture.directory))

        let sessions = fixture.store.listSessions()
        #expect(sessions.count == 1)
        guard case let .recoveryNeeded(directory, _) = sessions[0] else {
            Issue.record("破損セッションがavailableとして扱われた")
            return
        }
        #expect(
            directory.resolvingSymlinksInPath()
                == fixture.directory.resolvingSymlinksInPath()
        )
    }

    @Test("journalが残るセッションは通常データでなく救済対象として列挙する")
    func listsPendingJournalForRecovery() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.store.saveInitialMetadata(fixture.metadata, in: fixture.directory)
        try Data().write(to: fixture.store.journalURL(in: fixture.directory))

        let sessions = fixture.store.listSessions()
        guard case .recoveryNeeded = sessions.first else {
            Issue.record("未確定journalを持つセッションがavailableとして扱われた")
            return
        }
    }

    @Test("AAC変換後meta更新前の中断では実在するm4aへパスを修復する")
    func repairsConvertedRecordingPath() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.store.saveInitialMetadata(fixture.metadata, in: fixture.directory)
        try Data().write(to: fixture.directory.appending(component: "mic.m4a"))

        let repaired = try fixture.store.repairConvertedRecordingPaths(
            in: fixture.directory
        )

        #expect(repaired.tracks.first { $0.id == fixture.micID }?.relativeAudioPath == "mic.m4a")
        #expect(
            repaired.tracks.first { $0.id == fixture.systemID }?
                .relativeAudioPath == "system.caf"
        )
        #expect(try fixture.store.loadMetadata(from: fixture.directory) == repaired)
    }
}
