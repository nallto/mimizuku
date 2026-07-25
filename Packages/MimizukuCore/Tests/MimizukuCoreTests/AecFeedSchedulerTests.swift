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
    }

    @Test("render が止まっても holdTimeout で解放される")
    func timeoutReleasesWhenRenderStalls() {
        var scheduler = AecFeedScheduler(holdTimeout: 0.2)
        scheduler.hold(frame(1, at: 0), arrivedAt: 100.0)
        #expect(scheduler.release(now: 100.1).isEmpty)
        let released = scheduler.release(now: 100.2)
        #expect(released.count == 1)
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

    @Test("render 未開始でもタイムアウト後は解放され、aligner は render 無しで通す")
    func timeoutPathFeedsWithoutRender() {
        var scheduler = AecFeedScheduler(holdTimeout: 0.2)
        var aligner = AecAligner()
        scheduler.hold(frame(1, at: 0), arrivedAt: 0)
        let released = scheduler.release(now: 0.25)
        #expect(released.count == 1)
        let step = aligner.appendCapture(released[0])
        #expect(step.render.isEmpty)
    }
}
