import Foundation

/// ストリームのサンプルクロックとホストクロックの乖離(ドリフト)を計測する
/// 純ロジック(ADR-0013 の 4)。
///
/// マイクと出力デバイスは別クロックでありうる(AEC3 に明示的なドリフト補償は
/// 無い ―― ADR-0013 のリスク)。本型は「積算サンプル数から期待されるホスト経過」と
/// 「実際のホスト経過」の差を追い、補正量(N サンプルに 1 サンプルの挿入/間引き)を
/// 算出する。**補正の適用は呼び出し側(AEC-3 のポンプ)の責務**で、本スライスでは
/// 計測と算出まで。
public struct AecDriftEstimator: Sendable {
    public let sampleRate: Double

    private var originHostTime: TimeInterval?
    private var accumulatedSamples: Int = 0
    /// 直近の乖離(秒)。正 = サンプルが余っている(サンプルクロックが速い)。
    public private(set) var driftSeconds: TimeInterval = 0
    /// 計測に使ったホスト経過(秒)。
    public private(set) var elapsedHostTime: TimeInterval = 0

    public init(sampleRate: Double = 48000) {
        precondition(sampleRate > 0)
        self.sampleRate = sampleRate
    }

    /// チャンク到着を記録する。`hostTime` はチャンク**先頭**サンプルの捕捉時刻。
    public mutating func record(sampleCount: Int, hostTime: TimeInterval) {
        guard sampleCount > 0 else { return }
        guard let origin = originHostTime else {
            originHostTime = hostTime
            accumulatedSamples = sampleCount
            return
        }
        // このチャンクの先頭時点で、既受領サンプル数ぶんの時間が経過しているはず。
        elapsedHostTime = hostTime - origin
        driftSeconds = Double(accumulatedSamples) / sampleRate - elapsedHostTime
        accumulatedSamples += sampleCount
    }

    /// ドリフト率(ppm)。計測が短すぎる(10 秒未満)うちは信頼できないので nil。
    public var driftPPM: Double? {
        guard elapsedHostTime >= 10 else { return nil }
        return driftSeconds / elapsedHostTime * 1_000_000
    }

    /// 補正量: 正 = N サンプルごとに 1 サンプル**間引く**、負 = N サンプルごとに
    /// 1 サンプル**挿入する**。補正不要(±2ppm 未満)なら nil。
    public var correctionInterval: Int? {
        guard let ppm = driftPPM, abs(ppm) >= 2 else { return nil }
        let interval = Int((1_000_000 / abs(ppm)).rounded())
        return ppm > 0 ? interval : -interval
    }
}
