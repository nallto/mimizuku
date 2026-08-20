import Foundation
import Testing

@testable import MimizukuCore

struct CaptureGapFillerTests {
    private func makeFiller(
        sampleRate: Double = 48000,
        threshold: TimeInterval = 0.25
    ) -> CaptureGapFiller {
        CaptureGapFiller(sampleRate: sampleRate, fillThreshold: threshold)
    }

    @Test("初回バッファは起点を作るだけで発火しない")
    func firstObserveEstablishesBaseline() {
        var filler = makeFiller()
        #expect(filler.observe(hostTime: 100, frameCount: 480) == nil)
        #expect(filler.fillCount == 0)
    }

    @Test("正確な周期の連続ストリームでは発火しない")
    func continuousStreamNeverFills() {
        var filler = makeFiller()
        // 10ms(480 フレーム @48kHz)刻みの正確な列。
        for index in 0 ..< 1000 {
            let hostTime = 100 + Double(index) * 0.01
            #expect(filler.observe(hostTime: hostTime, frameCount: 480) == nil)
        }
        #expect(filler.fillCount == 0)
        #expect(filler.filledFrames == 0)
    }

    @Test("閾値以下のジッタでは発火せず、予測タイムラインにも影響しない")
    func jitterBelowThresholdIsAbsorbed() {
        var filler = makeFiller()
        _ = filler.observe(hostTime: 100, frameCount: 480)
        // ±0.2 秒のジッタ(閾値 0.25 未満)を交互に与える。
        for index in 1 ..< 100 {
            let jitter = index.isMultiple(of: 2) ? 0.2 : -0.2
            let hostTime = 100 + Double(index) * 0.01 + jitter
            #expect(filler.observe(hostTime: hostTime, frameCount: 480) == nil)
        }
        // ジッタが予測を汚していなければ、正確な時刻へ戻っても発火しない。
        #expect(filler.observe(hostTime: 101, frameCount: 480) == nil)
        #expect(filler.fillCount == 0)
    }

    /// 欠落長は可変である(#116 の前提)。短い・長い・分単位の欠落を同じロジックが
    /// 実測どおりのフレーム数へ換算することを固定する。
    @Test(
        "欠落長を実測どおりのフレーム数へ換算する(可変長)",
        arguments: [
            (gap: 0.5, expectedFrames: 24000),
            (gap: 1.9, expectedFrames: 91200),
            (gap: 20.7, expectedFrames: 993_600),
            (gap: 129.0, expectedFrames: 6_192_000)
        ]
    )
    func variableGapLengthsAreMeasured(gap: TimeInterval, expectedFrames: Int) {
        var filler = makeFiller()
        _ = filler.observe(hostTime: 100, frameCount: 480)
        // 予測される次バッファは 100.01。そこから gap 秒遅れて到着する。
        let result = filler.observe(hostTime: 100.01 + gap, frameCount: 480)
        #expect(result?.frames == expectedFrames)
        #expect(result.map { abs($0.seconds - gap) < 1e-9 } == true)
    }

    @Test("連続した欠落はそれぞれ独立に実測され、総量が積算される")
    func consecutiveGapsAreMeasuredIndependently() {
        var filler = makeFiller()
        _ = filler.observe(hostTime: 100, frameCount: 480)
        let first = filler.observe(hostTime: 100.01 + 0.5, frameCount: 480)
        #expect(first?.frames == 24000)
        // 1 つ目の欠落で起点は実測(100.51)へ追従済み。そこからさらに 2.0 秒欠ける。
        let second = filler.observe(hostTime: 100.52 + 2.0, frameCount: 480)
        #expect(second?.frames == 96000)
        #expect(filler.fillCount == 2)
        #expect(filler.filledFrames == 24000 + 96000)
    }

    @Test("発火後は実測へ追従し、丸め誤差を次回へ累積させない")
    func fillRebasesToObservedTime() {
        var filler = makeFiller()
        _ = filler.observe(hostTime: 100, frameCount: 480)
        // フレーム境界に載らない半端な欠落(0.5001 秒 → 24004.8 → 24005 フレーム)。
        let gap = filler.observe(hostTime: 100.01 + 0.5001, frameCount: 480)
        #expect(gap?.frames == 24005)
        // 以後、実測時刻を起点にした正確な周期なら発火しない(丸めの 0.2 フレーム分が
        // 残留していれば、どこかで閾値を超えてしまう)。
        for index in 1 ..< 1000 {
            let hostTime = 100.5101 + Double(index) * 0.01
            #expect(filler.observe(hostTime: hostTime, frameCount: 480) == nil)
        }
    }

    @Test("閾値ちょうどでは発火しない(超えたときだけ)")
    func exactThresholdDoesNotFill() {
        // 2 進で正確に表せる値だけを使う(sampleRate 1000 / 0.5 秒周期 / 閾値 0.5)。
        var filler = makeFiller(sampleRate: 1000, threshold: 0.5)
        _ = filler.observe(hostTime: 100, frameCount: 500)
        // 予測 100.5 に対し 101.0 到着 = ずれ 0.5 ちょうど → 発火しない(ジッタ扱い。
        // 予測タイムラインは元の起点のまま進む)。
        #expect(filler.observe(hostTime: 101.0, frameCount: 500) == nil)
        // 予測 101.0 に対し 101.51 到着 = ずれ 0.51 → 発火する。
        #expect(filler.observe(hostTime: 101.51, frameCount: 500)?.frames == 510)
    }

    @Test("早い方向の跳びは無音を挿入せず、実測へ追従だけする")
    func backwardJumpNeverInserts() {
        var filler = makeFiller()
        _ = filler.observe(hostTime: 100, frameCount: 480)
        // 予測(100.01)より 1 秒早い到着。時間を削る操作はしない。
        #expect(filler.observe(hostTime: 99.01, frameCount: 480) == nil)
        #expect(filler.backwardRebases == 1)
        #expect(filler.filledFrames == 0)
        // 追従後の周期では発火しない。
        #expect(filler.observe(hostTime: 99.02, frameCount: 480) == nil)
    }

    @Test("非有限の時刻は判定せず、次の正常な時刻で再開する")
    func nonFiniteHostTimeIsSkipped() {
        var filler = makeFiller()
        _ = filler.observe(hostTime: 100, frameCount: 480)
        #expect(filler.observe(hostTime: .nan, frameCount: 480) == nil)
        #expect(filler.observe(hostTime: .infinity, frameCount: 480) == nil)
        // 壊れた時刻を起点にしていなければ、正常へ戻った周期の判定が成立する。
        #expect(filler.observe(hostTime: 100.03, frameCount: 480) == nil)
        #expect(filler.fillCount == 0)
    }

    @Test("フレーム数ゼロのバッファは無視する")
    func zeroFrameCountIsIgnored() {
        var filler = makeFiller()
        _ = filler.observe(hostTime: 100, frameCount: 480)
        #expect(filler.observe(hostTime: 100.01, frameCount: 0) == nil)
        // タイムラインが進んでいないので、次の正常バッファでも発火しない。
        #expect(filler.observe(hostTime: 100.01, frameCount: 480) == nil)
    }

    @Test("チャンク分割は合計を保ち、上限を超えない")
    func chunkLengthsPreserveTotal() {
        #expect(
            CaptureGapFiller.chunkLengths(totalFrames: 100_000, maxChunkFrames: 48000)
                == [48000, 48000, 4000]
        )
        #expect(
            CaptureGapFiller.chunkLengths(totalFrames: 48000, maxChunkFrames: 48000)
                == [48000]
        )
        #expect(CaptureGapFiller.chunkLengths(totalFrames: 100, maxChunkFrames: 48000) == [100])
        #expect(CaptureGapFiller.chunkLengths(totalFrames: 0, maxChunkFrames: 48000).isEmpty)
        #expect(CaptureGapFiller.chunkLengths(totalFrames: 100, maxChunkFrames: 0).isEmpty)
    }
}
