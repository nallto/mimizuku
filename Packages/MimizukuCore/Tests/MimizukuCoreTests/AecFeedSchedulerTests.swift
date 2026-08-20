import Foundation
import MimizukuCore
import Testing

@Suite("AecFeedScheduler")
struct AecFeedSchedulerTests {
    private let duration = 480.0 / 48000.0

    private func frame(_ value: Int16, at time: TimeInterval) -> AecFrame {
        AecFrame(samples: [Int16](repeating: value, count: 480), hostTime: time)
    }

    @Test("初回render前のcaptureは原音を出さず即時破棄する")
    func captureBeforeReferenceIsDiscarded() {
        var scheduler = AecFeedScheduler()
        scheduler.begin(at: 0)
        scheduler.hold(frame(1, at: 0), arrivedAt: 0)

        let released = scheduler.release(now: 0.01)
        #expect(released.count == 1)
        #expect(released[0].processing == .silence)
        #expect(scheduler.heldCount == 0)
        #expect(scheduler.state == .waitingForReference)
        #expect(scheduler.discardedFrames == 1)
    }

    @Test("renderフロンティアが覆ったcaptureだけAECへ解放する")
    func releasedInOrderUpToFrontier() {
        var scheduler = AecFeedScheduler()
        scheduler.begin(at: 0)
        #expect(
            scheduler.advanceRenderFrontier(startingAt: 0, to: duration) == .activated
        )
        scheduler.hold(frame(1, at: 0), arrivedAt: 0)
        scheduler.hold(frame(2, at: duration), arrivedAt: 0)
        scheduler.hold(frame(3, at: duration * 2), arrivedAt: 0)

        let released = scheduler.release(now: 0.01)
        #expect(released.map(\.frame.hostTime) == [0, duration])
        #expect(released.allSatisfy { $0.processing == .aec })
        #expect(scheduler.state == .active)
        #expect(scheduler.heldCount == 1)
    }

    @Test("renderのactor到着後でもepochより古いcaptureは破棄する")
    func hostTimeDeterminesPreReferenceCapture() {
        var scheduler = AecFeedScheduler()
        scheduler.begin(at: 0)
        scheduler.advanceRenderFrontier(startingAt: 1.0, to: 1.0)
        scheduler.hold(frame(1, at: 0.9), arrivedAt: 1.1)

        let released = scheduler.release(now: 1.1)
        #expect(released.count == 1)
        #expect(released[0].processing == .silence)
        #expect(scheduler.state == .active)
    }

    @Test("初回render未着は5秒の境界で開始失敗する")
    func referenceStartDeadline() {
        var scheduler = AecFeedScheduler(referenceStartTimeout: 5.0)
        scheduler.begin(at: 10)

        #expect(scheduler.checkDeadline(now: 14.999) == .none)
        #expect(scheduler.state == .waitingForReference)
        #expect(
            scheduler.checkDeadline(now: 15.0) == .failed(.referenceStartTimedOut)
        )
        #expect(scheduler.state == .failed(.referenceStartTimedOut))
    }

    @Test("watchdog失敗後のcaptureも原音を出さず破棄する")
    func captureAfterStartFailureIsDiscarded() {
        var scheduler = AecFeedScheduler(referenceStartTimeout: 5.0)
        scheduler.begin(at: 0)
        _ = scheduler.checkDeadline(now: 5)
        scheduler.hold(frame(1, at: 5), arrivedAt: 5)

        let released = scheduler.release(now: 5)
        #expect(released.count == 1)
        #expect(released[0].processing == .silence)
    }

    @Test("active中にrender対応が途切れたらrecoveringへ移りcaptureを破棄する")
    func renderStallEntersRecovery() {
        var scheduler = AecFeedScheduler(holdTimeout: 0.2)
        scheduler.begin(at: 0)
        scheduler.advanceRenderFrontier(startingAt: 0, to: 0)
        scheduler.hold(frame(1, at: duration * 10), arrivedAt: 100)

        #expect(scheduler.release(now: 100.199).isEmpty)
        let released = scheduler.release(now: 100.2)
        #expect(released.count == 1)
        #expect(released[0].processing == .silence)
        #expect(scheduler.state == .recovering)
        #expect(scheduler.recoveryCount == 1)
    }

    @Test("参照ストリーム中断でもactiveからrecoveringへ移る")
    func referenceInterruptionEntersRecovery() {
        var scheduler = AecFeedScheduler()
        scheduler.begin(at: 0)
        scheduler.advanceRenderFrontier(startingAt: 0, to: 0)

        #expect(scheduler.markReferenceInterrupted(at: 1) == .recovering)
        #expect(scheduler.state == .recovering)
        #expect(scheduler.markReferenceInterrupted(at: 2) == .none)
    }

    @Test("開始待ち中の参照ストリーム失敗は期限まで再試行できる")
    func startupInterruptionDoesNotFailImmediately() {
        var scheduler = AecFeedScheduler(referenceStartTimeout: 5)
        scheduler.begin(at: 0)

        #expect(scheduler.markReferenceInterrupted(at: 1) == .none)
        #expect(scheduler.state == .waitingForReference)
        #expect(scheduler.checkDeadline(now: 4.9) == .none)
    }

    @Test("recovering中にrenderが戻れば新しいepochでactiveへ復帰する")
    func recoveredReferenceStartsNewEpoch() {
        var scheduler = AecFeedScheduler()
        scheduler.begin(at: 0)
        scheduler.advanceRenderFrontier(startingAt: 0, to: 0)
        _ = scheduler.markReferenceInterrupted(at: 1)

        #expect(
            scheduler.advanceRenderFrontier(startingAt: 2, to: 2) == .recovered
        )
        #expect(scheduler.state == .active)
        #expect(scheduler.renderEpochStartTime == 2)

        scheduler.hold(frame(1, at: 1.9), arrivedAt: 2.1)
        scheduler.hold(frame(2, at: 2.0), arrivedAt: 2.1)
        let released = scheduler.release(now: 2.1)
        #expect(released.map(\.processing) == [.silence, .aec])
    }

    @Test("復旧待ちは5秒の境界で失敗する")
    func recoveryDeadline() {
        var scheduler = AecFeedScheduler(referenceRecoveryTimeout: 5)
        scheduler.begin(at: 0)
        scheduler.advanceRenderFrontier(startingAt: 0, to: 0)
        _ = scheduler.markReferenceInterrupted(at: 10)

        #expect(scheduler.checkDeadline(now: 14.999) == .none)
        #expect(
            scheduler.checkDeadline(now: 15) == .failed(.referenceRecoveryTimedOut)
        )
        #expect(scheduler.state == .failed(.referenceRecoveryTimedOut))
    }

    @Test("failed後の遅いrenderでは復帰しない")
    func lateRenderDoesNotRecoverFailedSession() {
        var scheduler = AecFeedScheduler(referenceStartTimeout: 5)
        scheduler.begin(at: 0)
        _ = scheduler.checkDeadline(now: 5)

        #expect(scheduler.advanceRenderFrontier(startingAt: 6, to: 6) == .none)
        #expect(scheduler.state == .failed(.referenceStartTimedOut))
        #expect(scheduler.renderFrontier == nil)
    }

    @Test("終了drainは状態遷移や失敗通知を起こさず残余を破棄する")
    func shutdownDrainIsStateNeutral() {
        var scheduler = AecFeedScheduler()
        scheduler.begin(at: 0)
        scheduler.hold(frame(1, at: 0), arrivedAt: 0)
        scheduler.hold(frame(2, at: duration), arrivedAt: 0)

        let released = scheduler.drainForShutdown()
        #expect(released.count == 2)
        #expect(released.allSatisfy { $0.processing == .silence })
        #expect(scheduler.state == .waitingForReference)
        #expect(scheduler.heldCount == 0)
    }

    @Test("保留上限超過分は原音を出さず破棄して有界化し、元 hostTime を報告する")
    func heldQueueIsBounded() {
        var scheduler = AecFeedScheduler(maxHeldFrames: 3)
        scheduler.begin(at: 0)
        scheduler.advanceRenderFrontier(startingAt: 0, to: 0)
        var drops: [AecFeedScheduler.HeldOverflowDrop] = []
        for index in 0 ..< 5 {
            if let drop = scheduler.hold(
                frame(Int16(index), at: Double(index + 10) * duration),
                arrivedAt: 0
            ) {
                drops.append(drop)
            }
        }
        #expect(scheduler.heldCount == 3)
        #expect(scheduler.droppedHeldFrames == 2)
        #expect(scheduler.discardedFrames == 2)
        // 破棄された frame(0) / frame(1) の元 hostTime がイベントに残る(#75)。
        #expect(drops == [
            AecFeedScheduler.HeldOverflowDrop(
                firstHostTime: Double(10) * duration,
                lastHostTime: Double(10) * duration,
                frameCount: 1
            ),
            AecFeedScheduler.HeldOverflowDrop(
                firstHostTime: Double(11) * duration,
                lastHostTime: Double(11) * duration,
                frameCount: 1
            )
        ])
    }

    @Test("保留上限内では hold は破棄を報告しない")
    func holdWithinLimitReportsNoDrop() {
        var scheduler = AecFeedScheduler(maxHeldFrames: 3)
        scheduler.begin(at: 0)
        for index in 0 ..< 3 {
            #expect(scheduler.hold(
                frame(Int16(index), at: Double(index) * duration),
                arrivedAt: 0
            ) == nil)
        }
    }

    /// 既定値はADR-0016 決定11が明記しているため、docsだけが黙って乖離しないよう固定する。
    /// 既存の期限テストは明示値を渡しているので、既定値の変更はここでしか捕まらない。
    @Test("参照期限の既定値を固定する")
    func defaultReferenceTimeoutsMatchDocumentedPolicy() {
        let scheduler = AecFeedScheduler()
        #expect(scheduler.referenceStartTimeout == 15)
        #expect(scheduler.referenceRecoveryTimeout == 15)
    }
}
