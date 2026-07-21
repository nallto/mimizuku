import Foundation
import MimizukuCore
import Testing

@Suite("SessionRetention")
struct SessionRetentionTests {
    private let minimum: TimeInterval = 2.0

    @Test("録音が 1 本も無ければ破棄")
    func emptyDurationsDiscards() {
        #expect(SessionRetention.shouldDiscard(durations: [], minimumDuration: minimum))
    }

    @Test("全ストリームが閾値未満なら破棄")
    func allShortDiscards() {
        #expect(SessionRetention.shouldDiscard(durations: [0.0, 1.99], minimumDuration: minimum))
    }

    @Test("閾値ちょうどは保持(境界値)")
    func exactMinimumKeeps() {
        #expect(!SessionRetention.shouldDiscard(durations: [2.0], minimumDuration: minimum))
    }

    @Test("片方が短くても最長が閾値以上なら保持")
    func longestStreamDecides() {
        #expect(!SessionRetention.shouldDiscard(durations: [0.0, 3600.0], minimumDuration: minimum))
    }
}
