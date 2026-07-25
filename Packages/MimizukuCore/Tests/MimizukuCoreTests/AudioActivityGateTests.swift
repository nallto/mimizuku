import Foundation
import MimizukuCore
import Testing

@Suite("AudioActivityGate")
struct AudioActivityGateTests {
    @Test("閾値以上で一度だけアクティブ遷移を返す(閾値ちょうどはアクティブ)")
    func risesOnce() {
        var gate = AudioActivityGate(thresholdDBFS: -42, hangover: 0.4)
        let first = gate.observe(levelDBFS: -42, at: 0)
        let second = gate.observe(levelDBFS: -30, at: 0.1)
        #expect(first == true)
        #expect(second == nil)
    }

    @Test("閾値未満でもハングオーバー内は落ちない")
    func hangoverKeepsActive() {
        var gate = AudioActivityGate(thresholdDBFS: -42, hangover: 0.4)
        _ = gate.observe(levelDBFS: -30, at: 0)
        let within = gate.observe(levelDBFS: -60, at: 0.3)
        #expect(within == nil)
    }

    @Test("ハングオーバー経過で一度だけ非アクティブ遷移を返す")
    func fallsAfterHangover() {
        var gate = AudioActivityGate(thresholdDBFS: -42, hangover: 0.4)
        _ = gate.observe(levelDBFS: -30, at: 0)
        let fall = gate.observe(levelDBFS: -60, at: 0.5)
        let again = gate.observe(levelDBFS: -60, at: 0.6)
        #expect(fall == false)
        #expect(again == nil)
    }

    @Test("非アクティブのまま静音が続いても遷移は出ない")
    func silentStaysQuiet() {
        var gate = AudioActivityGate(thresholdDBFS: -42, hangover: 0.4)
        #expect(gate.observe(levelDBFS: -70, at: 0) == nil)
        #expect(gate.observe(levelDBFS: -70, at: 1) == nil)
    }

    @Test("再アクティブ化でハングオーバー起点が更新される")
    func reactivationRefreshesHangover() {
        var gate = AudioActivityGate(thresholdDBFS: -42, hangover: 0.4)
        _ = gate.observe(levelDBFS: -30, at: 0)
        _ = gate.observe(levelDBFS: -30, at: 1.0)
        // 起点 1.0 から 0.3 秒後はまだ落ちない。
        #expect(gate.observe(levelDBFS: -60, at: 1.3) == nil)
        #expect(gate.observe(levelDBFS: -60, at: 1.5) == false)
    }
}
