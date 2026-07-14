import Foundation
import Testing
@testable import MimizukuCore

// CI で初日から `swift test` が通るためのプレースホルダ。
// 実テスト予定: TranscriptSegment の JSONL エンコード、ゼロサンプル検知ロジック、
// セッション状態機械、ルーティングロジック。
// 注意: TCC 権限(マイク / システム音声)を要するテストはホスト型 CI ランナーで
// 実行できない。ローカル限定のテストプランに隔離すること(docs/domain-pitfalls.md #8)。

@Test func streamKindHasTwoCases() {
    #expect(StreamKind.allCases.count == 2)
}

@Test func segmentRoundTripsThroughJSON() throws {
    let segment = TranscriptSegment(
        stream: .microphone,
        text: "hello",
        isFinal: true,
        start: 0.0,
        end: 1.2
    )
    let data = try JSONEncoder().encode(segment)
    let decoded = try JSONDecoder().decode(TranscriptSegment.self, from: data)
    #expect(decoded.text == "hello")
    #expect(decoded.stream == .microphone)
    #expect(decoded.isFinal)
}
