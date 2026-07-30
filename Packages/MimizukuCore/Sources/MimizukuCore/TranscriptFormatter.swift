import Foundation

public protocol TranscriptFormatting: Sendable {
    func format(entries: [TranscriptJournalEntry]) async throws -> [TranscriptBlock]
}

public enum TranscriptFormattingError: Error, Equatable {
    case invalidTimeRange(sequence: UInt64)
}

/// 認識器の改訂単位を、利用者が読む表示ブロックへ決定的に整形する既定実装。
///
/// 契約の入出力はSpeechやUIに依存しない値型であり、将来オンデバイスNLPやLLMを使う実装へ差し替えても、トラック帰属・時間範囲・未完了末尾を保持する。
public struct DefaultTranscriptFormatter: TranscriptFormatting {
    public var maximumMergeGap: TimeInterval

    public init(maximumMergeGap: TimeInterval = 1.0) {
        self.maximumMergeGap = maximumMergeGap
    }

    public func format(entries: [TranscriptJournalEntry]) async throws -> [TranscriptBlock] {
        var result: [TranscriptBlock] = []
        var lastIndexByTrack: [UUID: Int] = [:]
        for entry in entries.sorted(by: Self.arrivalOrder) {
            if let start = entry.start, let end = entry.end, end < start {
                throw TranscriptFormattingError.invalidTimeRange(sequence: entry.sequence)
            }
            let pieces = Self.sentencePieces(in: entry.text)
            for (index, piece) in pieces.enumerated() {
                let range = Self.proportionalRange(
                    index: index,
                    pieces: pieces,
                    start: entry.start,
                    end: entry.end
                )
                let next = TranscriptBlock(
                    trackID: entry.trackID,
                    text: piece,
                    start: range.start,
                    end: range.end,
                    isComplete: entry.isComplete
                )
                if let previousIndex = lastIndexByTrack[next.trackID] {
                    if shouldMerge(result[previousIndex], next) {
                        result[previousIndex] = Self.merged(result[previousIndex], next)
                        continue
                    }
                }
                result.append(next)
                lastIndexByTrack[next.trackID] = result.count - 1
            }
        }
        return result
    }

    private func shouldMerge(_ previous: TranscriptBlock, _ next: TranscriptBlock) -> Bool {
        guard previous.trackID == next.trackID, !Self.endsSentence(previous.text) else {
            return false
        }
        if let previousEnd = previous.end, let nextStart = next.start {
            return nextStart - previousEnd <= maximumMergeGap
        }
        return true
    }

    private static func merged(
        _ previous: TranscriptBlock,
        _ next: TranscriptBlock
    ) -> TranscriptBlock {
        TranscriptBlock(
            id: previous.id,
            trackID: previous.trackID,
            text: join(previous.text, next.text),
            start: minOptional(previous.start, next.start),
            end: maxOptional(previous.end, next.end),
            isComplete: next.isComplete
        )
    }

    private static func arrivalOrder(
        _ lhs: TranscriptJournalEntry,
        _ rhs: TranscriptJournalEntry
    ) -> Bool {
        if lhs.sequence != rhs.sequence { return lhs.sequence < rhs.sequence }
        return lhs.trackID.uuidString < rhs.trackID.uuidString
    }

    private static func sentencePieces(in text: String) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        var pieces: [String] = []
        var current = ""
        for character in trimmed {
            current.append(character)
            if sentenceTerminators.contains(character) {
                let piece = current.trimmingCharacters(in: .whitespacesAndNewlines)
                let isPunctuationOnly = piece.allSatisfy { sentenceTerminators.contains($0) }
                if isPunctuationOnly, !pieces.isEmpty {
                    pieces[pieces.count - 1] += piece
                } else {
                    pieces.append(piece)
                }
                current = ""
            }
        }
        let remainder = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !remainder.isEmpty { pieces.append(remainder) }
        return pieces
    }

    private static func proportionalRange(
        index: Int,
        pieces: [String],
        start: TimeInterval?,
        end: TimeInterval?
    ) -> (start: TimeInterval?, end: TimeInterval?) {
        guard pieces.count > 1, let start, let end else { return (start, end) }
        let duration = end - start
        let weights = pieces.map { max(1, $0.count) }
        let total = weights.reduce(0, +)
        let leading = weights.prefix(index).reduce(0, +)
        let trailing = leading + weights[index]
        return (
            start + duration * Double(leading) / Double(total),
            start + duration * Double(trailing) / Double(total)
        )
    }

    private static func endsSentence(_ text: String) -> Bool {
        guard let last = text.last else { return false }
        return sentenceTerminators.contains(last)
    }

    private static func join(_ lhs: String, _ rhs: String) -> String {
        guard let last = lhs.last, let first = rhs.first else { return lhs + rhs }
        let needsSpace = last.isASCII && first.isASCII && !last.isWhitespace && !first.isWhitespace
        return lhs + (needsSpace ? " " : "") + rhs
    }

    private static func minOptional(_ lhs: TimeInterval?, _ rhs: TimeInterval?) -> TimeInterval? {
        switch (lhs, rhs) {
        case let (lhs?, rhs?): min(lhs, rhs)
        case let (lhs?, nil): lhs
        case let (nil, rhs?): rhs
        case (nil, nil): nil
        }
    }

    private static func maxOptional(_ lhs: TimeInterval?, _ rhs: TimeInterval?) -> TimeInterval? {
        switch (lhs, rhs) {
        case let (lhs?, rhs?): max(lhs, rhs)
        case let (lhs?, nil): lhs
        case let (nil, rhs?): rhs
        case (nil, nil): nil
        }
    }

    private static let sentenceTerminators: Set<Character> = ["。", "！", "？", ".", "!", "?"]
}
