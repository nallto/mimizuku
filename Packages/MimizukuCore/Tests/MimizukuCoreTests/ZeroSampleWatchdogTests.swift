import Foundation
import Testing

@testable import MimizukuCore

struct ZeroSampleWatchdogTests {
    /// 4800 frames @ 48kHz = 0.1 秒のバッファを想定。
    private let frames = 4800
    private let sampleRate = 48000.0

    /// n バッファ分のゼロ観測を与え、発火した回数を返す。
    private func feedZeros(
        _ watchdog: inout ZeroSampleWatchdog,
        seconds: TimeInterval
    ) -> Int {
        // 浮動小数点誤差でバッファ数が欠けないよう丸める(5.1 * 48000 = 244799.99…)。
        let buffers = Int((seconds * sampleRate / Double(frames)).rounded())
        var fired = 0
        for _ in 0 ..< buffers {
            let didFire = watchdog.observe(isAllZero: true, frames: frames, sampleRate: sampleRate)
            fired += didFire ? 1 : 0
        }
        return fired
    }

    @Test func firesAfterInitialThresholdOfContinuousZeros() {
        var watchdog = ZeroSampleWatchdog(initialThreshold: 5, maxThreshold: 60)
        #expect(feedZeros(&watchdog, seconds: 4.9) == 0)
        #expect(feedZeros(&watchdog, seconds: 0.2) == 1)
    }

    @Test func nonZeroResetsCounterAndThreshold() {
        var watchdog = ZeroSampleWatchdog(initialThreshold: 5, maxThreshold: 60)
        _ = feedZeros(&watchdog, seconds: 4.9)
        // 非ゼロで連続時間がリセットされる。
        _ = watchdog.observe(isAllZero: false, frames: frames, sampleRate: sampleRate)
        #expect(watchdog.consecutiveZeroSeconds == 0)
        #expect(feedZeros(&watchdog, seconds: 4.9) == 0)
    }

    @Test func backoffDoublesThresholdUpToMax() {
        var watchdog = ZeroSampleWatchdog(initialThreshold: 5, maxThreshold: 15)
        // 1 回目: 5 秒で発火 → 閾値 10 秒。
        #expect(feedZeros(&watchdog, seconds: 5.1) == 1)
        #expect(watchdog.currentThreshold == 10)
        // 2 回目: さらに 10 秒で発火 → 閾値は上限 15 秒で頭打ち。
        #expect(feedZeros(&watchdog, seconds: 10.1) == 1)
        #expect(watchdog.currentThreshold == 15)
        #expect(feedZeros(&watchdog, seconds: 15.1) == 1)
        #expect(watchdog.currentThreshold == 15)
    }

    @Test func nonZeroAfterBackoffRestoresInitialThreshold() {
        var watchdog = ZeroSampleWatchdog(initialThreshold: 5, maxThreshold: 60)
        _ = feedZeros(&watchdog, seconds: 5.1)
        #expect(watchdog.currentThreshold == 10)
        // 音が戻ったらバックオフも初期化(次の劣化には再び 5 秒で反応)。
        _ = watchdog.observe(isAllZero: false, frames: frames, sampleRate: sampleRate)
        #expect(watchdog.currentThreshold == 5)
    }

    @Test func invalidObservationsAreIgnored() {
        var watchdog = ZeroSampleWatchdog(initialThreshold: 5, maxThreshold: 60)
        let firedOnZeroFrames = watchdog.observe(isAllZero: true, frames: 0, sampleRate: sampleRate)
        let firedOnZeroRate = watchdog.observe(isAllZero: true, frames: frames, sampleRate: 0)
        #expect(!firedOnZeroFrames)
        #expect(!firedOnZeroRate)
        #expect(watchdog.consecutiveZeroSeconds == 0)
    }
}
