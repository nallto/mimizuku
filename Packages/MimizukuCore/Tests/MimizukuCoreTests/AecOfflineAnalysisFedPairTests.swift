import Foundation
import MimizukuCore
import Testing

@Suite("AecOfflineAnalysisFedPair")
struct AecOfflineAnalysisFedPairTests {
    private let sampleRate = 48000.0

    /// 決定的な擬似乱数(LCG)。テストごとに seed を固定して再現可能にする。
    private func noise(count: Int, seed: UInt64, amplitude: Int16 = 10000) -> [Int16] {
        var state = seed
        return (0 ..< count).map { _ in
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            let normalized = Double(state >> 11) / Double(UInt64.max >> 11)
            return Int16((normalized * 2 - 1) * Double(amplitude))
        }
    }

    private struct FedPairFixture {
        let captures: [AecDiagnosticsRecord.Capture]
        let fed: [AecDiagnosticsRecord.RenderFed]
        let rawSamples: [Int16]
        let fedSamples: [Int16]
    }

    @Test("中央値: 奇数件は中央値、偶数件は中央 2 値の平均、空は nil")
    func medianDefinition() {
        #expect(AecOfflineAnalysis.median([3, 1, 2]) == 2)
        // 偶数件で上側を返す実装だと [0, 100] が 100 になる ―― 一般的な定義(平均 50)を固定。
        #expect(AecOfflineAnalysis.median([0, 100]) == 50)
        #expect(AecOfflineAnalysis.median([4, 1, 3, 2]) == 2.5)
        #expect(AecOfflineAnalysis.median([7]) == 7)
        // APM ERLE が全欠落(compactMap 結果が空)のケースはここに帰着する。
        #expect(AecOfflineAnalysis.median([]) == nil)
    }

    @Test("delaySummary: 全窓判定なし・混在・空の集計")
    func delaySummaryAggregation() {
        func estimate(_ ms: Double) -> AecOfflineAnalysis.WindowVerdict {
            .estimate(.init(lagSeconds: ms / 1000, peakCorrelation: 0.9))
        }
        let none = AecOfflineAnalysis.WindowVerdict.indeterminate(.lowCorrelation)

        // 全窓判定なし: 中央値なし・valid 率 0。
        let allNone = AecOfflineAnalysis.delaySummary([none, none, none])
        #expect(allNone == .init(medianMs: nil, validRate: 0))
        // 混在: estimate 2 / 4 窓 → 中央値は estimate のみから、valid 率 0.5。
        let mixed = AecOfflineAnalysis.delaySummary([estimate(10), none, estimate(30), none])
        #expect(mixed == .init(medianMs: 20, validRate: 0.5))
        // 窓なしは nil(CLI は n/a 表示)。
        #expect(AecOfflineAnalysis.delaySummary([]) == nil)
    }

    @Test("fed アンカー: hostTime 最近傍(半フレーム許容)で対応点を返す")
    func fedAnchorIndexUsesHostTimes() {
        let times = [0.15, 0.16, 0.17, 0.18, 0.19, 0.20]
        // capture 0.20 → 同時刻の末尾(index 5)。グループ先頭(0.15)ではない。
        #expect(AecOfflineAnalysis.fedAnchorIndex(
            captureHostTime: 0.20, fedHostTimes: times, frameDuration: 0.01
        ) == 5)
        // 半フレーム以内の未来はスロット同一とみなす。
        #expect(AecOfflineAnalysis.fedAnchorIndex(
            captureHostTime: 0.156, fedHostTimes: times, frameDuration: 0.01
        ) == 1)
        // fed がまだ無い時刻は nil(判定不能)。
        #expect(AecOfflineAnalysis.fedAnchorIndex(
            captureHostTime: 0.10, fedHostTimes: times, frameDuration: 0.01
        ) == nil)
        #expect(AecOfflineAnalysis.fedAnchorIndex(
            captureHostTime: 0.10, fedHostTimes: [], frameDuration: 0.01
        ) == nil)
    }

    @Test("fed 対解析: 複数 fed 先行グループでも最終遅延値が真値になる")
    func fedPairAnalysisSurvivesLeadingMultiFedGroup() throws {
        // 無音置換 20f → 処理済み 80f。最初の処理済み capture(frameIndex 20、t=10.20)の
        // 直前に −240〜0ms(maxRenderLead 相当)を覆う 25 枚の fed group がある。
        // グループ先頭を capture と同時刻とみなす整列では約 240ms の人工遅延が入る構成。
        // 途中に 0 枚(k=60)/ 2 枚(k=61)の group も混ぜる。真のエコー遅延は 120ms。
        let frameLength = 480
        let fixture = makeFedPairFixture(frameLength: frameLength, delay: 0.12)
        var config = AecOfflineAnalysis.Config()
        config.windowDuration = 0.5
        config.hopDuration = 0.5
        config.maxLag = 0.2
        config.decimationFactor = 12
        let results = AecOfflineAnalysis.analyzeFedPair(
            .init(
                captures: fixture.captures,
                fed: fixture.fed,
                rawSamples: fixture.rawSamples,
                fedSamples: fixture.fedSamples,
                frameLength: frameLength,
                sampleRate: sampleRate
            ),
            config: config
        )
        // 全ラグ範囲を探索できるのは先頭窓のみ(それ以降は fed の未来文脈が不足して
        // 保守的に判定なしとなる)。その先頭窓 = 25 枚グループ直後が真値 120ms を返す
        // (グループ先頭アンカーなら 240ms ずれる)。
        let first = try #require(results.first)
        #expect(first.captureFrameIndex == 20)
        guard case let .estimate(estimate) = first.verdict else {
            Issue.record("estimate ではなく \(first.verdict)")
            return
        }
        #expect(abs(estimate.lagSeconds - 0.12) < 0.003)
        #expect(estimate.peakCorrelation > 0.9)
    }

    /// fed の給餌スケジュール(スロット時刻と給餌先 capture)。
    /// 先行 group: t=9.96..10.20 の 25 枚(feedBefore = 最初の処理済み capture 20)。
    /// 以降は capture k=21..99 に対応。k=60 は 0 枚、k=61 は 2 枚(10.60 と 10.61)。
    private func makeFedSchedule(base: Double) -> (times: [Double], before: [Int]) {
        var fedTimes: [Double] = []
        var fedBefore: [Int] = []
        for index in 0 ..< 25 {
            fedTimes.append(base - 0.04 + Double(index) * 0.01)
            fedBefore.append(20)
        }
        for frame in 21 ..< 100 where frame != 60 {
            if frame == 61 {
                fedTimes.append(base + 0.60)
                fedBefore.append(61)
            }
            fedTimes.append(base + Double(frame) * 0.01)
            fedBefore.append(frame)
        }
        return (fedTimes, fedBefore)
    }

    /// fed 対解析の合成試行。fed の hostTime は aligner のスロット時刻を模し、
    /// capture 内容は「その時刻 − delay の fed 内容」(実時間対応)で構成する。
    private func makeFedPairFixture(
        frameLength: Int,
        delay: Double
    ) -> FedPairFixture {
        let base = 10.0
        let (fedTimes, fedBefore) = makeFedSchedule(base: base)
        let fedFrames = (0 ..< fedTimes.count)
            .map { noise(count: frameLength, seed: UInt64($0 + 1)) }
        // 時刻(センチ秒)→ fed index。
        var indexByCentis: [Int: Int] = [:]
        for (position, time) in fedTimes.enumerated() {
            indexByCentis[Int((time * 100).rounded())] = position
        }
        var captures: [AecDiagnosticsRecord.Capture] = []
        var rawFrames: [[Int16]] = []
        for frame in 0 ..< 100 {
            let silenced = frame < 20
            let time = base + Double(frame) * 0.01
            captures.append(.init(
                frameIndex: frame,
                outputFrameIndex: frame,
                speechTimeSeconds: Double(frame) * 0.01,
                hostTime: time,
                silenced: silenced,
                epoch: 0,
                rawRMSDBFS: -20,
                processedRMSDBFS: silenced ? nil : -40,
                renderFedCount: 0
            ))
            if silenced {
                rawFrames.append(noise(count: frameLength, seed: UInt64(1000 + frame)))
            } else if let source = indexByCentis[Int(((time - delay) * 100).rounded())] {
                rawFrames.append(fedFrames[source])
            } else {
                rawFrames.append(noise(count: frameLength, seed: UInt64(2000 + frame)))
            }
        }
        let fed = (0 ..< fedTimes.count).map { position in
            AecDiagnosticsRecord.RenderFed(
                fedIndex: position,
                hostTime: fedTimes[position],
                epoch: 0,
                provenance: .actual,
                fedBeforeCaptureFrameIndex: fedBefore[position],
                rmsDBFS: -20
            )
        }
        return FedPairFixture(
            captures: captures,
            fed: fed,
            rawSamples: rawFrames.flatMap(\.self),
            fedSamples: fedFrames.flatMap(\.self)
        )
    }
}
