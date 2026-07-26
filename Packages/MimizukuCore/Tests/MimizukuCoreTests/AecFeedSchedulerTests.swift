import Foundation
import MimizukuCore
import Testing

@Suite("AecFeedScheduler")
struct AecFeedSchedulerTests {
    private let duration = 480.0 / 48000.0 // 10ms

    private func frame(_ value: Int16, at time: TimeInterval) -> AecFrame {
        AecFrame(samples: [Int16](repeating: value, count: 480), hostTime: time)
    }

    @Test("render フロンティア未到達の capture は保留される")
    func captureIsHeldUntilFrontier() {
        var scheduler = AecFeedScheduler()
        scheduler.hold(frame(1, at: 0), arrivedAt: 0)
        #expect(scheduler.release(now: 0.01).isEmpty)
        #expect(scheduler.heldCount == 1)
    }

    @Test("render フロンティアが追い越した分だけ順に解放される")
    func releasedInOrderUpToFrontier() {
        var scheduler = AecFeedScheduler()
        scheduler.hold(frame(1, at: 0), arrivedAt: 0)
        scheduler.hold(frame(2, at: duration), arrivedAt: 0)
        scheduler.hold(frame(3, at: duration * 2), arrivedAt: 0)
        // render は 2 フレーム目まで給餌済み(フロンティア = 2×duration)。
        scheduler.advanceRenderFrontier(to: duration)
        let released = scheduler.release(now: 0.01)
        #expect(released.map(\.hostTime) == [0, duration])
        #expect(scheduler.heldCount == 1)
        #expect(scheduler.timeoutReleases == 0)
    }

    @Test("render 起動前は猶予内なら解放しない(参照なし給餌を防ぐ)")
    func heldBeforeRenderWithinGrace() {
        var scheduler = AecFeedScheduler(holdTimeout: 0.2, renderStartGrace: 3.0)
        scheduler.hold(frame(1, at: 0), arrivedAt: 0)
        // render 未起動 + 猶予内(< 3.0 秒)→ 保留のまま(タイムアウトも効かない)。
        #expect(scheduler.release(now: 2.9).isEmpty)
        #expect(scheduler.heldCount == 1)
        #expect(scheduler.timeoutReleases == 0)
        #expect(scheduler.renderStalledReleases == 0)
    }

    @Test("render が猶予を過ぎても来なければ安全弁で素通し解放される(#70 / #64)")
    func renderStalledSafetyValveReleases() {
        var scheduler = AecFeedScheduler(holdTimeout: 0.2, renderStartGrace: 3.0)
        scheduler.hold(frame(1, at: 0), arrivedAt: 0)
        // render 未起動のまま猶予超過 → 参照なしで解放し、専用カウンタで記録する。
        let released = scheduler.release(now: 3.0)
        #expect(released.count == 1)
        #expect(scheduler.heldCount == 0)
        #expect(scheduler.renderStalledReleases == 1)
        // タイムアウト(render 稼働後)とは別カウンタ(取り違え防止)。
        #expect(scheduler.timeoutReleases == 0)
    }

    @Test("flush(now=無限大)は render 未起動でも残余をすべて解放する(セッション末の欠損防止)")
    func flushReleasesEverythingWithoutRender() {
        var scheduler = AecFeedScheduler(renderStartGrace: 3.0)
        scheduler.hold(frame(1, at: 0), arrivedAt: 0)
        scheduler.hold(frame(2, at: duration), arrivedAt: 0)
        let released = scheduler.release(now: .infinity)
        #expect(released.count == 2)
        #expect(scheduler.heldCount == 0)
        #expect(scheduler.renderStalledReleases == 2)
    }

    @Test("render 稼働後に停止したらタイムアウトで解放されカウントされる")
    func timeoutAfterRenderStarted() {
        var scheduler = AecFeedScheduler(holdTimeout: 0.2)
        // render が一度流れて frontier が立つ。
        scheduler.advanceRenderFrontier(to: 0)
        scheduler.hold(frame(1, at: duration * 10), arrivedAt: 100.0)
        #expect(scheduler.release(now: 100.1).isEmpty)
        let released = scheduler.release(now: 100.2)
        #expect(released.count == 1)
        #expect(scheduler.timeoutReleases == 1)
    }

    @Test("保留上限を超えたら古い方から捨てて有界化する")
    func heldQueueIsBounded() {
        var scheduler = AecFeedScheduler(maxHeldFrames: 3)
        for index in 0 ..< 5 {
            scheduler.hold(frame(Int16(index), at: Double(index) * duration), arrivedAt: 0)
        }
        #expect(scheduler.heldCount == 3)
        #expect(scheduler.droppedHeldFrames == 2)
    }

    @Test("mic 塊が先着しても render 到着後の給餌で実 render が破棄されない(相互作用)")
    func interactionWithAlignerAvoidsStaleDrops() {
        // AEC-2 verifier 申し送りの再現テスト: mic 85ms 塊(capture 8 フレーム)が
        // render より先に到着するシナリオ。スケジューラで保留 → render 到着後に
        // 解放して aligner へ渡せば、実 render は捨てられず無音充填も起きない。
        var scheduler = AecFeedScheduler()
        var aligner = AecAligner()

        // capture 8 フレーム(t=0〜70ms)が先に届く → 全保留。
        for index in 0 ..< 8 {
            scheduler.hold(frame(Int16(index), at: Double(index) * duration), arrivedAt: 0.085)
        }
        #expect(scheduler.release(now: 0.086).isEmpty)

        // render(t=0〜70ms)が届く → aligner へ給餌し、フロンティアを前進。
        for index in 0 ..< 8 {
            aligner.appendRender(frame(Int16(100 + index), at: Double(index) * duration))
        }
        scheduler.advanceRenderFrontier(to: 7 * duration)

        // 解放された capture を順に aligner へ渡す。
        let released = scheduler.release(now: 0.09)
        #expect(released.count == 8)
        var fedRenderFrames = 0
        for capture in released {
            fedRenderFrames += aligner.appendCapture(capture).render.count
        }
        #expect(fedRenderFrames == 8)
        #expect(aligner.droppedRenderFrames == 0)
        #expect(aligner.filledSilenceFrames == 0)
    }

    @Test("render 稼働後の一時停止では解放され、aligner は無音充填で通す")
    func timeoutPathAfterRenderFeedsWithoutRender() {
        var scheduler = AecFeedScheduler(holdTimeout: 0.2)
        var aligner = AecAligner()
        // render が一度流れた(scheduler・aligner とも起動済み)。
        aligner.appendRender(frame(100, at: 0))
        scheduler.advanceRenderFrontier(to: 0)
        // その後 render が止まり、100ms 先の capture がタイムアウト解放される。
        scheduler.hold(frame(1, at: duration * 10), arrivedAt: 0)
        let released = scheduler.release(now: 0.25)
        #expect(released.count == 1)
        // aligner は capture 時刻まで無音充填してから capture を返す。
        let step = aligner.appendCapture(released[0])
        #expect(!step.render.isEmpty)
    }
}
