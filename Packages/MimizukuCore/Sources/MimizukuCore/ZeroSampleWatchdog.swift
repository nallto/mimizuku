import Foundation

/// システム音声 tap のゼロサンプル劣化(docs/domain-pitfalls.md #3)を検知する純ロジック。
///
/// IOProc が正常に発火し続けたままサンプルがすべて厳密に 0.0f になる既知の障害モードを、
/// 「連続ゼロ時間が閾値に達したら再構築を要求する」形で表面化させる。
///
/// 正当な無音(何も再生していない)と劣化はソース側から区別できないため:
/// - 発火のたびに閾値を倍化する(初期 5 秒 → 上限 20 秒)。劣化なら 1 回目の再構築で
///   回復し、正当な無音なら再構築の頻度が下がる(無音セッションを殺さない)。
/// - 非ゼロサンプルを観測したら連続時間と閾値を初期値へ戻す(音が鳴っている間の
///   検知は常に初期閾値)。
/// - 上限は「長い無音の間に劣化した場合、会話再開後に失う音声の最大長」でもある。
///   60 秒案は損失が大きすぎ、固定 5 秒案は無音中の HAL 酷使が過剰なため、20 秒を採る。
///
/// 呼び出し側(App の tap ソース)は 1 バッファ毎に `observe` を呼び、`true` が返ったら
/// tap + aggregate device の**両方**を破棄・再作成する(IOProc の再起動だけでは直らない)。
public struct ZeroSampleWatchdog: Sendable, Equatable {
    /// 初回発火までの連続ゼロ秒数。
    public let initialThreshold: TimeInterval
    /// バックオフの上限。
    public let maxThreshold: TimeInterval

    /// 現在の発火閾値(バックオフで変動)。
    public private(set) var currentThreshold: TimeInterval
    /// 現在の連続ゼロ秒数。
    public private(set) var consecutiveZeroSeconds: TimeInterval = 0

    public init(initialThreshold: TimeInterval = 5, maxThreshold: TimeInterval = 20) {
        self.initialThreshold = initialThreshold
        self.maxThreshold = maxThreshold
        currentThreshold = initialThreshold
    }

    /// 1 バッファ分の観測を反映する。
    /// - Parameters:
    ///   - isAllZero: バッファの全サンプルが厳密に 0.0f か。
    ///   - frames: バッファのフレーム数。
    ///   - sampleRate: バッファのサンプルレート(Hz)。0 以下なら観測を無視する。
    /// - Returns: `true` なら再構築を要求(カウンタはリセットし、閾値は倍化される)。
    public mutating func observe(isAllZero: Bool, frames: Int, sampleRate: Double) -> Bool {
        guard sampleRate > 0, frames > 0 else { return false }
        guard isAllZero else {
            consecutiveZeroSeconds = 0
            currentThreshold = initialThreshold
            return false
        }
        consecutiveZeroSeconds += TimeInterval(frames) / sampleRate
        guard consecutiveZeroSeconds >= currentThreshold else { return false }
        consecutiveZeroSeconds = 0
        currentThreshold = min(currentThreshold * 2, maxThreshold)
        return true
    }
}
