import Foundation

/// 実測ホストタイムのジッタを吸収し、**サンプルクロック由来の連続タイムライン**へ
/// 正規化する(#63)。
///
/// 捕捉コールバックの実測時刻はスケジューリング等でジッタを持ち、そのまま
/// `AecFramer` へ渡すと不連続判定が頻発して持ち越しサンプルが破棄され続ける
/// (実測: 「両方」モードでマイク録音が約 5% 短くなり AEC が全くロックしなかった)。
/// 連続ストリームでは「先頭時刻 + 積算サンプル数 / レート」が正しい時刻であり、
/// 実測時刻は**リベース判定(本物の欠落・デバイス変更の検出)にのみ**使う。
public struct AecTimeline: Sendable {
    public let sampleRate: Double
    /// |実測 − 予測| がこれを超えたら本物の不連続とみなし、実測へ追従する。
    public let rebaseThreshold: TimeInterval

    /// リベース(本物の不連続)の回数(診断用)。
    public private(set) var rebases: Int = 0

    private var baseHostTime: TimeInterval?
    private var accumulatedSamples: Int = 0

    public init(sampleRate: Double = 48000, rebaseThreshold: TimeInterval) {
        precondition(sampleRate > 0 && rebaseThreshold > 0)
        self.sampleRate = sampleRate
        self.rebaseThreshold = rebaseThreshold
    }

    /// `normalize` の結果。正規化時刻に加え、実測と予測の関係(#75 の診断対象)を返す。
    public struct Normalization: Sendable, Equatable {
        /// 正規化後のチャンク開始時刻(rebase 時は実測へ追従した値)。
        public let hostTime: TimeInterval
        /// サンプルクロック由来の予測時刻。初回チャンクは予測を持てないため nil
        /// (0 を入れると「予測と一致した」という誤った意味になる)。
        public let predictedHostTime: TimeInterval?
        /// 実測 − 予測(秒)。初回チャンクは nil。
        public let delta: TimeInterval?
        /// 閾値超の不連続(本物の欠落)として実測へ追従したか。
        public let rebased: Bool

        public init(
            hostTime: TimeInterval,
            predictedHostTime: TimeInterval?,
            delta: TimeInterval?,
            rebased: Bool
        ) {
            self.hostTime = hostTime
            self.predictedHostTime = predictedHostTime
            self.delta = delta
            self.rebased = rebased
        }
    }

    /// チャンクの実測時刻を正規化した開始時刻に写す。呼び出し後、`sampleCount` 分
    /// タイムラインが進む。
    public mutating func normalize(hostTime: TimeInterval, sampleCount: Int) -> Normalization {
        guard let base = baseHostTime else {
            baseHostTime = hostTime
            accumulatedSamples = sampleCount
            return Normalization(
                hostTime: hostTime,
                predictedHostTime: nil,
                delta: nil,
                rebased: false
            )
        }
        let predicted = base + Double(accumulatedSamples) / sampleRate
        let delta = hostTime - predicted
        if abs(delta) > rebaseThreshold {
            rebases += 1
            baseHostTime = hostTime
            accumulatedSamples = sampleCount
            return Normalization(
                hostTime: hostTime,
                predictedHostTime: predicted,
                delta: delta,
                rebased: true
            )
        }
        accumulatedSamples += sampleCount
        return Normalization(
            hostTime: predicted,
            predictedHostTime: predicted,
            delta: delta,
            rebased: false
        )
    }
}
