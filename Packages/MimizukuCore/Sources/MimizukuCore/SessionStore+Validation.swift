import Foundation

extension SessionStore {
    func validate(
        metadata: SessionMetadata,
        transcript: TranscriptDocument
    ) throws {
        try Self.validateMetadata(metadata)
        try Self.validateTranscript(transcript)
        guard metadata.id == transcript.sessionID else {
            throw SessionStoreError.sessionIDMismatch
        }
        let trackIDs = Set(metadata.tracks.map(\.id))
        for block in transcript.blocks where !trackIDs.contains(block.trackID) {
            throw SessionStoreError.unknownTrack(block.trackID)
        }
    }

    func validate(
        metadata: SessionMetadata,
        entries: [TranscriptJournalEntry]
    ) throws {
        try Self.validateMetadata(metadata)
        let trackIDs = Set(metadata.tracks.map(\.id))
        for entry in entries {
            guard entry.sessionID == metadata.id else {
                throw SessionStoreError.sessionIDMismatch
            }
            guard trackIDs.contains(entry.trackID) else {
                throw SessionStoreError.unknownTrack(entry.trackID)
            }
        }
    }

    static func validateMetadata(_ metadata: SessionMetadata) throws {
        guard
            metadata.revision >= 1,
            metadata.duration.isFinite,
            metadata.duration >= 0,
            !metadata.tracks.isEmpty,
            Set(metadata.tracks.map(\.id)).count == metadata.tracks.count
        else {
            throw SessionStoreError.invalidMetadata
        }
        switch metadata.input.kind {
        case .liveRecording:
            guard metadata.input.importedMedia == nil else {
                throw SessionStoreError.invalidMetadata
            }
        case .imported:
            guard metadata.input.importedMedia != nil else {
                throw SessionStoreError.invalidMetadata
            }
        }
        for track in metadata.tracks {
            let components = track.relativeAudioPath.split(
                separator: "/",
                omittingEmptySubsequences: false
            )
            guard
                !track.relativeAudioPath.isEmpty,
                !track.relativeAudioPath.hasPrefix("/"),
                !components.contains(".."),
                track.startOffset.isFinite,
                track.startOffset >= 0
            else {
                throw SessionStoreError.invalidMetadata
            }
        }
    }

    static func validateTranscript(_ transcript: TranscriptDocument) throws {
        guard transcript.revision >= 1 else {
            throw SessionStoreError.invalidTranscript
        }
        for block in transcript.blocks {
            guard
                !block.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                block.start?.isFinite != false,
                block.end?.isFinite != false
            else {
                throw SessionStoreError.invalidTranscript
            }
            if let start = block.start, let end = block.end, end < start {
                throw SessionStoreError.invalidTranscript
            }
        }
    }

    static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    struct LegacyMetadataV0: Codable {
        let schemaVersion: Int
        let id: UUID
        let title: String
        let startedAt: Date
        let duration: TimeInterval
        let tags: [String]
        let status: SessionStatus
        let tracks: [SessionTrack]

        func migrated() -> SessionMetadata {
            SessionMetadata(
                id: id,
                title: title,
                startedAt: startedAt,
                duration: duration,
                tags: tags,
                status: status,
                input: .liveRecording,
                tracks: tracks
            )
        }
    }

    struct LegacyTranscriptV0: Codable {
        let schemaVersion: Int
        let sessionID: UUID
        let blocks: [TranscriptBlock]

        func migrated() -> TranscriptDocument {
            TranscriptDocument(
                sessionID: sessionID,
                sourceRunID: UUID(),
                appliedSequence: 0,
                blocks: blocks
            )
        }
    }

    static func schemaVersion(
        in data: Data,
        invalid: SessionStoreError
    ) throws -> Int {
        struct SchemaHeader: Decodable {
            let schemaVersion: Int
        }
        do {
            return try JSONDecoder().decode(SchemaHeader.self, from: data).schemaVersion
        } catch {
            throw invalid
        }
    }

    static func atomicWrite(_ data: Data, to destination: URL) throws {
        let directory = destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let temporary = directory
            .appending(component: ".\(destination.lastPathComponent).\(UUID().uuidString).tmp")
        do {
            guard FileManager.default.createFile(atPath: temporary.path, contents: nil) else {
                throw CocoaError(.fileWriteUnknown)
            }
            try synchronize(data, to: temporary)
            if FileManager.default.fileExists(atPath: destination.path) {
                _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary)
            } else {
                try FileManager.default.moveItem(at: temporary, to: destination)
            }
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
    }

    private static func synchronize(_ data: Data, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        do {
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
        } catch {
            try? handle.close()
            throw error
        }
    }
}
