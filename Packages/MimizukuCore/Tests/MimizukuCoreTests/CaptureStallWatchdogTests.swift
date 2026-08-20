import Foundation
import Testing

@testable import MimizukuCore

struct CaptureStallWatchdogTests {
    private func makeWatchdog(
        initial: TimeInterval = 2,
        max: TimeInterval = 8,
        attempts: Int = 3
    ) -> CaptureStallWatchdog {
        CaptureStallWatchdog(initialThreshold: initial, maxThreshold: max, maxAttempts: attempts)
    }

    @Test("初回評価は起点を作るだけで発火しない")
    func firstEvaluateEstablishesBaseline() {
        var watchdog = makeWatchdog()
        // 起点が無い状態では、経過時間を測る基準がないため判定しない。
        #expect(watchdog.evaluate(now: 1000, lastArrival: nil) == .wait)
        // 起点は 1000。閾値 2 秒に届くまでは待つ。
        #expect(watchdog.evaluate(now: 1001.9, lastArrival: nil) == .wait)
        #expect(
            watchdog.evaluate(now: 1002, lastArrival: nil) == .rebuild(attempt: 1, idleSeconds: 2)
        )
    }

    @Test("markStarted は起点を進める")
    func markStartedMovesBaseline() {
        var watchdog = makeWatchdog()
        watchdog.markStarted(now: 500)
        #expect(watchdog.evaluate(now: 501.9, lastArrival: nil) == .wait)
        watchdog.markStarted(now: 502)
        // 起点が 502 へ動いたので、503.9 の時点ではまだ 1.9 秒しか経っていない。
        #expect(watchdog.evaluate(now: 503.9, lastArrival: nil) == .wait)
        #expect(
            watchdog.evaluate(now: 504, lastArrival: nil) == .rebuild(attempt: 1, idleSeconds: 2)
        )
    }

    @Test("到着は起点・閾値・試行回数を初期化する")
    func arrivalResetsState() {
        var watchdog = makeWatchdog()
        watchdog.markStarted(now: 0)
        _ = watchdog.evaluate(now: 2, lastArrival: nil)
        _ = watchdog.evaluate(now: 6, lastArrival: nil)
        #expect(watchdog.attempts == 2)
        #expect(watchdog.currentThreshold == 8)

        // 到着を観測 → 起点は到着時刻、閾値と試行回数は初期値へ。
        #expect(watchdog.evaluate(now: 10, lastArrival: 9) == .wait)
        #expect(watchdog.attempts == 0)
        #expect(watchdog.currentThreshold == 2)
        // 起点が 9 なので 10.9 では発火せず、11 で初期閾値どおり発火する。
        #expect(watchdog.evaluate(now: 10.9, lastArrival: 9) == .wait)
        #expect(watchdog.evaluate(now: 11, lastArrival: 9) == .rebuild(attempt: 1, idleSeconds: 2))
    }

    @Test("同じ到着時刻を二重に数えない")
    func sameArrivalIsCountedOnce() {
        var watchdog = makeWatchdog()
        #expect(watchdog.evaluate(now: 100, lastArrival: 100) == .wait)
        // 到着が更新されないまま閾値を超えたら、停止として発火する。
        #expect(watchdog.evaluate(now: 101.9, lastArrival: 100) == .wait)
        #expect(
            watchdog.evaluate(now: 102, lastArrival: 100) == .rebuild(attempt: 1, idleSeconds: 2)
        )
    }

    @Test("発火ごとに閾値を倍化し、起点を発火時点へ進める")
    func backoffDoublesAndRebaselines() {
        var watchdog = makeWatchdog()
        watchdog.markStarted(now: 0)
        #expect(watchdog.evaluate(now: 2, lastArrival: nil) == .rebuild(attempt: 1, idleSeconds: 2))
        #expect(watchdog.currentThreshold == 4)
        // 起点が 2 へ動いたので、次の発火は 6(= 2 + 4)。
        #expect(watchdog.evaluate(now: 5.9, lastArrival: nil) == .wait)
        #expect(watchdog.evaluate(now: 6, lastArrival: nil) == .rebuild(attempt: 2, idleSeconds: 4))
        #expect(watchdog.currentThreshold == 8)
    }

    @Test("バックオフは上限で頭打ちになる")
    func backoffStopsAtMax() {
        var watchdog = makeWatchdog(initial: 2, max: 4, attempts: 10)
        watchdog.markStarted(now: 0)
        _ = watchdog.evaluate(now: 2, lastArrival: nil)
        #expect(watchdog.currentThreshold == 4)
        _ = watchdog.evaluate(now: 6, lastArrival: nil)
        #expect(watchdog.currentThreshold == 4)
        _ = watchdog.evaluate(now: 10, lastArrival: nil)
        #expect(watchdog.currentThreshold == 4)
    }

    @Test("上限回数を超えたら失敗させ、起点は進めない")
    func failsAfterMaxAttempts() {
        var watchdog = makeWatchdog(initial: 2, max: 8, attempts: 2)
        watchdog.markStarted(now: 0)
        #expect(watchdog.evaluate(now: 2, lastArrival: nil) == .rebuild(attempt: 1, idleSeconds: 2))
        #expect(watchdog.evaluate(now: 6, lastArrival: nil) == .rebuild(attempt: 2, idleSeconds: 4))
        // 3 回目の発火は再構築せず失敗(報告する回数は実際に行った再構築の回数)。
        #expect(watchdog.evaluate(now: 14, lastArrival: nil) == .fail(attempts: 2, idleSeconds: 8))
        // 失敗では起点を進めない。起点が 6 のままなら、次の周期の経過時間は 9 秒になる。
        #expect(watchdog.evaluate(now: 15, lastArrival: nil) == .fail(attempts: 2, idleSeconds: 9))
    }

    @Test("失敗後も到着があれば通常状態へ戻る")
    func arrivalAfterFailureResetsState() {
        var watchdog = makeWatchdog(initial: 2, max: 8, attempts: 1)
        watchdog.markStarted(now: 0)
        _ = watchdog.evaluate(now: 2, lastArrival: nil)
        #expect(watchdog.evaluate(now: 6, lastArrival: nil) == .fail(attempts: 1, idleSeconds: 4))
        #expect(watchdog.evaluate(now: 7, lastArrival: 7) == .wait)
        #expect(watchdog.attempts == 0)
        #expect(watchdog.currentThreshold == 2)
    }

    @Test("再構築が進行中の間は試行回数を増やさず、失敗もさせない")
    func inFlightBuildNeverFails() {
        var watchdog = CaptureStallWatchdog(
            initialThreshold: 2,
            maxThreshold: 8,
            maxAttempts: 3,
            blockedNoticeThreshold: 3
        )
        watchdog.markStarted(now: 0)
        // 停止を検知して再構築を要求 → 呼び出し側が build を開始する。
        #expect(watchdog.evaluate(now: 2, lastArrival: nil) == .rebuild(attempt: 1, idleSeconds: 2))
        watchdog.markBuildStarted(now: 2)

        // 通常の閾値(2→4→8秒)を超えても、進行中なら発火も回数の加算もしない。
        #expect(watchdog.evaluate(now: 4.9, lastArrival: nil) == .wait)
        #expect(watchdog.attempts == 1)

        // 通知閾値を超えたら「ブロック中」を報告する。終端ではないので、
        // どれだけ長引いても失敗にはならない(実測で60秒でも0.17秒差で回復した)。
        #expect(watchdog.evaluate(now: 5, lastArrival: nil) == .blocked(blockedSeconds: 3))
        #expect(watchdog.evaluate(now: 62, lastArrival: nil) == .blocked(blockedSeconds: 60))
        #expect(watchdog.evaluate(now: 302, lastArrival: nil) == .blocked(blockedSeconds: 300))
        #expect(watchdog.attempts == 1)
    }

    @Test("再構築が終われば通常の停止検知へ戻り、起点は完了時点になる")
    func finishingBuildResumesNormalDetection() {
        var watchdog = CaptureStallWatchdog(initialThreshold: 2, maxThreshold: 8, maxAttempts: 3)
        watchdog.markStarted(now: 0)
        _ = watchdog.evaluate(now: 2, lastArrival: nil)
        watchdog.markBuildStarted(now: 2)
        // ブロック中は状態通知だけが返り、失敗しない。
        #expect(watchdog.evaluate(now: 20, lastArrival: nil) == .blocked(blockedSeconds: 18))

        // 20.7秒ブロックしたのち build が返った実測ケース。到着が無くても失敗させない。
        watchdog.markBuildFinished(now: 22.7)
        #expect(watchdog.evaluate(now: 24.6, lastArrival: nil) == .wait)
        // 起点は完了時点なので、そこから通常の閾値で測り直す。
        #expect(
            watchdog.evaluate(now: 26.7, lastArrival: nil) == .rebuild(attempt: 2, idleSeconds: 4)
        )
    }

    @Test("進行中に到着があれば回復とみなす")
    func arrivalDuringBuildResetsState() {
        var watchdog = CaptureStallWatchdog(initialThreshold: 2, maxThreshold: 8, maxAttempts: 3)
        watchdog.markStarted(now: 0)
        _ = watchdog.evaluate(now: 2, lastArrival: nil)
        watchdog.markBuildStarted(now: 2)
        // build 完了通知より先にバッファが届くことがある(tap は build 内で張られるため)。
        #expect(watchdog.evaluate(now: 5, lastArrival: 4.8) == .wait)
        #expect(watchdog.attempts == 0)
    }

    @Test("非有限な経過時間は無視する")
    func nonFiniteIdleIsIgnored() {
        var nanWatchdog = makeWatchdog()
        nanWatchdog.markStarted(now: .nan)
        #expect(nanWatchdog.evaluate(now: 100, lastArrival: nil) == .wait)
        #expect(nanWatchdog.attempts == 0)

        var infiniteWatchdog = makeWatchdog()
        infiniteWatchdog.markStarted(now: 0)
        #expect(infiniteWatchdog.evaluate(now: .infinity, lastArrival: nil) == .wait)
        #expect(infiniteWatchdog.attempts == 0)
    }

    /// 既定値はADR-0016が失敗までの遅延(マイク 2+4+8+8=22秒)として明記しているため、
    /// docsだけが黙って乖離しないようここで固定する。
    @Test("既定の閾値・上限・再構築回数を固定する")
    func defaultsMatchDocumentedPolicy() {
        let watchdog = CaptureStallWatchdog()
        #expect(watchdog.initialThreshold == 2)
        #expect(watchdog.maxThreshold == 8)
        #expect(watchdog.maxAttempts == 3)
        #expect(watchdog.blockedNoticeThreshold == 3)
        #expect(watchdog.currentThreshold == 2)
    }

    @Test("時刻が巻き戻っても発火しない")
    func backwardTimeDoesNotFire() {
        var watchdog = makeWatchdog()
        watchdog.markStarted(now: 1000)
        // 単調時計では起きない想定だが、負の経過時間で発火しないことを保証する。
        #expect(watchdog.evaluate(now: 990, lastArrival: nil) == .wait)
        #expect(watchdog.attempts == 0)
    }

    @Test("到着の観測は経過時間の判定より優先する")
    func arrivalWinsOverElapsedIdle() {
        var watchdog = makeWatchdog()
        watchdog.markStarted(now: 0)
        // 起点から 100 秒経っていても、新しい到着があればまず起点を更新する。
        #expect(watchdog.evaluate(now: 100, lastArrival: 99) == .wait)
        #expect(watchdog.attempts == 0)
    }
}
