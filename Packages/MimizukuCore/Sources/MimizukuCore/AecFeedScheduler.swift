import Foundation

/// AEC ポンプの給餌順を決める純ロジック(#63。AEC-2 の verifier 申し送りへの対応)。
///
/// `AecAligner` は「render / capture をホストタイム昇順で渡す」契約を持つが、実際の
/// 到着は順不同(mic は約 85ms 塊、tap は約 10ms 塊で、どちらが先かは不定)。
/// **到着順**で aligner へ渡すと、capture が先に処理された時点で render 時計が無音充填で
/// 前進し、直後に到着する実 render が stale として系統的に破棄される(far-end が
/// 恒常的に無音化 = AEC 無効化)。
///
/// 本型は capture フレームを **render 到着フロンティアまで保留**し、フロンティアが
/// 追い越した分だけ順に解放する。render が止まった場合(tap 再構築・システム無音経路の
/// 停止)に capture まで滞留させないよう、保留は `holdTimeout` で打ち切って解放する
/// (その先の無音充填は aligner の責務)。
public struct AecFeedScheduler: Sendable {
    /// render が来ないときに capture の保留を打ち切るまでの実時間(秒)。
    public let holdTimeout: TimeInterval
    /// 1 フレームの長さ(秒)。フロンティア比較の境界に使う。
    public let frameDuration: TimeInterval

    private struct Held: Sendable {
        var frame: AecFrame
        var arrivedAt: TimeInterval
    }

    private var held: [Held] = []
    /// render 給餌済み範囲の末尾(最後の render フレーム末尾時刻)。未開始は nil。
    public private(set) var renderFrontier: TimeInterval?

    /// 保留中の capture フレーム数(診断用)。
    public var heldCount: Int { held.count }

    public init(holdTimeout: TimeInterval = 0.2, frameDuration: TimeInterval = 480.0 / 48000.0) {
        precondition(holdTimeout >= 0 && frameDuration > 0)
        self.holdTimeout = holdTimeout
        self.frameDuration = frameDuration
    }

    /// render フレーム列を aligner へ渡した後に呼ぶ(フロンティアを前進させる)。
    public mutating func advanceRenderFrontier(to lastFrameHostTime: TimeInterval) {
        let end = lastFrameHostTime + frameDuration
        if let frontier = renderFrontier {
            renderFrontier = max(frontier, end)
        } else {
            renderFrontier = end
        }
    }

    /// capture フレームを保留に積む。`now` は到着時のホストクロック時刻。
    public mutating func hold(_ frame: AecFrame, arrivedAt now: TimeInterval) {
        held.append(Held(frame: frame, arrivedAt: now))
    }

    /// 現時点で解放できる capture フレームを先頭から順に取り出す。
    /// 解放条件: フレーム末尾が render フロンティア以前(整列済み給餌が可能)、
    /// または保留が `holdTimeout` を超えた(render 停止 ―― 無音充填で進める)。
    public mutating func release(now: TimeInterval) -> [AecFrame] {
        var released: [AecFrame] = []
        while let first = held.first {
            let coveredByRender = renderFrontier.map { first.frame.hostTime + frameDuration <= $0 }
                ?? false
            let timedOut = now - first.arrivedAt >= holdTimeout
            guard coveredByRender || timedOut else { break }
            released.append(first.frame)
            held.removeFirst()
        }
        return released
    }
}
