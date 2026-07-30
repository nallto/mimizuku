import Foundation

public enum SessionStoreError: Error, Equatable {
    case unsupportedMetaVersion(Int)
    case unsupportedTranscriptVersion(Int)
    case invalidMetadata
    case invalidTranscript
    case sessionIDMismatch
    case unknownTrack(UUID)
    case journalRunMismatch
}

public enum SessionLoadState: Sendable, Equatable {
    case available(
        directory: URL,
        metadata: SessionMetadata,
        transcript: TranscriptDocument?
    )
    case recoveryNeeded(directory: URL, reason: String)
}

public struct SessionStore: Sendable {
    public let layout: SessionLayout

    public init(layout: SessionLayout) {
        self.layout = layout
    }

    public func saveInitialMetadata(
        _ metadata: SessionMetadata,
        in directory: URL
    ) throws {
        try saveMetadata(metadata, in: directory)
    }

    public func saveMetadata(
        _ metadata: SessionMetadata,
        in directory: URL
    ) throws {
        guard metadata.schemaVersion == SessionSchema.currentMetaVersion else {
            throw SessionStoreError.unsupportedMetaVersion(metadata.schemaVersion)
        }
        try Self.validateMetadata(metadata)
        try Self.atomicWrite(Self.encoder.encode(metadata), to: metadataURL(in: directory))
    }

    public func loadMetadata(from directory: URL) throws -> SessionMetadata {
        let data = try Data(contentsOf: metadataURL(in: directory))
        let version = try Self.schemaVersion(in: data, invalid: .invalidMetadata)
        if version == 0 {
            do {
                let legacy = try Self.decoder.decode(LegacyMetadataV0.self, from: data)
                let migrated = legacy.migrated()
                try saveMetadata(migrated, in: directory)
                return migrated
            } catch {
                if let storeError = error as? SessionStoreError { throw storeError }
                throw SessionStoreError.invalidMetadata
            }
        }
        guard version == SessionSchema.currentMetaVersion else {
            throw SessionStoreError.unsupportedMetaVersion(version)
        }
        do {
            let metadata = try Self.decoder.decode(SessionMetadata.self, from: data)
            try Self.validateMetadata(metadata)
            return metadata
        } catch {
            if let storeError = error as? SessionStoreError { throw storeError }
            throw SessionStoreError.invalidMetadata
        }
    }

    public func loadTranscript(from directory: URL) throws -> TranscriptDocument {
        let data = try Data(contentsOf: transcriptURL(in: directory))
        let version = try Self.schemaVersion(in: data, invalid: .invalidTranscript)
        if version == 0 {
            do {
                let legacy = try Self.decoder.decode(LegacyTranscriptV0.self, from: data)
                let migrated = legacy.migrated()
                try saveTranscript(migrated, in: directory)
                return migrated
            } catch {
                if let storeError = error as? SessionStoreError { throw storeError }
                throw SessionStoreError.invalidTranscript
            }
        }
        guard version == SessionSchema.currentTranscriptVersion else {
            throw SessionStoreError.unsupportedTranscriptVersion(version)
        }
        do {
            let transcript = try Self.decoder.decode(TranscriptDocument.self, from: data)
            try Self.validateTranscript(transcript)
            return transcript
        } catch {
            if let storeError = error as? SessionStoreError { throw storeError }
            throw SessionStoreError.invalidTranscript
        }
    }

    public func saveTranscript(
        _ transcript: TranscriptDocument,
        in directory: URL
    ) throws {
        guard transcript.schemaVersion == SessionSchema.currentTranscriptVersion else {
            throw SessionStoreError.unsupportedTranscriptVersion(transcript.schemaVersion)
        }
        try Self.validateTranscript(transcript)
        if FileManager.default.fileExists(atPath: metadataURL(in: directory).path) {
            try validate(metadata: loadMetadata(from: directory), transcript: transcript)
        }
        try Self.atomicWrite(Self.encoder.encode(transcript), to: transcriptURL(in: directory))
    }

    public func listSessions(fileManager: FileManager = .default) -> [SessionLoadState] {
        guard let directories = try? fileManager.contentsOfDirectory(
            at: layout.root,
            includingPropertiesForKeys: [.isDirectoryKey]
        ) else {
            return []
        }
        return directories
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
            .map { directory in
                do {
                    let metadata = try loadMetadata(from: directory)
                    if fileManager.fileExists(atPath: journalURL(in: directory).path) {
                        return .recoveryNeeded(
                            directory: directory,
                            reason: "未確定の文字起こしジャーナルがあります。"
                        )
                    }
                    let transcript: TranscriptDocument?
                    if fileManager.fileExists(atPath: transcriptURL(in: directory).path) {
                        let loaded = try loadTranscript(from: directory)
                        try validate(metadata: metadata, transcript: loaded)
                        transcript = loaded
                    } else {
                        transcript = nil
                    }
                    if metadata.status == .recording {
                        return .recoveryNeeded(
                            directory: directory,
                            reason: "録音中の状態で終了したセッションです。"
                        )
                    }
                    return .available(
                        directory: directory,
                        metadata: metadata,
                        transcript: transcript
                    )
                } catch {
                    return .recoveryNeeded(
                        directory: directory,
                        reason: String(describing: error)
                    )
                }
            }
    }

    public func finalize(
        metadata: SessionMetadata,
        journalEntries: [TranscriptJournalEntry],
        formatter: any TranscriptFormatting = DefaultTranscriptFormatter(),
        incompleteEntries: [TranscriptJournalEntry] = [],
        sourceRunID: UUID? = nil,
        finalStatus: SessionStatus = .completed,
        in directory: URL,
        fileManager: FileManager = .default
    ) async throws -> (metadata: SessionMetadata, transcript: TranscriptDocument) {
        let entries = journalEntries + incompleteEntries
        try validate(metadata: metadata, entries: entries)
        let runIDs = Set(entries.map(\.runID))
        guard runIDs.count <= 1 else { throw SessionStoreError.journalRunMismatch }
        let runID = runIDs.first ?? sourceRunID ?? UUID()
        let transcriptFile = transcriptURL(in: directory)
        var existingRevision = 0
        if fileManager.fileExists(atPath: transcriptFile.path) {
            existingRevision = try loadTranscript(from: directory).revision
        }
        let document = try await TranscriptDocument(
            sessionID: metadata.id,
            revision: existingRevision + 1,
            sourceRunID: runID,
            appliedSequence: journalEntries.map(\.sequence).max() ?? 0,
            blocks: formatter.format(entries: entries)
        )

        // ADR-0007: transcriptを先に確定し、その後metaの派生値を更新する。
        try saveTranscript(document, in: directory)
        var completed = metadata
        completed.revision += 1
        completed.duration = max(
            completed.duration,
            entries.compactMap(\.end).max() ?? 0
        )
        completed.status = finalStatus
        try Self.atomicWrite(Self.encoder.encode(completed), to: metadataURL(in: directory))

        let journal = journalURL(in: directory)
        if fileManager.fileExists(atPath: journal.path) {
            try fileManager.removeItem(at: journal)
        }
        return (completed, document)
    }

    public func metadataURL(in directory: URL) -> URL {
        directory.appending(component: "meta.json")
    }

    public func transcriptURL(in directory: URL) -> URL {
        directory.appending(component: "transcript.json")
    }

    public func journalURL(in directory: URL) -> URL {
        directory.appending(component: "transcript.journal.jsonl")
    }
}
