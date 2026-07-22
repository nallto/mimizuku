import Foundation

/// render(システム音声 = far-end)と capture(マイク = near-end)の 2 ストリームを
/// ホストタイムで整列し、APM への給餌手順を決める純ロジック(ADR-0013 の 4)。
///
/// 契約(呼び出し側 = AEC ポンプ、AEC-3):
/// - render フレームは `appendRender`、capture フレームは `appendCapture` へ
///   ホストタイム昇順で渡す。
/// - `appendCapture` は「先に給餌すべき render フレーム列(時刻順)+ capture
///   フレーム」を返す。APM の呼び出し順序(ProcessReverseStream → ProcessStream)
///   をこの順で厳守する。
///
/// 設計:
/// - **render の欠落は無音で充填する。** tap 再構築中(数十 ms〜)も render 時計を
///   連続に保たないと AEC3 の遅延推定がずれる(エコーは実世界では鳴り続けている)。
///   充填量は `filledSilenceFrames` に積算する。
/// - **render 未開始(tap の捕捉開始はマイクより遅い ―― #61 実測 +1.2 秒)の間**は
///   render を流さない(無音充填もしない)。render 時計は最初の render フレーム
///   から始める。
/// - **滞留上限**: capture が来ないまま render が溜まったら古い方から破棄し、
///   `droppedRenderFrames` に積算する(無言で失わない)。
public struct AecAligner: Sendable {
    /// 1 回の capture 給餌の手順。
    public struct Step: Sendable, Equatable {
        /// capture より先に(この順で)給餌する render フレーム。無音充填を含む。
        public var render: [AecFrame]
        public var capture: AecFrame

        public init(render: [AecFrame], capture: AecFrame) {
            self.render = render
            self.capture = capture
        }
    }

    public let frameLength: Int
    public let sampleRate: Double
    /// render 待ち行列の滞留上限(フレーム数)。既定 300 = 3 秒。
    public let maxQueuedRenderFrames: Int

    /// 滞留上限で破棄した render フレーム数(診断用)。
    public private(set) var droppedRenderFrames: Int = 0
    /// 無音で充填した render フレーム数(診断用)。
    public private(set) var filledSilenceFrames: Int = 0

    private var renderQueue: [AecFrame] = []
    /// 次に来るべき render フレームの時刻(render 未開始なら nil)。
    private var renderExpectedNext: TimeInterval?
    private var frameDuration: TimeInterval { Double(frameLength) / sampleRate }

    public init(
        frameLength: Int = 480,
        sampleRate: Double = 48000,
        maxQueuedRenderFrames: Int = 300
    ) {
        precondition(frameLength > 0 && sampleRate > 0 && maxQueuedRenderFrames > 0)
        self.frameLength = frameLength
        self.sampleRate = sampleRate
        self.maxQueuedRenderFrames = maxQueuedRenderFrames
    }

    public mutating func appendRender(_ frame: AecFrame) {
        if let expected = renderExpectedNext {
            // 充填済み時刻より古い遅延到着は捨てる(無音充填との二重給餌で render
            // 時計が進みすぎるのを防ぐ)。
            if frame.hostTime < expected - frameDuration / 2 {
                droppedRenderFrames += 1
                return
            }
            // 欠落(半フレーム超の飛び)は無音で充填して render 時計を連続に保つ。
            var next = expected
            while frame.hostTime - next > frameDuration / 2 {
                enqueue(AecFrame(samples: silence, hostTime: next))
                filledSilenceFrames += 1
                next += frameDuration
            }
        }
        enqueue(frame)
        renderExpectedNext = frame.hostTime + frameDuration
    }

    public mutating func appendCapture(_ frame: AecFrame) -> Step {
        // render 側が止まっている(tap 再構築等)まま capture が進んだ場合も、
        // capture 時刻まで無音で充填する。render 未開始なら何も流さない。
        if var next = renderExpectedNext {
            while frame.hostTime - next > -frameDuration / 2 {
                enqueue(AecFrame(samples: silence, hostTime: next))
                filledSilenceFrames += 1
                next += frameDuration
            }
            renderExpectedNext = next
        }

        // capture 時刻以前の render をすべて払い出す(APM へ先に給餌する分)。
        let cutoff = frame.hostTime + frameDuration / 2
        var render: [AecFrame] = []
        while let first = renderQueue.first, first.hostTime < cutoff {
            render.append(first)
            renderQueue.removeFirst()
        }
        return Step(render: render, capture: frame)
    }

    private var silence: [Int16] { [Int16](repeating: 0, count: frameLength) }

    private mutating func enqueue(_ frame: AecFrame) {
        renderQueue.append(frame)
        if renderQueue.count > maxQueuedRenderFrames {
            renderQueue.removeFirst(renderQueue.count - maxQueuedRenderFrames)
            droppedRenderFrames += 1
        }
    }
}
