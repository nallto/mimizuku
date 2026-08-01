import AVFoundation
import Foundation
import MimizukuCore
import OSLog

// MARK: - AEC 診断試行(#75 / ADR-0015)の生成・転送・close

extension AudioSessionController {
    /// 配線層 extension(`AudioSessionController+Inputs`)から pump へ渡す診断シンク。
    var aecDiagnosticsRecorder: AecDiagnosticsRecorder? {
        aecDiagnosticsTrial?.recorder
    }

    /// 診断が有効化されているか。**argument domain(起動引数)だけ**を読む ――
    /// `UserDefaults.standard.bool` は永続 application domain も拾うため、過去の
    /// `defaults write` が残っていると引数なしでも raw 録音が有効になってしまう
    /// (ADR-0015 の「揮発性起動引数のみ」を機構として強制する)。
    static func isAecDiagnosticsEnabled(
        argumentDomain: [String: Any] = UserDefaults.standard
            .volatileDomain(forName: UserDefaults.argumentDomain)
    ) -> Bool {
        guard let value = argumentDomain[aecDiagnosticsDefaultsKey] else { return false }
        if let number = value as? NSNumber { return number.boolValue }
        if let string = value as? String { return (string as NSString).boolValue }
        return false
    }

    /// 診断試行を生成する(フラグ off / マイク非含有モード / 生成失敗は nil)。
    func makeAecDiagnosticsTrial(streams: [StreamKind]) -> AecDiagnosticsTrial? {
        guard Self.isAecDiagnosticsEnabled() else { return nil }
        // AEC が動くのはマイクを含むモードのみ(システム音声単体に near-end は無い)。
        guard streams.contains(.microphone) else { return nil }
        do {
            let startedAt = Date()
            let layout = AecDiagnosticsLayout.defaultLayout()
            let directory = try layout.createTrialDirectory(startedAt: startedAt)
            let mode = streams.contains(.systemAudio) ? "both" : "micOnly"
            logger.notice(
                "aec diagnostics enabled: \(directory.path, privacy: .public)"
            )
            return AecDiagnosticsTrial(
                directory: directory,
                mode: mode,
                startedAt: startedAt,
                startHostTime: AVAudioTime.seconds(forHostTime: mach_absolute_time())
            )
        } catch {
            logger.error(
                """
                aec diagnostics setup failed (session continues without it): \
                \(error.localizedDescription, privacy: .public)
                """
            )
            return nil
        }
    }

    /// 試行を drain / close して meta を確定し、結果をログへ残す。
    func closeAecDiagnostics(
        _ trial: AecDiagnosticsTrial,
        speechStartOffsets: [StreamKind: TimeInterval]
    ) async {
        let offsets = Dictionary(
            uniqueKeysWithValues: speechStartOffsets.map { ($0.key.rawValue, $0.value) }
        )
        let meta = await trial.close(speechStartOffsets: offsets)
        logger.notice(
            """
            aec diagnostics closed: \(meta.trialID, privacy: .public) \
            valid=\(meta.valid, privacy: .public) \
            capture=\(meta.captureFrameCount, privacy: .public) \
            received=\(meta.renderReceivedFrameCount, privacy: .public) \
            fed=\(meta.renderFedFrameCount, privacy: .public) \
            dropped=\(meta.droppedRecords, privacy: .public)
            """
        )
    }
}
