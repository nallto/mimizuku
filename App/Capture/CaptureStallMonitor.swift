import Foundation
import MimizukuCore
import os

/// 停止検知が使う単調時計。**スリープ時間を含む**(`ContinuousClock` 基準)―― スリープ中に
/// 停止する時計だと、復帰後に「経過なし」と見えて止まったままのエンジン / IOProc を検知できない
/// (docs/domain-pitfalls.md #14)。原点は任意で、差分だけが意味を持つ。
enum CaptureClock {
    private static let origin = ContinuousClock.now

    static func now() -> TimeInterval {
        let components = origin.duration(to: ContinuousClock.now).components
        return TimeInterval(components.seconds) + TimeInterval(components.attoseconds) * 1e-18
    }
}

/// 捕捉コールバックの到着時刻だけを記録する。捕捉側(tap コールバック / IOProc)は任意スレッド
/// から `note()` を呼び、監視側は評価キューから `latest()` を読む。共有する可変状態がこの 1 値
/// だけに絞られているため、ロック 1 つで完結する(監視オブジェクト自体を捕捉スレッドへ露出しない)。
final class CaptureArrivalRecorder: Sendable {
    private let lastArrival = OSAllocatedUnfairLock<TimeInterval?>(initialState: nil)

    /// バッファを下流へ出せた。
    func note() {
        let now = CaptureClock.now()
        lastArrival.withLock { $0 = now }
    }

    /// 最後の到着時刻(まだ 1 度も届いていなければ nil)。
    func latest() -> TimeInterval? {
        lastArrival.withLock { $0 }
    }
}

/// 捕捉コールバックが**発火しなくなる**形の停止を監視する(docs/domain-pitfalls.md #14)。
///
/// 判定は Core の `CaptureStallWatchdog`(純ロジック・CI テスト対象)が全て行い、本クラスは
/// 「周期的に時計を読んで問い、結果を呼び出し側へ渡す」副作用だけを持つ。利用者は
/// `MicrophoneSession` のみ ―― システム音声 tap は無音時に 2 分以上コールバックを出さないため
/// 「無出力 = 異常」が成立せず、時間駆動の停止検知を持たない(ADR-0016 決定7、pitfalls #15)。
///
/// `@unchecked Sendable` の正当化(ハード制約 #4、PR にも明記): DispatchQueue の @Sendable
/// クロージャへ self を渡すために Sendable 宣言が必要だが、本クラスの可変状態はすべて評価キュー
/// 専有であり、捕捉スレッドと共有するのはロックで保護された `CaptureArrivalRecorder`(本クラスの
/// プロパティではなく、呼び出し側が所有する Sendable な値)だけである。コンパイラが検証できない
/// だけでデータ競合は構造的に排除されている。
final class CaptureStallMonitor: @unchecked Sendable {
    private let arrivals: CaptureArrivalRecorder
    private let queue: DispatchQueue
    private let interval: TimeInterval
    private let onRebuild: (String, Int) -> Void
    private let onFail: (Int) -> Void
    private let onBlocked: (TimeInterval) -> Void

    // MARK: queue でのみ触る状態

    private var watchdog: CaptureStallWatchdog
    private var timer: DispatchSourceTimer?

    /// - Parameters:
    ///   - queue: 評価とコールバックを行うキュー(呼び出し側の制御キュー)。
    ///   - arrivals: 捕捉コールバックが到着を記録する先(呼び出し側が所有する)。
    ///   - watchdog: 閾値・バックオフ・上限回数の方針。
    ///   - interval: 評価周期。
    ///   - onRebuild: 再構築の要求(理由・通算試行回数)。`queue` 上で呼ばれる。
    ///   - onFail: 上限に達した(実際に行った再構築回数)。`queue` 上で呼ばれる。
    ///   - onBlocked: 再構築がブロック中(ブロック秒数)。終端ではなく、周期的に呼ばれる。
    init(
        queue: DispatchQueue,
        arrivals: CaptureArrivalRecorder,
        watchdog: CaptureStallWatchdog,
        interval: TimeInterval = 0.5,
        onRebuild: @escaping (String, Int) -> Void,
        onFail: @escaping (Int) -> Void,
        onBlocked: @escaping (TimeInterval) -> Void
    ) {
        self.queue = queue
        self.arrivals = arrivals
        self.watchdog = watchdog
        self.interval = interval
        self.onRebuild = onRebuild
        self.onFail = onFail
        self.onBlocked = onBlocked
    }

    /// 監視を開始する(`queue` 上で呼ぶ)。
    func start() {
        guard timer == nil else { return }
        watchdog.markStarted(now: CaptureClock.now())
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + interval, repeating: interval)
        timer.setEventHandler { [weak self] in self?.evaluate() }
        self.timer = timer
        timer.resume()
    }

    /// 捕捉が(再)開始した。起動直後の無到着を停止と誤検知しないよう起点を進める
    /// (`queue` 上で呼ぶ)。
    func markStarted() {
        watchdog.markStarted(now: CaptureClock.now())
    }

    /// 再構築を開始した。以後は build 専用の期限で判定する(`queue` 上で呼ぶ)。
    func markBuildStarted() {
        watchdog.markBuildStarted(now: CaptureClock.now())
    }

    /// 再構築が終わった(成否は問わない)。通常の停止検知へ戻す(`queue` 上で呼ぶ)。
    func markBuildFinished() {
        watchdog.markBuildFinished(now: CaptureClock.now())
    }

    /// 監視を止める(`queue` 上で呼ぶ)。
    func cancel() {
        timer?.cancel()
        timer = nil
    }

    private func evaluate() {
        switch watchdog.evaluate(now: CaptureClock.now(), lastArrival: arrivals.latest()) {
        case .wait:
            break
        case let .rebuild(attempt, idleSeconds):
            let seconds = String(format: "%.1f", idleSeconds)
            onRebuild("stalled for \(seconds)s (attempt \(attempt))", attempt)
        case let .fail(attempts, _):
            cancel()
            onFail(attempts)
        case let .blocked(blockedSeconds):
            // 終端ではない。監視は続けたまま、長引いていることを呼び出し側へ知らせる。
            onBlocked(blockedSeconds)
        }
    }
}
