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
/// 初回 render より古い capture は、後から render が届いても APM へ遡及投入せず
/// `warmupBypass` として原音を残す。対応する render がない開始時 backlog を APM へ入れると、
/// 両方モードのように tap 起動が遅い場合に AEC3 の初期収束を崩すため。
/// タイムアウト解放は **render が一度でも流れ始めた後**(= tap 再構築等での一時停止)
/// にのみ働く。render 起動前は保留し続け、有界化のため上限超過分を古い方から捨てる。
///
/// **ただし render が `renderStartGrace` を過ぎても一度も来ない場合は bypass へ遷移し、
/// 保留 capture と以後の capture を即時解放する安全弁を持つ**(#70 / #74)。両方モードでは
/// system tap が +1.2 秒程度で起動するため通常は発動しないが、隠し参照 tap(マイク単体
/// モード)の TCC 未許可・IOProc 沈黙では render が永遠に来ない。各フレームを個別に
/// `renderStartGrace` だけ待たせると、欠損は避けられてもセッション全体が恒久的に遅延する。
/// そのため最古フレームの猶予超過をセッション単位の状態遷移としてラッチし、遅れて render が
/// 来ても途中復帰させない(AEC の急な有効化による音質変化より安定した原音継続を優先)。
public struct AecFeedScheduler: Sendable {
    /// 参照音声の稼働状態。bypass はセッション中ラッチし、自動復帰しない。
    public enum State: Sendable, Equatable {
        case waitingForReference
        case active
        case bypass(BypassReason)
    }

    /// AEC を使わずマイク原音を通す理由。
    public enum BypassReason: Sendable, Equatable {
        /// 初回 render が猶予時間内に届かなかった。
        case referenceStartTimedOut
        /// 参照ストリームが失敗、または capture 継続中に終了した。
        case referenceUnavailable
    }

    /// 解放した capture の処理方法。bypass は APM へ渡してはいけない。
    public enum Processing: Sendable, Equatable {
        case aec
        /// 参照開始前に捕捉したため、APM へ入れず原音を残す。一時的で、後続は AEC へ進む。
        case warmupBypass
        /// 参照が利用できないため、セッション中継続して原音を残す。
        case bypass
    }

    /// 解放対象の capture と、その後の処理方法。
    public struct Release: Sendable, Equatable {
        public let frame: AecFrame
        public let processing: Processing

        public init(frame: AecFrame, processing: Processing) {
            self.frame = frame
            self.processing = processing
        }
    }

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
    /// 初回 render フレームのホスト時刻。actor への到着順ではなく捕捉時刻で
    /// ウォームアップ範囲を判定する。
    public private(set) var renderStartTime: TimeInterval?
    /// render 給餌済み範囲の末尾(最後の render フレーム末尾時刻)。未開始は nil。
    public private(set) var renderFrontier: TimeInterval?
    /// 参照音声の稼働状態。
    public private(set) var state: State = .waitingForReference

    /// 保留中の capture フレーム数(診断用)。
    public var heldCount: Int { held.count }
    /// タイムアウトで(render 未カバーのまま)解放した数(診断用 ―― render 稼働中に
    /// 増え続けるならアンカー/同期の異常サイン)。
    public private(set) var timeoutReleases: Int = 0
    /// 上限超過で古い方から捨てた capture フレーム数(診断用)。
    public private(set) var droppedHeldFrames: Int = 0
    /// bypass で素通し解放した数(診断用 ―― 非ゼロなら参照 tap の失敗/沈黙により
    /// AEC が効いていないセッションのサイン。#70 / #74)。
    public private(set) var renderStalledReleases: Int = 0
    /// 初回 render より前に到着し、AEC の初期収束を守るため原音で解放した数。
    public private(set) var warmupBypassReleases: Int = 0

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
    public mutating func advanceRenderFrontier(
        startingAt firstFrameHostTime: TimeInterval,
        to lastFrameHostTime: TimeInterval
    ) {
        // bypass はセッション中ラッチする。遅れて届いた参照で途中復帰しない。
        if case .bypass = state { return }
        state = .active
        if renderStartTime == nil {
            renderStartTime = firstFrameHostTime
        }
        let end = lastFrameHostTime + frameDuration
        if let frontier = renderFrontier {
            renderFrontier = max(frontier, end)
        } else {
            renderFrontier = end
        }
    }

    /// 参照ストリームの失敗・終了を通知し、bypass をラッチする。
    /// - Returns: この呼び出しで新たに bypass へ遷移した場合は `true`。
    @discardableResult
    public mutating func markReferenceUnavailable() -> Bool {
        enterBypass(reason: .referenceUnavailable)
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
    /// - 初回 render より前に到着した capture。原音を残すが APM へは入れない。
    /// - フレーム末尾が render フロンティア以前(整列済み給餌が可能)。
    /// - **render 稼働後**に保留が `holdTimeout` を超えた(tap 再構築等での一時停止 ――
    ///   その先の無音充填は aligner の責務)。
    /// - **render 未起動のまま**最古の保留が `renderStartGrace` を超えた(参照 tap の
    ///   失敗/沈黙)。この時点で bypass をラッチし、保留全件と後続を即時解放する。
    ///   `now` を `.infinity` にした flush でも同様に残余をすべて解放する。
    public mutating func release(now: TimeInterval) -> [Release] {
        if shouldEnterBypass(now: now) {
            enterBypass(reason: .referenceStartTimedOut)
        }

        var released: [Release] = []
        while let first = held.first {
            let required = first.frame.hostTime + frameDuration
            let coveredByRender = renderFrontier.map { required <= $0 } ?? false
            let waited = now - first.arrivedAt
            let timedOut = state == .active && waited >= holdTimeout
            let processing: Processing
            if case .bypass = state {
                processing = .bypass
                renderStalledReleases += 1
            } else if isBeforeInitialRender(first.frame), state == .active {
                processing = .warmupBypass
                warmupBypassReleases += 1
            } else if coveredByRender || timedOut {
                processing = .aec
            } else {
                break
            }
            if processing == .aec, !coveredByRender {
                timeoutReleases += 1
            }
            released.append(Release(frame: first.frame, processing: processing))
            held.removeFirst()
        }
        return released
    }

    @discardableResult
    private mutating func enterBypass(reason: BypassReason) -> Bool {
        if case .bypass = state { return false }
        state = .bypass(reason)
        return true
    }

    private func shouldEnterBypass(now: TimeInterval) -> Bool {
        guard case .waitingForReference = state, let first = held.first else { return false }
        return now - first.arrivedAt >= renderStartGrace
    }

    private func isBeforeInitialRender(_ frame: AecFrame) -> Bool {
        guard let renderStartTime else { return false }
        return frame.hostTime < renderStartTime
    }
}
