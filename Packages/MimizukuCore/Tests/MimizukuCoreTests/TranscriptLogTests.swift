import Foundation
import Testing
@testable import MimizukuCore

// TranscriptLog(純粋な集約ロジック)の境界値・異常系テスト。
// volatile→final 収束、空文字、到着順、2 ストリームの独立性を検証する。

private func vol(_ stream: StreamKind, _ text: String) -> TranscriptSegment {
    TranscriptSegment(stream: stream, text: text, isFinal: false)
}

private func fin(_ stream: StreamKind, _ text: String) -> TranscriptSegment {
    TranscriptSegment(stream: stream, text: text, isFinal: true)
}

@Test func emptyLogHasNoLines() {
    let log = TranscriptLog()
    #expect(log.finalized.isEmpty)
    #expect(log.volatileLines.isEmpty)
    #expect(log.volatile(for: .microphone) == nil)
}

@Test func volatileUpdatesReplaceRatherThanAccumulate() {
    var log = TranscriptLog()
    log.apply(vol(.microphone, "こん"))
    log.apply(vol(.microphone, "こんにち"))
    #expect(log.volatile(for: .microphone)?.text == "こんにち")
    #expect(log.volatileLines.count == 1)
    #expect(log.finalized.isEmpty)
}

@Test func finalConvergesAndClearsVolatile() {
    var log = TranscriptLog()
    log.apply(vol(.microphone, "こん"))
    log.apply(vol(.microphone, "こんにち"))
    log.apply(fin(.microphone, "こんにちは"))
    #expect(log.finalized.map(\.text) == ["こんにちは"])
    #expect(log.volatile(for: .microphone) == nil)
    #expect(log.volatileLines.isEmpty)
}

@Test func finalizedSegmentsKeepArrivalOrder() {
    var log = TranscriptLog()
    log.apply(fin(.microphone, "一"))
    log.apply(fin(.microphone, "二"))
    log.apply(fin(.microphone, "三"))
    #expect(log.finalized.map(\.text) == ["一", "二", "三"])
}

@Test func emptyFinalDoesNotAppendButClearsVolatile() {
    var log = TranscriptLog()
    log.apply(vol(.microphone, "途中"))
    log.apply(fin(.microphone, "   "))
    #expect(log.finalized.isEmpty)
    #expect(log.volatile(for: .microphone) == nil)
}

@Test func emptyVolatileClearsStreamVolatile() {
    var log = TranscriptLog()
    log.apply(vol(.microphone, "途中"))
    log.apply(vol(.microphone, ""))
    #expect(log.volatile(for: .microphone) == nil)
    #expect(log.finalized.isEmpty)
}

@Test func streamsAreIndependent() {
    var log = TranscriptLog()
    log.apply(vol(.microphone, "自分の途中"))
    log.apply(vol(.systemAudio, "相手の途中"))
    // マイクの確定は systemAudio の volatile を消さない(docs/domain-pitfalls.md #7)。
    log.apply(fin(.microphone, "自分の確定"))
    #expect(log.finalized.map(\.text) == ["自分の確定"])
    #expect(log.volatile(for: .microphone) == nil)
    #expect(log.volatile(for: .systemAudio)?.text == "相手の途中")
    #expect(log.volatileLines.count == 1)
}

@Test func volatileLinesAreOrderedByStreamDeclaration() {
    var log = TranscriptLog()
    log.apply(vol(.systemAudio, "相手"))
    log.apply(vol(.microphone, "自分"))
    // StreamKind の宣言順(microphone, systemAudio)で安定表示する。
    #expect(log.volatileLines.map(\.stream) == [.microphone, .systemAudio])
}
