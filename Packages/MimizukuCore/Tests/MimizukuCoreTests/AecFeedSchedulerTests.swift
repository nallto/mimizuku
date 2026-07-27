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
        // 参照開始後に到着した capture を対象に、通常の frontier 解放を確認する。
        scheduler.advanceRenderFrontier(startingAt: 0, to: duration)
        scheduler.hold(frame(1, at: 0), arrivedAt: 0)
        scheduler.hold(frame(2, at: duration), arrivedAt: 0)
        scheduler.hold(frame(3, at: duration * 2), arrivedAt: 0)
        // render は 2 フレーム目まで給餌済み(フロンティア = 2×duration)。
        let released = scheduler.release(now: 0.01)
        #expect(released.map(\.frame.hostTime) == [0, duration])
        #expect(released.allSatisfy { $0.processing == .aec })
        #expect(scheduler.state == .active)
        #expect(scheduler.heldCount == 1)
        #expect(scheduler.timeoutReleases == 0)
    }

    @Test("参照開始前の capture は原音で残し、後続 capture だけ AEC へ進める")
    func preReferenceCaptureBypassesWarmupWithoutLatching() {
        var scheduler = AecFeedScheduler()
        scheduler.hold(frame(1, at: 0), arrivedAt: 0)
        scheduler.hold(frame(2, at: duration), arrivedAt: 0)

        scheduler.advanceRenderFrontier(startingAt: duration * 2, to: duration * 2)
        let warmup = scheduler.release(now: 0.1)
        #expect(warmup.map(\.frame.samples[0]) == [1, 2])
        #expect(warmup.allSatisfy { $0.processing == .warmupBypass })
        #expect(scheduler.warmupBypassReleases == 2)
        #expect(scheduler.state == .active)

        scheduler.hold(frame(3, at: duration * 2), arrivedAt: 0.11)
        let active = scheduler.release(now: 0.11)
        #expect(active.map(\.frame.samples[0]) == [3])
        #expect(active.allSatisfy { $0.processing == .aec })
        // ウォームアップはセッション中 bypass をラッチしない。
        #expect(scheduler.state == .active)
    }

    @Test("actor 到着順が逆転してもホスト時刻が初回 render より古い capture は APM に入れない")
    func hostTimeDeterminesWarmupWhenArrivalOrderIsReversed() {
        var scheduler = AecFeedScheduler()
        // render タスクが actor を先に取った後、上流に滞留していた古い capture が届く状況。
        scheduler.advanceRenderFrontier(startingAt: 1.0, to: 1.0)
        scheduler.hold(frame(1, at: 0.9), arrivedAt: 1.1)

        let released = scheduler.release(now: 1.1)
        #expect(released.count == 1)
        #expect(released[0].processing == .warmupBypass)
        #expect(scheduler.warmupBypassReleases == 1)
    }

    @Test("render 起動前は猶予内なら解放しない(参照なし給餌を防ぐ)")
    func heldBeforeRenderWithinGrace() {
        var scheduler = AecFeedScheduler(holdTimeout: 0.2, renderStartGrace: 3.0)
        scheduler.hold(frame(1, at: 0), arrivedAt: 0)
        // render 未起動 + 猶予内(< 3.0 秒)→ 保留のまま(タイムアウトも効かない)。
        #expect(scheduler.release(now: 2.9).isEmpty)
        #expect(scheduler.heldCount == 1)
        #expect(scheduler.state == .waitingForReference)
        #expect(scheduler.timeoutReleases == 0)
        #expect(scheduler.renderStalledReleases == 0)
    }

    @Test("render が猶予を過ぎても来なければ bypass へ遷移して保留全件を解放する")
    func renderStalledSafetyValveDrainsHeldFrames() {
        var scheduler = AecFeedScheduler(holdTimeout: 0.2, renderStartGrace: 3.0)
        scheduler.hold(frame(1, at: 0), arrivedAt: 0)
        scheduler.hold(frame(2, at: duration), arrivedAt: 2.9)
        // 最古フレームが猶予超過 → 新しい保留分もまとめて bypass 解放する。
        let released = scheduler.release(now: 3.0)
        #expect(released.map(\.frame.samples[0]) == [1, 2])
        #expect(released.allSatisfy { $0.processing == .bypass })
        #expect(scheduler.heldCount == 0)
        #expect(scheduler.state == .bypass(.referenceStartTimedOut))
        #expect(scheduler.renderStalledReleases == 2)
        // タイムアウト(render 稼働後)とは別カウンタ(取り違え防止)。
        #expect(scheduler.timeoutReleases == 0)
    }

    @Test("bypass 後の capture は猶予を待たず即時解放する")
    func futureCaptureIsReleasedImmediatelyAfterBypass() {
        var scheduler = AecFeedScheduler(renderStartGrace: 3.0)
        scheduler.hold(frame(1, at: 0), arrivedAt: 0)
        _ = scheduler.release(now: 3.0)

        scheduler.hold(frame(2, at: duration), arrivedAt: 3.1)
        let released = scheduler.release(now: 3.1)
        #expect(released.map(\.frame.samples[0]) == [2])
        #expect(released.allSatisfy { $0.processing == .bypass })
    }

    @Test("参照ストリーム失敗時は猶予を待たず bypass へ遷移する")
    func referenceFailureEntersBypassImmediately() {
        var scheduler = AecFeedScheduler(renderStartGrace: 3.0)
        scheduler.hold(frame(1, at: 0), arrivedAt: 0)

        let transitioned = scheduler.markReferenceUnavailable()
        #expect(transitioned)
        let released = scheduler.release(now: 0.1)
        #expect(released.map(\.frame.samples[0]) == [1])
        #expect(released.allSatisfy { $0.processing == .bypass })
        #expect(scheduler.state == .bypass(.referenceUnavailable))
        // 同じ通知で理由や状態を上書きしない。
        let transitionedAgain = scheduler.markReferenceUnavailable()
        #expect(!transitionedAgain)
    }

    @Test("稼働後の参照ストリーム失敗でも即時 bypass へ遷移する")
    func activeReferenceFailureEntersBypassImmediately() {
        var scheduler = AecFeedScheduler()
        scheduler.advanceRenderFrontier(startingAt: 0, to: 0)
        scheduler.hold(frame(1, at: duration * 10), arrivedAt: 10)

        let transitioned = scheduler.markReferenceUnavailable()
        let released = scheduler.release(now: 10)
        #expect(transitioned)
        #expect(scheduler.state == .bypass(.referenceUnavailable))
        #expect(released.map(\.frame.samples[0]) == [1])
        #expect(released.allSatisfy { $0.processing == .bypass })
    }

    @Test("bypass 後に遅れて render が来ても active へ復帰しない")
    func lateRenderDoesNotReactivateBypass() {
        var scheduler = AecFeedScheduler()
        scheduler.markReferenceUnavailable()
        scheduler.advanceRenderFrontier(startingAt: 10, to: 10)
        #expect(scheduler.state == .bypass(.referenceUnavailable))
        #expect(scheduler.renderFrontier == nil)
    }

    @Test("flush(now=無限大)は render 未起動でも残余をすべて解放する(セッション末の欠損防止)")
    func flushReleasesEverythingWithoutRender() {
        var scheduler = AecFeedScheduler(renderStartGrace: 3.0)
        scheduler.hold(frame(1, at: 0), arrivedAt: 0)
        scheduler.hold(frame(2, at: duration), arrivedAt: 0)
        let released = scheduler.release(now: .infinity)
        #expect(released.count == 2)
        #expect(released.allSatisfy { $0.processing == .bypass })
        #expect(scheduler.heldCount == 0)
        #expect(scheduler.state == .bypass(.referenceStartTimedOut))
        #expect(scheduler.renderStalledReleases == 2)
    }

    @Test("render 稼働後に停止したらタイムアウトで解放されカウントされる")
    func timeoutAfterRenderStarted() {
        var scheduler = AecFeedScheduler(holdTimeout: 0.2)
        // render が一度流れて frontier が立つ。
        scheduler.advanceRenderFrontier(startingAt: 0, to: 0)
        scheduler.hold(frame(1, at: duration * 10), arrivedAt: 100.0)
        #expect(scheduler.release(now: 100.1).isEmpty)
        let released = scheduler.release(now: 100.2)
        #expect(released.count == 1)
        #expect(released[0].processing == .aec)
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

    @Test("mic 塊が先着した開始 backlog は APM に入れず、後続から対応 render を給餌する")
    func interactionWithAlignerBypassesPreReferenceBacklog() {
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

        // system tap が 80ms 遅れて render(t=80〜150ms)から開始する。
        for index in 0 ..< 8 {
            let time = Double(index + 8) * duration
            aligner.appendRender(frame(Int16(100 + index), at: time))
        }
        scheduler.advanceRenderFrontier(
            startingAt: 8 * duration,
            to: 15 * duration
        )

        // 参照開始前の capture は録音には残すが、対応参照がないため APM へ入れない。
        let released = scheduler.release(now: 0.09)
        #expect(released.count == 8)
        #expect(released.allSatisfy { $0.processing == .warmupBypass })

        // 参照開始後の最初の capture から AEC を開始し、貯めた render を先に給餌する。
        scheduler.hold(frame(8, at: 16 * duration), arrivedAt: 0.175)
        scheduler.advanceRenderFrontier(
            startingAt: 8 * duration,
            to: 16 * duration
        )
        aligner.appendRender(frame(108, at: 16 * duration))
        let active = scheduler.release(now: 0.096)
        #expect(active.count == 1)
        #expect(active[0].processing == .aec)
        let fedRenderFrames = aligner.appendCapture(active[0].frame).render.count
        #expect(fedRenderFrames == 9)
        #expect(aligner.droppedRenderFrames == 0)
        #expect(aligner.filledSilenceFrames == 0)
    }

    @Test("render 稼働後の一時停止では解放され、aligner は無音充填で通す")
    func timeoutPathAfterRenderFeedsWithoutRender() {
        var scheduler = AecFeedScheduler(holdTimeout: 0.2)
        var aligner = AecAligner()
        // render が一度流れた(scheduler・aligner とも起動済み)。
        aligner.appendRender(frame(100, at: 0))
        scheduler.advanceRenderFrontier(startingAt: 0, to: 0)
        // その後 render が止まり、100ms 先の capture がタイムアウト解放される。
        scheduler.hold(frame(1, at: duration * 10), arrivedAt: 0)
        let released = scheduler.release(now: 0.25)
        #expect(released.count == 1)
        #expect(released[0].processing == .aec)
        // aligner は capture 時刻まで無音充填してから capture を返す。
        let step = aligner.appendCapture(released[0].frame)
        #expect(!step.render.isEmpty)
    }
}
