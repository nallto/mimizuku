import Foundation

public extension SessionStore {
    func recoverJournal(
        in directory: URL,
        formatter: any TranscriptFormatting = DefaultTranscriptFormatter(),
        fileManager: FileManager = .default
    ) async throws -> (metadata: SessionMetadata, transcript: TranscriptDocument)? {
        let journal = journalURL(in: directory)
        guard fileManager.fileExists(atPath: journal.path) else { return nil }
        let metadata = try loadMetadata(from: directory)
        let contents = try TranscriptJournalReader().read(from: journal)
        guard let last = contents.entries.last else {
            if fileManager.fileExists(atPath: transcriptURL(in: directory).path) {
                let existing = try loadTranscript(from: directory)
                try validate(metadata: metadata, transcript: existing)
                let recovered = try recoverMetadata(
                    metadata,
                    using: existing,
                    in: directory
                )
                try fileManager.removeItem(at: journal)
                return (recovered, existing)
            }
            return try await finalize(
                metadata: metadata,
                journalEntries: [],
                sourceRunID: UUID(),
                finalStatus: .interrupted,
                in: directory,
                fileManager: fileManager
            )
        }

        if fileManager.fileExists(atPath: transcriptURL(in: directory).path) {
            let existing = try loadTranscript(from: directory)
            try validate(metadata: metadata, transcript: existing)
            if existing.sourceRunID == last.runID, existing.appliedSequence >= last.sequence {
                let recovered = try recoverMetadata(
                    metadata,
                    using: existing,
                    in: directory
                )
                try fileManager.removeItem(at: journal)
                return (recovered, existing)
            }
        }
        return try await finalize(
            metadata: metadata,
            journalEntries: contents.entries,
            formatter: formatter,
            in: directory,
            fileManager: fileManager
        )
    }

    func pendingJournalDirectories(
        fileManager: FileManager = .default
    ) -> [URL] {
        sessionDirectories(fileManager: fileManager)
            .filter { fileManager.fileExists(atPath: journalURL(in: $0).path) }
            .sorted { $0.path < $1.path }
    }

    /// AAC変換成功後・meta更新前に終了したセッションを、実在するm4aへ安全に付け替える。
    @discardableResult
    func repairConvertedRecordingPaths(
        in directory: URL,
        fileManager: FileManager = .default
    ) throws -> SessionMetadata {
        var metadata = try loadMetadata(from: directory)
        var changed = false
        metadata.tracks = metadata.tracks.map { track in
            guard URL(filePath: track.relativeAudioPath).pathExtension == "caf" else {
                return track
            }
            let declared = directory.appending(component: track.relativeAudioPath)
            let convertedName = URL(filePath: track.relativeAudioPath)
                .deletingPathExtension()
                .appendingPathExtension("m4a")
                .lastPathComponent
            let converted = directory.appending(component: convertedName)
            guard
                !fileManager.fileExists(atPath: declared.path),
                fileManager.fileExists(atPath: converted.path)
            else {
                return track
            }
            changed = true
            var updated = track
            updated.relativeAudioPath = convertedName
            return updated
        }
        if changed {
            metadata.revision += 1
            try saveMetadata(metadata, in: directory)
        }
        return metadata
    }

    func sessionDirectories(
        fileManager: FileManager = .default
    ) -> [URL] {
        guard let directories = try? fileManager.contentsOfDirectory(
            at: layout.root,
            includingPropertiesForKeys: [.isDirectoryKey]
        ) else {
            return []
        }
        return directories.filter {
            (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        }
    }

    private func recoverMetadata(
        _ metadata: SessionMetadata,
        using transcript: TranscriptDocument,
        in directory: URL
    ) throws -> SessionMetadata {
        guard metadata.status != .completed else { return metadata }
        var recovered = metadata
        recovered.revision += 1
        recovered.status = .completed
        recovered.duration = max(
            recovered.duration,
            transcript.blocks.compactMap(\.end).max() ?? 0
        )
        try Self.atomicWrite(Self.encoder.encode(recovered), to: metadataURL(in: directory))
        return recovered
    }
}
