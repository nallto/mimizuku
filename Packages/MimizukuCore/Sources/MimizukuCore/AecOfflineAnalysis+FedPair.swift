import Foundation

// MARK: - サマリー集計(試行サマリー行の素材。Issue へ残す正式値なのでテストで固定する)

public extension AecOfflineAnalysis {
    /// 中央値。偶数件は中央 2 値の平均(一般的な定義)。空は nil。
    static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return (sorted[mid - 1] + sorted[mid]) / 2
        }
        return sorted[mid]
    }

    /// 窓別 verdict 列の要約(delay 中央値と estimate になった窓の割合)。
    struct DelaySummary: Sendable, Equatable {
        /// estimate 窓の遅延中央値(ms)。estimate が 1 つも無ければ nil。
        public let medianMs: Double?
        /// estimate になった窓の割合(0...1)。
        public let validRate: Double

        public init(medianMs: Double?, validRate: Double) {
            self.medianMs = medianMs
            self.validRate = validRate
        }
    }

    /// 窓別 verdict 列から `DelaySummary` を作る。窓が無ければ nil。
    static func delaySummary(_ verdicts: [WindowVerdict]) -> DelaySummary? {
        guard !verdicts.isEmpty else { return nil }
        let lagsMs = verdicts.compactMap { verdict -> Double? in
            guard case let .estimate(estimate) = verdict else { return nil }
            return estimate.lagSeconds * 1000
        }
        return DelaySummary(
            medianMs: median(lagsMs),
            validRate: Double(lagsMs.count) / Double(verdicts.count)
        )
    }
}

// MARK: - raw × render-fed(APM が見た参照系列)の窓解析

extension AecOfflineAnalysis {
    /// fed 対解析の入力(診断試行の記録一式)。
    public struct FedPairInput: Sendable {
        public var captures: [AecDiagnosticsRecord.Capture]
        public var fed: [AecDiagnosticsRecord.RenderFed]
        public var rawSamples: [Int16]
        public var fedSamples: [Int16]
        public var frameLength: Int
        public var sampleRate: Double

        public init(
            captures: [AecDiagnosticsRecord.Capture],
            fed: [AecDiagnosticsRecord.RenderFed],
            rawSamples: [Int16],
            fedSamples: [Int16],
            frameLength: Int,
            sampleRate: Double
        ) {
            self.captures = captures
            self.fed = fed
            self.rawSamples = rawSamples
            self.fedSamples = fedSamples
            self.frameLength = frameLength
            self.sampleRate = sampleRate
        }
    }

    /// fed 対の 1 窓の結果。
    public struct FedPairWindow: Sendable, Equatable {
        public let epoch: Int
        /// 窓開始の capture `frameIndex`。
        public let captureFrameIndex: Int
        public let verdict: WindowVerdict

        public init(epoch: Int, captureFrameIndex: Int, verdict: WindowVerdict) {
            self.epoch = epoch
            self.captureFrameIndex = captureFrameIndex
            self.verdict = verdict
        }
    }

    /// epoch ごとの整列済み系列(内部作業用)。
    private struct FedEpochSlice {
        let epoch: Int
        let processed: [AecDiagnosticsRecord.Capture]
        let captureAPM: [Int16]
        let fedAPM: [Int16]
        let fedHostTimes: [Double]
    }

    /// 窓割りと解析パラメータ(内部作業用)。
    private struct FedWindowing {
        let windowFrames: Int
        let hopFrames: Int
        let frameLength: Int
        let frameDuration: Double
        let sampleRate: Double
        let config: Config
    }

    /// 窓開始 capture の時刻に対応する fed フレーム位置を返す(hostTime 最近傍)。
    ///
    /// fed の hostTime は aligner が払い出したスロット時刻なので、capture の正規化
    /// 時刻と直接対応が取れる。グループ数のカウントで代用すると、1 capture の直前に
    /// 複数 fed(過去 −N×10ms を覆う group)がある場合にグループ先頭を capture と
    /// 同時刻とみなしてしまい、group 長ぶんの人工遅延が窓ごとに入る。
    ///
    /// - Returns: `hostTime ≤ captureHostTime + frameDuration/2` を満たす最後の fed の
    ///   位置。存在しなければ nil(その窓は判定不能)。
    public static func fedAnchorIndex(
        captureHostTime: Double,
        fedHostTimes: [Double],
        frameDuration: Double
    ) -> Int? {
        let cutoff = captureHostTime + frameDuration / 2
        var low = 0
        var high = fedHostTimes.count
        while low < high {
            let mid = (low + high) / 2
            if fedHostTimes[mid] <= cutoff {
                low = mid + 1
            } else {
                high = mid
            }
        }
        return low > 0 ? low - 1 : nil
    }

    /// raw × render-fed の窓別遅延解析(APM が見た参照系列の診断)。
    ///
    /// APM の内部時計は「処理済み(silenced=false)フレーム」だけ進むため、epoch ごとに
    /// silenced を除いた処理順を capture 軸として連結し、窓ごとに fed の hostTime から
    /// 対応点を復元して整列する(先頭同一原点・グループ数カウントのいずれも、fed が
    /// 0/1/複数のとき窓単位のずれを生む)。
    public static func analyzeFedPair(
        _ input: FedPairInput,
        config: Config = Config()
    ) -> [FedPairWindow] {
        let windowing = FedWindowing(
            windowFrames: Int(config.windowDuration * input.sampleRate) / input.frameLength,
            hopFrames: max(1, Int(config.hopDuration * input.sampleRate) / input.frameLength),
            frameLength: input.frameLength,
            frameDuration: Double(input.frameLength) / input.sampleRate,
            sampleRate: input.sampleRate,
            config: config
        )
        var results: [FedPairWindow] = []
        for epoch in Set(input.captures.map(\.epoch)).sorted() {
            guard let slice = makeEpochSlice(
                epoch: epoch,
                input: input,
                windowFrames: windowing.windowFrames
            ) else { continue }
            results.append(contentsOf: analyzeFedEpoch(slice, windowing: windowing))
        }
        return results
    }

    /// epoch の処理済み capture 列と fed 列を APM 時間軸で連結する。
    /// 窓を作れない epoch は nil。
    private static func makeEpochSlice(
        epoch: Int,
        input: FedPairInput,
        windowFrames: Int
    ) -> FedEpochSlice? {
        let processed = input.captures.filter { $0.epoch == epoch && !$0.silenced }
        let fedInEpoch = input.fed.filter { $0.epoch == epoch }
        guard processed.count >= windowFrames, !fedInEpoch.isEmpty else { return nil }
        var captureAPM: [Int16] = []
        captureAPM.reserveCapacity(processed.count * input.frameLength)
        for record in processed {
            let base = record.frameIndex * input.frameLength
            captureAPM.append(contentsOf: input.rawSamples[base ..< base + input.frameLength])
        }
        // fedIndex は昇順・epoch 内で連続(受付順の正典)。
        let fedBase = fedInEpoch[0].fedIndex * input.frameLength
        let fedEnd = (fedInEpoch[fedInEpoch.count - 1].fedIndex + 1) * input.frameLength
        return FedEpochSlice(
            epoch: epoch,
            processed: processed,
            captureAPM: captureAPM,
            fedAPM: Array(input.fedSamples[fedBase ..< fedEnd]),
            fedHostTimes: fedInEpoch.map(\.hostTime)
        )
    }

    private static func analyzeFedEpoch(
        _ slice: FedEpochSlice,
        windowing: FedWindowing
    ) -> [FedPairWindow] {
        var results: [FedPairWindow] = []
        var start = 0
        while start + windowing.windowFrames <= slice.processed.count {
            defer { start += windowing.hopFrames }
            results.append(analyzeFedWindow(slice, windowing: windowing, start: start))
        }
        return results
    }

    private static func analyzeFedWindow(
        _ slice: FedEpochSlice,
        windowing: FedWindowing,
        start: Int
    ) -> FedPairWindow {
        let frameIndex = slice.processed[start].frameIndex
        // 窓開始 capture の時刻に対応する fed 位置で再アンカーする。
        guard let anchorFrame = fedAnchorIndex(
            captureHostTime: slice.processed[start].hostTime,
            fedHostTimes: slice.fedHostTimes,
            frameDuration: windowing.frameDuration
        ) else {
            return FedPairWindow(
                epoch: slice.epoch,
                captureFrameIndex: frameIndex,
                verdict: .indeterminate(.insufficientRenderContext)
            )
        }
        let startSample = start * windowing.frameLength
        let windowSamples = windowing.windowFrames * windowing.frameLength
        let captureWindow = Array(
            slice.captureAPM[startSample ..< startSample + windowSamples]
        )
        let anchorFed = anchorFrame * windowing.frameLength
        let contextStart = max(0, anchorFed - Int(windowing.config.maxLag * windowing.sampleRate))
        let contextEnd = min(
            slice.fedAPM.count,
            anchorFed + windowSamples + Int(-windowing.config.minLag * windowing.sampleRate)
        )
        guard contextStart < contextEnd else {
            return FedPairWindow(
                epoch: slice.epoch,
                captureFrameIndex: frameIndex,
                verdict: .indeterminate(.insufficientRenderContext)
            )
        }
        let verdict = estimateDelay(
            capture: captureWindow,
            render: Array(slice.fedAPM[contextStart ..< contextEnd]),
            renderStartOffset: Double(contextStart - anchorFed) / windowing.sampleRate,
            sampleRate: windowing.sampleRate,
            config: windowing.config
        )
        return FedPairWindow(
            epoch: slice.epoch,
            captureFrameIndex: frameIndex,
            verdict: verdict
        )
    }
}
