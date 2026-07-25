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

    /// チャンクの実測時刻を正規化した開始時刻に写す。呼び出し後、`sampleCount` 分
    /// タイムラインが進む。
    public mutating func normalize(hostTime: TimeInterval, sampleCount: Int) -> TimeInterval {
        guard let base = baseHostTime else {
            baseHostTime = hostTime
            accumulatedSamples = sampleCount
            return hostTime
        }
        let predicted = base + Double(accumulatedSamples) / sampleRate
        if abs(hostTime - predicted) > rebaseThreshold {
            rebases += 1
            baseHostTime = hostTime
            accumulatedSamples = sampleCount
            return hostTime
        }
        accumulatedSamples += sampleCount
        return predicted
    }
}
