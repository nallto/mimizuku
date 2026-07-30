import Foundation
import MimizukuCore

extension AudioSessionController {
    func recoverPendingTranscripts() async {
        let directories = store.pendingJournalDirectories()
        guard !directories.isEmpty else { return }
        logger.notice("recovering \(directories.count) transcript journal(s)")
        for directory in directories {
            do {
                _ = try await Self.recoverTranscriptOffMain(
                    store: store,
                    directory: directory
                )
            } catch {
                logger.error(
                    "transcript recovery failed: \(error.localizedDescription, privacy: .public)"
                )
                applyRecordingError(
                    "前回の文字起こしを自動回復できませんでした(元データは保持)。"
                )
            }
        }
    }

    private nonisolated static func recoverTranscriptOffMain(
        store: SessionStore,
        directory: URL
    ) async throws -> (metadata: SessionMetadata, transcript: TranscriptDocument)? {
        try await store.recoverJournal(in: directory)
    }

    /// AAC変換後にmetaの相対パスだけを更新する。複数変換の完了はMainActor上で直列に反映されるため、一方の更新をもう一方が上書きしない。
    func updateRecordingPath(
        from oldName: String,
        to newName: String,
        in directory: URL
    ) {
        do {
            var metadata = try store.loadMetadata(from: directory)
            guard metadata.tracks.contains(where: { $0.relativeAudioPath == oldName }) else {
                return
            }
            metadata.revision += 1
            metadata.tracks = metadata.tracks.map { track in
                var updated = track
                if updated.relativeAudioPath == oldName {
                    updated.relativeAudioPath = newName
                }
                return updated
            }
            try store.saveMetadata(metadata, in: directory)
        } catch {
            logger.error(
                "recording path update failed: \(error.localizedDescription, privacy: .public)"
            )
            applyRecordingError(
                "録音は変換されましたがメタデータの更新に失敗しました。"
            )
        }
    }

    func storeSessionDirectories() -> [URL] {
        store.sessionDirectories()
    }

    func repairConvertedRecordingPath(in directory: URL) {
        do {
            _ = try store.repairConvertedRecordingPaths(in: directory)
        } catch {
            logger.error(
                "recording path recovery failed: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    func canRecoverRecording(in directory: URL) -> Bool {
        let metadataURL = store.metadataURL(in: directory)
        guard FileManager.default.fileExists(atPath: metadataURL.path) else {
            // S5以前の録音ディレクトリにはmetaが無い。従来どおりAAC変換できる。
            return true
        }
        do {
            _ = try store.loadMetadata(from: directory)
            return true
        } catch {
            let description = error.localizedDescription
            let reason = "recording conversion skipped for unsupported metadata"
            logger.error(
                "\(reason, privacy: .public): \(description, privacy: .public)"
            )
            return false
        }
    }
}
