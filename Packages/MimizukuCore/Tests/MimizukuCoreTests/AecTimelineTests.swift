import Foundation
import MimizukuCore
import Testing

@Suite("AecTimeline")
struct AecTimelineTests {
    @Test("ジッタのある実測時刻が連続タイムラインへ正規化される")
    func jitterIsAbsorbed() {
        var timeline = AecTimeline(rebaseThreshold: 0.25)
        let chunk = 4096
        let duration = Double(chunk) / 48000
        var normalized: [TimeInterval] = []
        // ±20ms のジッタ(AecFramer の許容 5ms を大きく超える)を混ぜる。
        let jitters: [TimeInterval] = [0, 0.02, -0.015, 0.01, -0.02, 0.018]
        for (index, jitter) in jitters.enumerated() {
            let measured = Double(index) * duration + jitter
            normalized.append(timeline.normalize(hostTime: measured, sampleCount: chunk))
        }
        for index in 1 ..< normalized.count {
            let delta = normalized[index] - normalized[index - 1]
            #expect(abs(delta - duration) < 1e-9)
        }
        #expect(timeline.rebases == 0)
    }

    @Test("正規化した時刻は AecFramer の不連続判定を発生させない")
    func normalizedTimesKeepFramerContinuous() {
        var timeline = AecTimeline(rebaseThreshold: 0.25)
        var framer = AecFramer()
        let chunk = 4096
        let duration = Double(chunk) / 48000
        var frames = 0
        for index in 0 ..< 20 {
            let measured = Double(index) * duration + (index.isMultiple(of: 2) ? 0.02 : -0.02)
            let time = timeline.normalize(hostTime: measured, sampleCount: chunk)
            frames += framer.append(samples: [Int16](repeating: 1, count: chunk), hostTime: time)
                .count
        }
        // 20 × 4096 = 81920 サンプル → 480 で 170 フレーム。破棄ゼロ。
        #expect(frames == 170)
        #expect(framer.discardedSamples == 0)
    }

    @Test("閾値超の不連続(本物の欠落)はリベースして実測へ追従する")
    func realGapRebases() {
        var timeline = AecTimeline(rebaseThreshold: 0.05)
        let chunk = 480
        _ = timeline.normalize(hostTime: 0, sampleCount: chunk)
        _ = timeline.normalize(hostTime: 0.01, sampleCount: chunk)
        // 500ms 飛ぶ(tap 再構築相当)→ 実測へ追従。
        let rebased = timeline.normalize(hostTime: 0.52, sampleCount: chunk)
        #expect(rebased == 0.52)
        #expect(timeline.rebases == 1)
        // 以後はリベース後の基準から連続。
        let next = timeline.normalize(hostTime: 0.53, sampleCount: chunk)
        #expect(abs(next - (0.52 + Double(chunk) / 48000)) < 1e-9)
    }
}
