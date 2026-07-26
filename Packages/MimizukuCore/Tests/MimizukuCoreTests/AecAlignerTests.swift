import Foundation
import MimizukuCore
import Testing

@Suite("AecAligner")
struct AecAlignerTests {
    private let duration = 480.0 / 48000.0 // 10ms

    private func frame(_ value: Int16, at time: TimeInterval) -> AecFrame {
        AecFrame(samples: [Int16](repeating: value, count: 480), hostTime: time)
    }

    @Test("render 未開始の capture は render 無しで通る(tap の開始遅れを再現)")
    func captureBeforeRenderStart() {
        var aligner = AecAligner()
        let step = aligner.appendCapture(frame(1, at: 0))
        #expect(step.render.isEmpty)
        #expect(aligner.filledSilenceFrames == 0)
    }

    @Test("capture 時刻以前の render が時刻順に払い出される(1.2 秒遅れ開始のケース)")
    func rendersFlushedUpToCaptureTime() {
        var aligner = AecAligner()
        // capture は 0 から進み、render は 1.2 秒から始まる(#61 実測の再現)。
        _ = aligner.appendCapture(frame(1, at: 0))
        aligner.appendRender(frame(10, at: 1.2))
        aligner.appendRender(frame(11, at: 1.2 + duration))
        let step = aligner.appendCapture(frame(2, at: 1.2 + duration))
        #expect(step.render.map(\.hostTime) == [1.2, 1.2 + duration])
        #expect(step.capture == frame(2, at: 1.2 + duration))
    }

    @Test("render の欠落は無音で充填され render 時計が連続に保たれる")
    func renderGapIsFilledWithSilence() {
        var aligner = AecAligner()
        aligner.appendRender(frame(10, at: 0))
        // 5 フレーム分(50ms)飛ばして次が来る → 間の 4 フレームを無音充填。
        aligner.appendRender(frame(11, at: duration * 5))
        #expect(aligner.filledSilenceFrames == 4)
        let step = aligner.appendCapture(frame(1, at: duration * 5))
        #expect(step.render.count == 6)
        #expect(step.render[1].samples == [Int16](repeating: 0, count: 480))
    }

    @Test("render が止まったまま capture が進んでも無音充填で追随する(tap 再構築)")
    func renderStallIsFilledByCapture() {
        var aligner = AecAligner()
        aligner.appendRender(frame(10, at: 0))
        let step = aligner.appendCapture(frame(1, at: duration * 5))
        // 0.01〜0.05 の 5 フレームが無音充填され、0.00 の実フレームと合わせて 6。
        #expect(aligner.filledSilenceFrames == 5)
        #expect(step.render.count == 6)
    }

    @Test("充填済み時刻より古い遅延到着 render は捨てる(二重給餌防止)")
    func staleRenderIsDropped() {
        var aligner = AecAligner()
        aligner.appendRender(frame(10, at: 0))
        _ = aligner.appendCapture(frame(1, at: duration * 5))
        aligner.appendRender(frame(11, at: duration * 2))
        #expect(aligner.droppedRenderFrames == 1)
    }

    @Test("滞留上限を超えた render は古い方から破棄されカウントされる")
    func overflowDropsOldest() {
        var aligner = AecAligner(maxQueuedRenderFrames: 3)
        for index in 0 ..< 5 {
            aligner.appendRender(frame(Int16(index), at: Double(index) * duration))
        }
        #expect(aligner.droppedRenderFrames == 2)
        // 最後の render と同時刻の capture(充填なし)。最新の 3 フレームだけが残る。
        let step = aligner.appendCapture(frame(9, at: Double(4) * duration))
        #expect(step.render.map(\.samples[0]) == [2, 3, 4])
    }

    @Test("tap 先行起動: capture より先行しすぎる render は上限を超えた分だけ捨てる(#64)")
    func excessLeadingRenderIsDropped() {
        // maxRenderLead = 50ms(5 フレーム)。tap がマイクより先に起動し render[0..9] が
        // 貯まった直後に最初の capture(最後の render と同時刻 = t=9 フレーム目)が来る状況。
        var aligner = AecAligner(maxRenderLead: duration * 5)
        for index in 0 ..< 10 {
            aligner.appendRender(frame(Int16(index), at: Double(index) * duration))
        }
        let captureTime = Double(9) * duration
        let step = aligner.appendCapture(frame(99, at: captureTime))
        // 先行上限(captureTime - 50ms = t=4)より古い render[0..3] は捨てる。
        #expect(aligner.droppedLeadRenderFrames == 4)
        // APM へ渡る render はすべて capture から maxRenderLead 以内の先行に収まる。
        for render in step.render {
            #expect(captureTime - render.hostTime <= duration * 5 + 1e-9)
        }
        #expect(step.render.map(\.samples[0]) == [4, 5, 6, 7, 8, 9])
    }

    @Test("定常状態(render と capture が同時に流れる)では先行破棄は起きない")
    func noLeadDropInSteadyState() {
        var aligner = AecAligner(maxRenderLead: duration * 5)
        // render[T] と capture[T] が交互に同時刻で流れる。
        for index in 0 ..< 20 {
            aligner.appendRender(frame(Int16(index), at: Double(index) * duration))
            let step = aligner.appendCapture(frame(Int16(index), at: Double(index) * duration))
            #expect(step.render.count == 1)
        }
        #expect(aligner.droppedLeadRenderFrames == 0)
    }
}
