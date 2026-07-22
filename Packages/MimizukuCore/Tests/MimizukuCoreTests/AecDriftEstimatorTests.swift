import Foundation
import MimizukuCore
import Testing

@Suite("AecDriftEstimator")
struct AecDriftEstimatorTests {
    @Test("クロックが一致していればドリフトは出ず補正も不要")
    func perfectClock() {
        var estimator = AecDriftEstimator()
        for index in 0 ... 150 {
            estimator.record(sampleCount: 4800, hostTime: Double(index) * 0.1)
        }
        let ppm = estimator.driftPPM
        let interval = estimator.correctionInterval
        #expect(ppm != nil)
        if let ppm {
            #expect(abs(ppm) < 1)
        }
        #expect(interval == nil)
    }

    @Test("計測が 10 秒未満のうちは ppm を出さない")
    func tooShortForPPM() {
        var estimator = AecDriftEstimator()
        estimator.record(sampleCount: 4800, hostTime: 0)
        estimator.record(sampleCount: 4800, hostTime: 0.1)
        #expect(estimator.driftPPM == nil)
        #expect(estimator.correctionInterval == nil)
    }

    @Test("サンプルクロックが速い(+50ppm)と間引き補正を提示する")
    func fastSampleClock() {
        var estimator = AecDriftEstimator()
        // ホスト時計では 0.1 秒 ×(1 + 50ppm)間隔で 4800 サンプルずつ届く
        // …の逆: サンプルが余る = ホスト間隔が 0.1 ×(1 − 50ppm)。
        let hostStep = 0.1 * (1 - 50e-6)
        for index in 0 ... 150 {
            estimator.record(sampleCount: 4800, hostTime: Double(index) * hostStep)
        }
        let ppm = estimator.driftPPM
        let interval = estimator.correctionInterval
        #expect(ppm != nil)
        if let ppm {
            #expect(ppm > 45 && ppm < 55)
        }
        #expect(interval != nil)
        if let interval {
            // 正 = 間引き。おおよそ 1/50ppm = 2 万サンプルに 1 回。
            #expect(interval > 15000 && interval < 25000)
        }
    }

    @Test("サンプルクロックが遅い(−50ppm)と挿入補正(負値)を提示する")
    func slowSampleClock() {
        var estimator = AecDriftEstimator()
        let hostStep = 0.1 * (1 + 50e-6)
        for index in 0 ... 150 {
            estimator.record(sampleCount: 4800, hostTime: Double(index) * hostStep)
        }
        let interval = estimator.correctionInterval
        #expect(interval != nil)
        if let interval {
            #expect(interval < 0)
        }
    }

    @Test("空チャンクは記録に影響しない")
    func zeroCountIgnored() {
        var estimator = AecDriftEstimator()
        estimator.record(sampleCount: 0, hostTime: 0)
        estimator.record(sampleCount: 4800, hostTime: 100)
        #expect(estimator.driftPPM == nil)
    }
}
