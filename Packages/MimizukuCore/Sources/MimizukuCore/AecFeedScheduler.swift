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
/// 追い越した分だけ順に解放する。
///
/// **参照が一度も来ていない間は capture を APM に入れない**(#63 実機で、開始直後に
/// システム tap が起動しきる前の capture を参照なしで供給すると、AEC がその区間を
/// 素通しし、開始時のわずかなアンカー差で毎回効き方が変わる = 3 パターンに分岐した)。
/// タイムアウト解放は **render が一度でも流れ始めた後**(= tap 再構築等での一時停止)
/// にのみ働く。render 起動前は保留し続け、有界化のため上限超過分を古い方から捨てる。
///
/// **ただし render が `renderStartGrace` を過ぎても一度も来ない場合は、保留 capture を
/// 実時間で解放する安全弁を持つ**(#70 / #64)。両方モードでは system tap が +1.2 秒程度で
/// 確実に起動するため通常は発動しないが、隠し参照 tap(マイク単体モード)の TCC 未許可・
/// IOProc 沈黙では render が永遠に来ない。無音充填のまま保留し続けると held 上限まで溜めて
/// 古い方から捨て、マイク発話がほぼ全損する(セッション末に flush されるだけ)ため、
/// 猶予超過後は参照なしで素通し解放して録音・文字起こしを実時間で継続させる
/// (無言欠損より原音を残す)。猶予値は両方モードの tap 起動遅延 + ジッタより十分大きく取り、
/// 正常起動時に誤発動しないようにする。
public struct AecFeedScheduler: Sendable {
    /// render 稼働後に停止したとき、capture の保留を打ち切るまでの実時間(秒)。
    public let holdTimeout: TimeInterval
    /// 1 フレームの長さ(秒)。フロンティア比較の境界に使う。
    public let frameDuration: TimeInterval
    /// capture 保留の上限フレーム数(render 起動前の滞留を有界化)。既定 400 = 4 秒。
    public let maxHeldFrames: Int
    /// render が一度も来ないまま保留 capture がこの実時間(秒)を超えたら、参照なしで
    /// 素通し解放する安全弁。既定 3.0 = 両方モードの tap 起動遅延(+1.2 秒)+ ジッタに
    /// 対して十分な余裕(正常起動では発動しない)。maxHeldFrames の 4 秒より短く取り、
    /// 上限到達で古いフレームを捨てる前に解放されるようにする。
    public let renderStartGrace: TimeInterval

    private struct Held: Sendable {
        var frame: AecFrame
        var arrivedAt: TimeInterval
    }

    private var held: [Held] = []
    /// render 給餌済み範囲の末尾(最後の render フレーム末尾時刻)。未開始は nil。
    public private(set) var renderFrontier: TimeInterval?
    /// render が一度でも流れ始めたか(タイムアウト解放を許すかの判定に使う)。
    private var renderStarted = false

    /// 保留中の capture フレーム数(診断用)。
    public var heldCount: Int { held.count }
    /// タイムアウトで(render 未カバーのまま)解放した数(診断用 ―― render 稼働中に
    /// 増え続けるならアンカー/同期の異常サイン)。
    public private(set) var timeoutReleases: Int = 0
    /// 上限超過で古い方から捨てた capture フレーム数(診断用)。
    public private(set) var droppedHeldFrames: Int = 0
    /// render が一度も来ないまま安全弁で素通し解放した数(診断用 ―― 非ゼロなら
    /// 隠し参照 tap の失敗/沈黙 = AEC が効いていないセッションのサイン。#70 / #64)。
    public private(set) var renderStalledReleases: Int = 0

    public init(
        holdTimeout: TimeInterval = 0.2,
        frameDuration: TimeInterval = 480.0 / 48000.0,
        maxHeldFrames: Int = 400,
        renderStartGrace: TimeInterval = 3.0
    ) {
        precondition(holdTimeout >= 0 && frameDuration > 0 && maxHeldFrames > 0)
        precondition(renderStartGrace > 0)
        self.holdTimeout = holdTimeout
        self.frameDuration = frameDuration
        self.maxHeldFrames = maxHeldFrames
        self.renderStartGrace = renderStartGrace
    }

    /// render フレーム列を aligner へ渡した後に呼ぶ(フロンティアを前進させる)。
    public mutating func advanceRenderFrontier(to lastFrameHostTime: TimeInterval) {
        renderStarted = true
        let end = lastFrameHostTime + frameDuration
        if let frontier = renderFrontier {
            renderFrontier = max(frontier, end)
        } else {
            renderFrontier = end
        }
    }

    /// capture フレームを保留に積む。`now` は到着時のホストクロック時刻。
    /// 上限を超えたら古い方から捨てる(有界化)。
    public mutating func hold(_ frame: AecFrame, arrivedAt now: TimeInterval) {
        held.append(Held(frame: frame, arrivedAt: now))
        if held.count > maxHeldFrames {
            droppedHeldFrames += held.count - maxHeldFrames
            held.removeFirst(held.count - maxHeldFrames)
        }
    }

    /// 現時点で解放できる capture フレームを先頭から順に取り出す。
    /// 解放条件は次のいずれか:
    /// - フレーム末尾が render フロンティア以前(整列済み給餌が可能)。
    /// - **render 稼働後**に保留が `holdTimeout` を超えた(tap 再構築等での一時停止 ――
    ///   その先の無音充填は aligner の責務)。
    /// - **render 未起動のまま**保留が `renderStartGrace` を超えた(隠し参照 tap の
    ///   失敗/沈黙。参照なしで素通し解放し、実時間で欠損を防ぐ。#70 / #64)。
    ///   `now` を `.infinity` にした flush ではこの条件で残余がすべて解放される。
    public mutating func release(now: TimeInterval) -> [AecFrame] {
        var released: [AecFrame] = []
        while let first = held.first {
            let required = first.frame.hostTime + frameDuration
            let coveredByRender = renderFrontier.map { required <= $0 } ?? false
            let waited = now - first.arrivedAt
            let timedOut = renderStarted && waited >= holdTimeout
            let renderStalled = !renderStarted && waited >= renderStartGrace
            guard coveredByRender || timedOut || renderStalled else { break }
            if renderStalled {
                renderStalledReleases += 1
            } else if !coveredByRender {
                timeoutReleases += 1
            }
            released.append(first.frame)
            held.removeFirst()
        }
        return released
    }
}
