import Foundation
import MimizukuCore
import Testing

@Suite("AecOfflineAnalysis")
struct AecOfflineAnalysisTests {
    private let sampleRate = 48000.0

    /// テスト実行時間短縮のため間引きを強める(4kHz、分解能 0.25ms ―― 許容誤差 2ms に
    /// 対して十分)。既定値そのものは `defaultConfigValues` で固定する。
    private var fastConfig: AecOfflineAnalysis.Config {
        var config = AecOfflineAnalysis.Config()
        config.decimationFactor = 12
        return config
    }

    @Test("既定パラメータは計画で固定した値のまま")
    func defaultConfigValues() {
        let config = AecOfflineAnalysis.Config()
        #expect(config.windowDuration == 1.0)
        #expect(config.hopDuration == 0.5)
        #expect(config.minLag == -0.1)
        #expect(config.maxLag == 0.5)
        #expect(config.minRenderRMSDBFS == -50)
        #expect(config.minCorrelation == 0.3)
        #expect(config.tiedPeakTolerance == 0.05)
        #expect(config.tiedPeakMinSeparation == 0.01)
        #expect(config.decimationFactor == 6)
    }

    /// 決定的な擬似乱数(LCG)。テストごとに seed を固定して再現可能にする。
    private func noise(count: Int, seed: UInt64, amplitude: Int16 = 10000) -> [Int16] {
        var state = seed
        return (0 ..< count).map { _ in
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            let normalized = Double(state >> 11) / Double(UInt64.max >> 11)
            return Int16((normalized * 2 - 1) * Double(amplitude))
        }
    }

    private struct EchoPair {
        let capture: [Int16]
        let render: [Int16]
        let offset: TimeInterval
    }

    /// render 系列と、そこから `delay` 秒遅れてエコーが乗った capture 窓を合成する。
    /// render は capture 窓の 0.5 秒前から 1.1 秒後までを覆う(renderStartOffset = -0.5)。
    private func makeEchoPair(delay: TimeInterval, seed: UInt64 = 1) -> EchoPair {
        let offset = -0.5
        let renderCount = Int(1.6 * sampleRate)
        let render = noise(count: renderCount, seed: seed)
        let windowCount = Int(1.0 * sampleRate)
        let shift = Int((-offset - delay) * sampleRate)
        let capture = (0 ..< windowCount).map { render[$0 + shift] }
        return EchoPair(capture: capture, render: render, offset: offset)
    }

    @Test("既知の正ラグ(render 先行 = echo delay)を推定する")
    func estimatesPositiveLag() throws {
        let pair = makeEchoPair(delay: 0.12)
        let verdict = AecOfflineAnalysis.estimateDelay(
            capture: pair.capture,
            render: pair.render,
            renderStartOffset: pair.offset,
            sampleRate: sampleRate,
            config: fastConfig
        )
        guard case let .estimate(estimate) = verdict else {
            Issue.record("estimate ではなく \(verdict)")
            return
        }
        // 間引き後の分解能(6/48000 = 0.125ms)+ ブロック平均の誤差を見込む。
        #expect(abs(estimate.lagSeconds - 0.12) < 0.002)
        #expect(estimate.peakCorrelation > 0.9)
    }

    @Test("既知の負ラグ(capture が先行)も符号どおり推定する")
    func estimatesNegativeLag() throws {
        let pair = makeEchoPair(delay: -0.05)
        let verdict = AecOfflineAnalysis.estimateDelay(
            capture: pair.capture,
            render: pair.render,
            renderStartOffset: pair.offset,
            sampleRate: sampleRate,
            config: fastConfig
        )
        guard case let .estimate(estimate) = verdict else {
            Issue.record("estimate ではなく \(verdict)")
            return
        }
        #expect(abs(estimate.lagSeconds - -0.05) < 0.002)
    }

    @Test("探索境界に一致するラグは boundaryPeak として判定しない")
    func boundaryPeakIsIndeterminate() {
        // 真の遅延 = maxLag(0.5 秒)ちょうど → 境界の最大は信用しない。
        let pair = makeEchoPair(delay: 0.5)
        let verdict = AecOfflineAnalysis.estimateDelay(
            capture: pair.capture,
            render: pair.render,
            renderStartOffset: pair.offset,
            sampleRate: sampleRate,
            config: fastConfig
        )
        #expect(verdict == .indeterminate(.boundaryPeak))
    }

    @Test("無相関ノイズは lowCorrelation として判定しない")
    func uncorrelatedNoiseIsIndeterminate() {
        let render = noise(count: Int(1.6 * sampleRate), seed: 1)
        let capture = noise(count: Int(1.0 * sampleRate), seed: 99)
        let verdict = AecOfflineAnalysis.estimateDelay(
            capture: capture,
            render: render,
            renderStartOffset: -0.5,
            sampleRate: sampleRate,
            config: fastConfig
        )
        #expect(verdict == .indeterminate(.lowCorrelation))
    }

    @Test("周期信号(同率ピーク)は tiedPeaks として判定しない")
    func periodicSignalIsIndeterminate() {
        // 周期 50ms の正弦波はラグ ±50ms ごとに同じ高さのピークを持つ。
        let renderCount = Int(1.6 * sampleRate)
        let render = (0 ..< renderCount).map { index in
            Int16(8000 * sin(2 * .pi * 20 * Double(index) / sampleRate))
        }
        let windowCount = Int(1.0 * sampleRate)
        let shift = Int((0.5 - 0.12) * sampleRate)
        let capture = (0 ..< windowCount).map { render[$0 + shift] }
        let verdict = AecOfflineAnalysis.estimateDelay(
            capture: capture,
            render: render,
            renderStartOffset: -0.5,
            sampleRate: sampleRate,
            config: fastConfig
        )
        #expect(verdict == .indeterminate(.tiedPeaks))
    }

    @Test("完全無音の窓は zeroSignal として判定しない")
    func zeroSignalIsIndeterminate() {
        let render = noise(count: Int(1.6 * sampleRate), seed: 1)
        let capture = [Int16](repeating: 0, count: Int(1.0 * sampleRate))
        let verdict = AecOfflineAnalysis.estimateDelay(
            capture: capture,
            render: render,
            renderStartOffset: -0.5,
            sampleRate: sampleRate,
            config: fastConfig
        )
        #expect(verdict == .indeterminate(.zeroSignal))
    }

    @Test("render が最小レベル未満の窓は renderTooQuiet として判定しない")
    func quietRenderIsIndeterminate() {
        // 振幅 3 ≒ −81 dBFS(閾値 −50 dBFS 未満)。
        let render = noise(count: Int(1.6 * sampleRate), seed: 1, amplitude: 3)
        let capture = noise(count: Int(1.0 * sampleRate), seed: 2)
        let verdict = AecOfflineAnalysis.estimateDelay(
            capture: capture,
            render: render,
            renderStartOffset: -0.5,
            sampleRate: sampleRate,
            config: fastConfig
        )
        #expect(verdict == .indeterminate(.renderTooQuiet))
    }

    @Test("窓長未満の capture は windowTooShort として判定しない")
    func shortWindowIsIndeterminate() {
        let render = noise(count: Int(1.6 * sampleRate), seed: 1)
        let capture = noise(count: Int(0.5 * sampleRate), seed: 1)
        let verdict = AecOfflineAnalysis.estimateDelay(
            capture: capture,
            render: render,
            renderStartOffset: -0.5,
            sampleRate: sampleRate,
            config: fastConfig
        )
        #expect(verdict == .indeterminate(.windowTooShort))
    }

    @Test("ラグ探索を覆えない短い render は insufficientRenderContext")
    func shortRenderContextIsIndeterminate() {
        let render = noise(count: 480, seed: 1)
        let capture = noise(count: Int(1.0 * sampleRate), seed: 1)
        let verdict = AecOfflineAnalysis.estimateDelay(
            capture: capture,
            render: render,
            renderStartOffset: 0,
            sampleRate: sampleRate,
            config: fastConfig
        )
        #expect(verdict == .indeterminate(.insufficientRenderContext))
    }
}
