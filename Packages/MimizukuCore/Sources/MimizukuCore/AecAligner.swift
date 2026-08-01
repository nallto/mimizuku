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
/// - **render 先行の上限(`maxRenderLead`)**: capture より `maxRenderLead` 以上古い
///   render は「この capture のエコー源になり得ない」ため APM へ流さず捨てる
///   (`droppedLeadRenderFrames` に積算)。**system tap がマイクより先に起動**した場合
///   (#64 実機。両方モードでも起動順で発生)、マイク到着までに貯まった render を
///   最初の capture で一気に APM へ流すと、AEC3 から見た far-end↔near-end 遅延が
///   探索窓を超え、エコー遅延を推定できず打ち消せない。先行量を窓内に抑えることで
///   **起動順に依存せず**収束させる(既存の「render 未開始まで capture を流さない」
///   ―― capture 先行対策の対称版)。
public struct AecAligner: Sendable {
    /// APM へ給餌する render フレームの出自(#75 の診断対象)。
    public enum RenderProvenance: Sendable, Equatable {
        /// tap から届いた実参照。
        case actual
        /// 欠落を充填した無音(実世界のエコー源とは対応しない)。
        case gapFilled
    }

    /// APM へ給餌する render フレーム + 出自。
    public struct RenderFeed: Sendable, Equatable {
        public var frame: AecFrame
        public var provenance: RenderProvenance

        public init(frame: AecFrame, provenance: RenderProvenance) {
            self.frame = frame
            self.provenance = provenance
        }
    }

    /// 整列中に起きた render の破棄(#75 の診断対象 ―― counter だけでは失われる
    /// 元 hostTime を保持する)。破棄はいずれも production 側の正常動作であり、
    /// 診断試行を invalid にはしない。
    public enum Event: Sendable, Equatable {
        /// 充填済み時刻より古い遅延到着 render を捨てた(二重給餌防止)。
        case lateRenderDropped(hostTime: TimeInterval)
        /// 滞留上限超過で最古の render を捨てた。
        case queueOverflowDropped(firstHostTime: TimeInterval, frameCount: Int)
        /// capture より `maxRenderLead` 以上先行する render を捨てた(#64)。
        case leadRenderDropped(
            firstHostTime: TimeInterval,
            lastHostTime: TimeInterval,
            frameCount: Int
        )
    }

    /// 1 回の capture 給餌の手順。
    public struct Step: Sendable, Equatable {
        /// capture より先に(この順で)給餌する render フレーム。無音充填を含む。
        public var render: [RenderFeed]
        public var capture: AecFrame
        /// この呼び出し中に起きた破棄。
        public var events: [Event]

        public init(render: [RenderFeed], capture: AecFrame, events: [Event] = []) {
            self.render = render
            self.capture = capture
            self.events = events
        }
    }

    public let frameLength: Int
    public let sampleRate: Double
    /// render 待ち行列の滞留上限(フレーム数)。既定 300 = 3 秒。
    public let maxQueuedRenderFrames: Int
    /// render が capture より先行してよい上限(秒)。これを超えて古い render は
    /// APM へ流さず捨てる(AEC3 の遅延探索窓内に far-end 先行を抑える)。既定 0.25 秒 ――
    /// 実エコー遅延(音響 + 出力バッファ、〜200ms 程度)を覆いつつ AEC3 の窓に収まる値。
    public let maxRenderLead: TimeInterval

    /// 滞留上限で破棄した render フレーム数(診断用)。
    public private(set) var droppedRenderFrames: Int = 0
    /// 先行上限(`maxRenderLead`)超過で捨てた render フレーム数(診断用 ―― 非ゼロなら
    /// tap がマイクより先行起動し、先行 render を窓内に抑えたサイン。#64)。
    public private(set) var droppedLeadRenderFrames: Int = 0
    /// 無音で充填した render フレーム数(診断用)。
    public private(set) var filledSilenceFrames: Int = 0

    private var renderQueue: [RenderFeed] = []
    /// 次に来るべき render フレームの時刻(render 未開始なら nil)。
    private var renderExpectedNext: TimeInterval?
    private var frameDuration: TimeInterval { Double(frameLength) / sampleRate }

    public init(
        frameLength: Int = 480,
        sampleRate: Double = 48000,
        maxQueuedRenderFrames: Int = 300,
        maxRenderLead: TimeInterval = 0.25
    ) {
        precondition(frameLength > 0 && sampleRate > 0 && maxQueuedRenderFrames > 0)
        precondition(maxRenderLead > 0)
        self.frameLength = frameLength
        self.sampleRate = sampleRate
        self.maxQueuedRenderFrames = maxQueuedRenderFrames
        self.maxRenderLead = maxRenderLead
    }

    @discardableResult
    public mutating func appendRender(_ frame: AecFrame) -> [Event] {
        var events: [Event] = []
        if let expected = renderExpectedNext {
            // 充填済み時刻より古い遅延到着は捨てる(無音充填との二重給餌で render
            // 時計が進みすぎるのを防ぐ)。
            if frame.hostTime < expected - frameDuration / 2 {
                droppedRenderFrames += 1
                return [.lateRenderDropped(hostTime: frame.hostTime)]
            }
            // 欠落(半フレーム超の飛び)は無音で充填して render 時計を連続に保つ。
            var next = expected
            while frame.hostTime - next > frameDuration / 2 {
                enqueue(RenderFeed(
                    frame: AecFrame(samples: silence, hostTime: next),
                    provenance: .gapFilled
                ), into: &events)
                filledSilenceFrames += 1
                next += frameDuration
            }
        }
        enqueue(RenderFeed(frame: frame, provenance: .actual), into: &events)
        renderExpectedNext = frame.hostTime + frameDuration
        return events
    }

    public mutating func appendCapture(_ frame: AecFrame) -> Step {
        var events: [Event] = []
        // render 側が止まっている(tap 再構築等)まま capture が進んだ場合も、
        // capture 時刻まで無音で充填する。render 未開始なら何も流さない。
        if var next = renderExpectedNext {
            while frame.hostTime - next > -frameDuration / 2 {
                enqueue(RenderFeed(
                    frame: AecFrame(samples: silence, hostTime: next),
                    provenance: .gapFilled
                ), into: &events)
                filledSilenceFrames += 1
                next += frameDuration
            }
            renderExpectedNext = next
        }

        // render 先行の上限: capture より maxRenderLead 以上古い render は、この capture の
        // エコー源(echo 遅延 < maxRenderLead)になり得ないため捨てる。tap がマイクより
        // 先行起動して render が貯まった場合(#64)、貯まった全 render を一気に APM へ流すと
        // far-end↔near-end 遅延が AEC3 の探索窓を超えて打ち消せない。窓内に抑える。
        let leadFloor = frame.hostTime - maxRenderLead
        var droppedLead: [TimeInterval] = []
        while let first = renderQueue.first, first.frame.hostTime < leadFloor {
            droppedLead.append(first.frame.hostTime)
            renderQueue.removeFirst()
            droppedLeadRenderFrames += 1
        }
        if let firstDropped = droppedLead.first, let lastDropped = droppedLead.last {
            events.append(.leadRenderDropped(
                firstHostTime: firstDropped,
                lastHostTime: lastDropped,
                frameCount: droppedLead.count
            ))
        }

        // capture 時刻以前の render をすべて払い出す(APM へ先に給餌する分)。
        let cutoff = frame.hostTime + frameDuration / 2
        var render: [RenderFeed] = []
        while let first = renderQueue.first, first.frame.hostTime < cutoff {
            render.append(first)
            renderQueue.removeFirst()
        }
        return Step(render: render, capture: frame, events: events)
    }

    private var silence: [Int16] { [Int16](repeating: 0, count: frameLength) }

    private mutating func enqueue(_ feed: RenderFeed, into events: inout [Event]) {
        renderQueue.append(feed)
        if renderQueue.count > maxQueuedRenderFrames {
            let overflow = renderQueue.count - maxQueuedRenderFrames
            let dropped = renderQueue.prefix(overflow)
            if let first = dropped.first {
                events.append(.queueOverflowDropped(
                    firstHostTime: first.frame.hostTime,
                    frameCount: overflow
                ))
            }
            renderQueue.removeFirst(overflow)
            droppedRenderFrames += 1
        }
    }
}
