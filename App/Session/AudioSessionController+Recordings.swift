import Foundation
import MimizukuCore

// MARK: - 録音終了処理

extension AudioSessionController {
    /// 停止後のAAC変換(ADR-0006 の 2)。失敗してもCAFは温存され、次回起動の
    /// 回復スキャンで再変換される。
    func convertInBackground(
        caf: URL,
        sessionDirectory: URL,
        generation: UInt64
    ) {
        Task { [weak self] in
            do {
                let converted = try await Self.convertOffMain(caf: caf)
                self?.updateRecordingPath(
                    from: caf.lastPathComponent,
                    to: converted.lastPathComponent,
                    in: sessionDirectory
                )
            } catch {
                let reason = error.localizedDescription
                self?.logger.error("aac conversion failed: \(reason, privacy: .public)")
                self?.applyRecordingError(
                    "録音の圧縮に失敗しました(元データは保持): \(reason)",
                    generation: generation
                )
            }
        }
    }

    func recoverPendingRecordings() async {
        for directory in storeSessionDirectories() {
            repairConvertedRecordingPath(in: directory)
        }
        let pending = layout.pendingRecordings()
        guard !pending.isEmpty else { return }
        logger.notice("recovering \(pending.count) unconverted recording(s)")
        for caf in pending {
            guard canRecoverRecording(in: caf.deletingLastPathComponent()) else { continue }
            do {
                let converted = try await Self.convertOffMain(caf: caf)
                updateRecordingPath(
                    from: caf.lastPathComponent,
                    to: converted.lastPathComponent,
                    in: caf.deletingLastPathComponent()
                )
            } catch {
                logger.error("recovery failed: \(error.localizedDescription, privacy: .public)")
                applyRecordingError("前回の録音の変換に失敗しました(元データは保持)。")
            }
        }
    }

    /// AAC変換をMainActorの外で実行する(数分の録音でもUIを塞がない)。
    private nonisolated static func convertOffMain(caf: URL) async throws -> URL {
        try AacConverter().convert(caf: caf)
    }

    /// 録音を閉じ、短すぎる/空のセッションは破棄する(全ストリームの**最長**で判定、ADR-0006の8)。AAC変換は文字起こしスナップショット確定後に呼び出し側が開始する。
    func closeRecordings(
        _ recorders: [AudioFileWriter],
        in sessionDirectory: URL
    ) async -> RecordingCloseResult {
        var durations: [TimeInterval] = []
        for recorder in recorders {
            _ = await recorder.finish()
            await durations.append(recorder.duration)
        }
        if SessionRetention.shouldDiscard(
            durations: durations,
            minimumDuration: Self.minimumSessionDuration
        ) {
            let longest = durations.max() ?? 0
            logger.notice("discarding short session (\(longest, format: .fixed(precision: 2))s)")
            try? FileManager.default.removeItem(at: sessionDirectory)
            return RecordingCloseResult(kept: false, durations: durations)
        }
        return RecordingCloseResult(kept: true, durations: durations)
    }

    /// AEC参照を開始できなかったセッションは正式なマイク音源を一度も生成していない。
    /// system側だけを残さず、writerを閉じてセッション全体を破棄する。
    func discardRecordings(
        _ recorders: [AudioFileWriter],
        in sessionDirectory: URL
    ) async {
        for recorder in recorders {
            _ = await recorder.finish()
        }
        do {
            try FileManager.default.removeItem(at: sessionDirectory)
        } catch {
            let reason = error.localizedDescription
            logger.error("failed to discard AEC start failure: \(reason, privacy: .public)")
        }
    }
}

struct RecordingCloseResult: Sendable {
    let kept: Bool
    let durations: [TimeInterval]

    var longestDuration: TimeInterval {
        durations.max() ?? 0
    }
}
