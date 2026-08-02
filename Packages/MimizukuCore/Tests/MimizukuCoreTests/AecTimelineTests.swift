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
            normalized.append(timeline.normalize(hostTime: measured, sampleCount: chunk).hostTime)
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
            let time = timeline.normalize(hostTime: measured, sampleCount: chunk).hostTime
            frames += framer.append(samples: [Int16](repeating: 1, count: chunk), hostTime: time)
                .frames.count
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
        #expect(rebased.hostTime == 0.52)
        #expect(rebased.rebased)
        #expect(timeline.rebases == 1)
        // 以後はリベース後の基準から連続。
        let next = timeline.normalize(hostTime: 0.53, sampleCount: chunk)
        #expect(abs(next.hostTime - (0.52 + Double(chunk) / 48000)) < 1e-9)
    }

    @Test("初回チャンクは予測を持たない(predicted / delta は nil)")
    func firstChunkHasNoPrediction() {
        var timeline = AecTimeline(rebaseThreshold: 0.25)
        let first = timeline.normalize(hostTime: 3.0, sampleCount: 480)
        #expect(first.hostTime == 3.0)
        #expect(first.predictedHostTime == nil)
        #expect(first.delta == nil)
        #expect(!first.rebased)
    }

    @Test("2 チャンク目以降は実測−予測の delta を報告する")
    func subsequentChunksReportDelta() {
        var timeline = AecTimeline(rebaseThreshold: 0.25)
        let chunk = 480
        let duration = Double(chunk) / 48000
        _ = timeline.normalize(hostTime: 0, sampleCount: chunk)
        // 実測が予測より 2ms 遅れて到着した(ジッタ内)。
        let second = timeline.normalize(hostTime: duration + 0.002, sampleCount: chunk)
        #expect(second.predictedHostTime == duration)
        #expect(abs((second.delta ?? 0) - 0.002) < 1e-9)
        #expect(!second.rebased)
        // 正規化時刻はジッタを含まない予測値。
        #expect(second.hostTime == duration)
    }

    @Test("rebase 時の delta は閾値超の実測−予測を保持する")
    func rebaseReportsDelta() {
        var timeline = AecTimeline(rebaseThreshold: 0.05)
        let chunk = 480
        let duration = Double(chunk) / 48000
        _ = timeline.normalize(hostTime: 0, sampleCount: chunk)
        let rebased = timeline.normalize(hostTime: 0.51, sampleCount: chunk)
        #expect(rebased.rebased)
        #expect(rebased.predictedHostTime == duration)
        #expect(abs((rebased.delta ?? 0) - (0.51 - duration)) < 1e-9)
    }
}
