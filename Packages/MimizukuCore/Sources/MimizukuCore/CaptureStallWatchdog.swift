import Foundation

/// 捕捉コールバックが**発火しなくなる**障害モードを検知する純ロジック
/// (docs/domain-pitfalls.md #14、ADR-0016)。
///
/// `ZeroSampleWatchdog` は「コールバックは来続けるのにサンプルが厳密ゼロ」を見る型で、
/// バッファ到着時にしか状態が進まない。したがってコールバック自体が止まる形
/// (録音中の既定入力デバイス切替、スリープ復帰後のエンジン停止、ドライバの死)は
/// 原理的に検知できない。本型は「最後の到着からの経過時間」で判定する時間駆動側を担う。
///
/// 設計:
/// - 判定に必要な時刻はすべて引数で受け取り、内部で時計を読まない。基準時刻の更新まで含めて
///   本型が持つため、呼び出し側(App)には副作用(タイマーと時計読み)だけが残り、CI で
///   決定的にテストできる。
/// - 発火のたびに閾値を倍化する(既定 初期 2 秒 → 上限 8 秒)。再構築が効かない状況で
///   HAL を叩き続けないため。
/// - 再構築の上限回数を持ち、超えたら失敗させる。成否は「build が返ったか」ではなく
///   **バッファが実際に再開したか**で判定する ―― 再構築が成功したように見えて
///   データが来ないケースを取りこぼさないため。
/// - 到着を観測したら基準時刻・閾値・試行回数を初期化する。
///
/// 時刻は任意の原点を持つ単調増加の秒数で渡す。呼び出し側は**スリープ時間を含む**時計を使う
/// ―― スリープ中に停止する時計だと、復帰後に「経過なし」と見えて止まったままのエンジン /
/// IOProc を検知できない。
public struct CaptureStallWatchdog: Sendable, Equatable {
    /// 判定結果。
    public enum Decision: Sendable, Equatable {
        /// まだ何もしない。
        case wait
        /// ソース内部の再構築を要求する(`attempt` は 1 起点の通算試行回数)。
        case rebuild(attempt: Int, idleSeconds: TimeInterval)
        /// 再構築の上限に達した。ストリームを失敗させる。
        case fail(attempts: Int, idleSeconds: TimeInterval)
        /// 再構築がHAL内でブロックしたまま`blockedNoticeThreshold`を超えている。
        /// **終端ではない** ―― 呼び出し側は利用者へ状態を見せるだけで、失敗させない。
        /// ブロックは解ければ回復するため、時間を根拠に失敗させない(ADR-0016 決定10)。
        case blocked(blockedSeconds: TimeInterval)
    }

    /// 初回発火までの無到着秒数。
    public let initialThreshold: TimeInterval
    /// バックオフの上限。
    public let maxThreshold: TimeInterval
    /// 失敗させるまでに許す再構築の回数。
    public let maxAttempts: Int
    /// 再構築が進行中(HAL 呼び出しがブロック中)のとき、状態の通知を始めるまでの時間。
    ///
    /// **ブロックを理由に失敗させない。** 実測のブロック時間は 20.7 / 25.2 / 60.5 / 123 / 129 秒
    /// とばらつき、上限が見えない。閾値を置くと必ず「わずかな差で失敗させる」が起きる ――
    /// build 開始から 20.5 秒 / 60.0 秒の時点で失敗させたが、その 0.2 秒後 / 0.17 秒後に
    /// いずれも build が成功して返った(2026-08-20、#93)。ブロックは解ければ回復するので、時間ではなく**状態を利用者へ
    /// 見せる**方針を採る(ADR-0016 決定10)。この値は「再接続中」を出し始める閾値にすぎない。
    public let blockedNoticeThreshold: TimeInterval

    /// 現在の発火閾値(バックオフで変動)。
    public private(set) var currentThreshold: TimeInterval
    /// これまでに要求した再構築の回数。
    public private(set) var attempts: Int = 0

    /// 経過時間の起点(最後の到着、または直前の再構築 / 開始)。
    private var baseline: TimeInterval?
    /// 既に反映済みの到着時刻(同じ到着を二重に数えないため)。
    private var lastSeenArrival: TimeInterval?

    /// 再構築を開始した時刻。nil なら進行中ではない。
    private var buildStartedAt: TimeInterval?

    public init(
        initialThreshold: TimeInterval = 2,
        maxThreshold: TimeInterval = 8,
        maxAttempts: Int = 3,
        blockedNoticeThreshold: TimeInterval = 3
    ) {
        self.initialThreshold = initialThreshold
        self.maxThreshold = maxThreshold
        self.maxAttempts = maxAttempts
        self.blockedNoticeThreshold = blockedNoticeThreshold
        currentThreshold = initialThreshold
    }

    /// 再構築を開始した。以後は試行回数を増やさず、ブロックが続く間は状態だけを報告する。
    public mutating func markBuildStarted(now: TimeInterval) {
        buildStartedAt = now
    }

    /// 再構築が終わった(成否は問わない)。通常の停止検知へ戻す。
    /// 起点も進める ―― 直後に到着が無くても、build 完了時点から測り直す。
    public mutating func markBuildFinished(now: TimeInterval) {
        buildStartedAt = nil
        baseline = now
    }

    /// 捕捉が(再)開始した。起動直後の無到着を停止と誤検知しないよう起点を進める。
    public mutating func markStarted(now: TimeInterval) {
        baseline = now
    }

    /// 1 周期分の観測を反映する。
    /// - Parameters:
    ///   - now: 現在時刻(単調増加の秒数)。
    ///   - lastArrival: 最後にバッファが届いた時刻。まだ 1 度も届いていなければ nil。
    /// - Returns: 呼び出し側が取るべき行動。
    public mutating func evaluate(now: TimeInterval, lastArrival: TimeInterval?) -> Decision {
        if let lastArrival, lastArrival != lastSeenArrival {
            lastSeenArrival = lastArrival
            baseline = lastArrival
            attempts = 0
            currentThreshold = initialThreshold
            return .wait
        }
        if let buildStartedAt {
            // 再構築が進行中。HAL 呼び出しがブロックしている間は試行回数を増やさず、
            // 失敗もさせない。長引いていることを利用者へ見せるための通知だけを返す。
            let blocked = now - buildStartedAt
            guard blocked.isFinite, blocked >= blockedNoticeThreshold else { return .wait }
            return .blocked(blockedSeconds: blocked)
        }
        guard let baseline else {
            // 初回評価で起点が無ければ、この時点を起点にする(markStarted 相当)。
            self.baseline = now
            return .wait
        }
        let idle = now - baseline
        guard idle.isFinite, idle >= currentThreshold else { return .wait }
        attempts += 1
        currentThreshold = min(currentThreshold * 2, maxThreshold)
        guard attempts <= maxAttempts else {
            return .fail(attempts: maxAttempts, idleSeconds: idle)
        }
        // 次の判定は再構築の時点から測る(再構築直後の連打を防ぐ)。
        self.baseline = now
        return .rebuild(attempt: attempts, idleSeconds: idle)
    }
}
