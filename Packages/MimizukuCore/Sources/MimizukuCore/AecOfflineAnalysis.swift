import Foundation

/// 診断試行の CAF から遅延・残留を後段計算する純ロジック(#75)。
///
/// ライブ経路では計算しない(観測がタイミングへ影響しないよう、記録した音声からの
/// オフライン解析に限る)。単純な相互相関は近端発話・無音・音楽の周期性で誤判定する
/// ため、正規化相互相関 + 有効窓条件で「判定なし」を明示的に返す。
public enum AecOfflineAnalysis {
    /// 解析パラメータ。既定値はテストで固定する(変更は意図的な再調整のみ)。
    public struct Config: Sendable {
        /// 解析窓長(秒)。
        public var windowDuration: TimeInterval = 1.0
        /// 窓のホップ(秒)。
        public var hopDuration: TimeInterval = 0.5
        /// ラグ探索範囲(秒)。**正 = render が capture より先行(= echo delay)**。
        public var minLag: TimeInterval = -0.1
        public var maxLag: TimeInterval = 0.5
        /// render がこの RMS(dBFS)未満の窓は判定しない。
        public var minRenderRMSDBFS: Double = -50
        /// 正規化相互相関ピークの最小値。未満は判定しない。
        public var minCorrelation: Double = 0.3
        /// ピークとの差がこの比率未満の別ピークがあれば同率とみなし判定しない。
        public var tiedPeakTolerance: Double = 0.05
        /// 同率ピークとして数える最小ラグ差(秒)。隣接ラグの自然な相関を除外する。
        public var tiedPeakMinSeparation: TimeInterval = 0.01
        /// 相関計算前の間引き係数(48kHz ÷ 6 = 8kHz。遅延分解能 0.125ms で十分)。
        public var decimationFactor: Int = 6

        public init() {}
    }

    public struct DelayEstimate: Sendable, Equatable {
        /// 推定遅延(秒)。正 = render が先行。
        public let lagSeconds: TimeInterval
        /// ピークの正規化相互相関(絶対値。極性反転に頑健にするため)。
        public let peakCorrelation: Double

        public init(lagSeconds: TimeInterval, peakCorrelation: Double) {
            self.lagSeconds = lagSeconds
            self.peakCorrelation = peakCorrelation
        }
    }

    public enum IndeterminateReason: String, Sendable, Equatable {
        case windowTooShort
        case zeroSignal
        case renderTooQuiet
        case insufficientRenderContext
        case boundaryPeak
        case tiedPeaks
        case lowCorrelation
    }

    public enum WindowVerdict: Sendable, Equatable {
        case estimate(DelayEstimate)
        case indeterminate(IndeterminateReason)
    }

    /// 1 窓の capture × render 遅延を正規化相互相関で推定する。
    ///
    /// - Parameters:
    ///   - capture: 解析窓(長さ ≥ `config.windowDuration`)。
    ///   - render: 参照系列。ラグ探索に必要な前後を含めて切り出して渡す
    ///     (目安: capture 窓の `maxLag` 秒前から `-minLag` 秒後まで)。
    ///   - renderStartOffset: `render[0]` の時刻 − `capture[0]` の時刻(秒)。
    ///     負 = render の切り出しが capture 窓より先に始まる。
    public static func estimateDelay(
        capture: [Int16],
        render: [Int16],
        renderStartOffset: TimeInterval,
        sampleRate: Double,
        config: Config = Config()
    ) -> WindowVerdict {
        if let reason = precheck(
            capture: capture,
            render: render,
            sampleRate: sampleRate,
            config: config
        ) {
            return .indeterminate(reason)
        }

        let factor = max(1, config.decimationFactor)
        let decimatedRate = sampleRate / Double(factor)
        let minLagSamples = Int((config.minLag * decimatedRate).rounded(.up))
        let maxLagSamples = Int((config.maxLag * decimatedRate).rounded(.down))
        guard minLagSamples <= maxLagSamples else {
            return .indeterminate(.insufficientRenderContext)
        }
        let correlations = scanCorrelations(
            capture: decimate(capture, factor: factor),
            render: decimate(render, factor: factor),
            offsetShift: Int((renderStartOffset * decimatedRate).rounded()),
            lagRange: minLagSamples ... maxLagSamples
        )
        return judgePeak(
            correlations,
            lagRange: minLagSamples ... maxLagSamples,
            decimatedRate: decimatedRate,
            config: config
        )
    }

    /// 窓自体の有効性(長さ・無音・render レベル)を判定する。無効なら理由を返す。
    private static func precheck(
        capture: [Int16],
        render: [Int16],
        sampleRate: Double,
        config: Config
    ) -> IndeterminateReason? {
        guard Double(capture.count) / sampleRate >= config.windowDuration - 1e-9 else {
            return .windowTooShort
        }
        guard AecAudioMetrics.rmsDBFS(capture) != nil else {
            return .zeroSignal
        }
        guard let renderRMS = AecAudioMetrics.rmsDBFS(render) else {
            return .zeroSignal
        }
        guard renderRMS >= config.minRenderRMSDBFS else {
            return .renderTooQuiet
        }
        return nil
    }

    /// ラグ ℓ(間引きサンプル)で capture[i] ↔ render[i − ℓ − offsetShift] を比較し、
    /// 範囲内で計算可能な全ラグの正規化相互相関(絶対値)を返す。
    /// D = ℓ / decimatedRate が「render が先行する秒数」。
    private static func scanCorrelations(
        capture: [Double],
        render: [Double],
        offsetShift: Int,
        lagRange: ClosedRange<Int>
    ) -> [(lagSamples: Int, value: Double)] {
        let captureEnergy = energy(capture)
        guard captureEnergy > 0 else { return [] }
        let renderPrefix = prefixSquares(render)
        var correlations: [(lagSamples: Int, value: Double)] = []
        for lag in lagRange {
            let shift = lag + offsetShift
            let firstIndex = 0 - shift
            let lastIndex = capture.count - 1 - shift
            guard firstIndex >= 0, lastIndex < render.count else { continue }

            var dot = 0.0
            for (index, value) in capture.enumerated() {
                dot += value * render[index - shift]
            }
            let renderEnergy = renderPrefix[lastIndex + 1] - renderPrefix[firstIndex]
            guard renderEnergy > 0 else { continue }
            let ncc = dot / (captureEnergy * renderEnergy).squareRoot()
            correlations.append((lag, abs(ncc)))
        }
        return correlations
    }

    /// 相関列からピークを選び、境界・同率・低相関を「判定なし」として除外する。
    private static func judgePeak(
        _ correlations: [(lagSamples: Int, value: Double)],
        lagRange: ClosedRange<Int>,
        decimatedRate: Double,
        config: Config
    ) -> WindowVerdict {
        guard let peak = correlations.max(by: { $0.value < $1.value }) else {
            return .indeterminate(.insufficientRenderContext)
        }
        guard peak.value >= config.minCorrelation else {
            return .indeterminate(.lowCorrelation)
        }
        // 探索境界での最大は「範囲外に真のピークがある」可能性を否定できない。
        // 境界ラグが範囲内で計算できなかった(候補から欠けた)場合も同様に扱う。
        let searchedMin = correlations.first?.lagSamples ?? lagRange.lowerBound
        let searchedMax = correlations.last?.lagSamples ?? lagRange.upperBound
        let atBoundary = peak.lagSamples == searchedMin || peak.lagSamples == searchedMax
            || searchedMin != lagRange.lowerBound || searchedMax != lagRange.upperBound
        if atBoundary {
            return .indeterminate(.boundaryPeak)
        }
        // 同率ピーク(周期信号のサイン): 十分離れたラグに近い高さの山があれば不定。
        let separation = Int((config.tiedPeakMinSeparation * decimatedRate).rounded(.up))
        let threshold = peak.value * (1 - config.tiedPeakTolerance)
        let tied = correlations.contains { candidate in
            abs(candidate.lagSamples - peak.lagSamples) > separation
                && candidate.value >= threshold
        }
        if tied {
            return .indeterminate(.tiedPeaks)
        }
        return .estimate(DelayEstimate(
            lagSeconds: Double(peak.lagSamples) / decimatedRate,
            peakCorrelation: peak.value
        ))
    }

    // MARK: - Helpers

    /// ブロック平均による間引き(簡易ローパス)。相関のラグ推定には十分。
    static func decimate(_ samples: [Int16], factor: Int) -> [Double] {
        guard factor > 1 else { return samples.map(Double.init) }
        var result: [Double] = []
        result.reserveCapacity(samples.count / factor)
        var index = 0
        while index + factor <= samples.count {
            var sum = 0.0
            for offset in 0 ..< factor {
                sum += Double(samples[index + offset])
            }
            result.append(sum / Double(factor))
            index += factor
        }
        return result
    }

    private static func energy(_ samples: [Double]) -> Double {
        samples.reduce(0) { $0 + $1 * $1 }
    }

    /// prefix[i] = samples[0..<i] の二乗和。区間エネルギーを O(1) で引くため。
    private static func prefixSquares(_ samples: [Double]) -> [Double] {
        var prefix = [Double](repeating: 0, count: samples.count + 1)
        for (index, value) in samples.enumerated() {
            prefix[index + 1] = prefix[index] + value * value
        }
        return prefix
    }
}
