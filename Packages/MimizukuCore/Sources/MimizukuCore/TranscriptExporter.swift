import Foundation

public struct TranscriptExporter: Sendable {
    public init() {}

    public func markdown(
        document: TranscriptDocument,
        tracks: [SessionTrack]
    ) -> String {
        render(document: document, tracks: tracks) { time, label, text, incomplete in
            "- \(time) **\(label):** \(text)\(incomplete)"
        }
    }

    public func plainText(
        document: TranscriptDocument,
        tracks: [SessionTrack]
    ) -> String {
        render(document: document, tracks: tracks) { time, label, text, incomplete in
            "\(time) \(label): \(text)\(incomplete)"
        }
    }

    private func render(
        document: TranscriptDocument,
        tracks: [SessionTrack],
        line: (String, String, String, String) -> String
    ) -> String {
        let labels = Dictionary(uniqueKeysWithValues: tracks.map { ($0.id, $0.label) })
        return document.blocks.map { block in
            line(
                Self.timestamp(block.start),
                labels[block.trackID] ?? "音声",
                block.text,
                block.isComplete ? "" : " [未完了]"
            )
        }.joined(separator: "\n") + (document.blocks.isEmpty ? "" : "\n")
    }

    private static func timestamp(_ seconds: TimeInterval?) -> String {
        guard let seconds else { return "[--:--]" }
        let total = max(0, Int(seconds.rounded(.down)))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let remainder = total % 60
        if hours > 0 {
            return String(format: "[%02d:%02d:%02d]", hours, minutes, remainder)
        }
        return String(format: "[%02d:%02d]", minutes, remainder)
    }
}
