import Foundation

/// render / capture 両ストリームのドリフト計測を束ね、参照復旧 epoch での
/// 非対称リセットを名前付き操作として固定する純ロジック(#78)。
///
/// `AecDriftEstimator` は積算サンプル数と起点からのホスト経過を比較するため、
/// render(参照)停止中はサンプルが増えず実時間だけが進む。旧 epoch の計測を
/// 復旧後へ持ち越すと、停止時間がそのまま大きな負の PPM として診断ログに混入する。
public struct AecDriftDiagnostics: Sendable {
    public let sampleRate: Double

    private var renderDrift: AecDriftEstimator
    private var captureDrift: AecDriftEstimator

    public init(sampleRate: Double = 48000) {
        self.sampleRate = sampleRate
        renderDrift = AecDriftEstimator(sampleRate: sampleRate)
        captureDrift = AecDriftEstimator(sampleRate: sampleRate)
    }

    public mutating func recordRender(sampleCount: Int, hostTime: TimeInterval) {
        renderDrift.record(sampleCount: sampleCount, hostTime: hostTime)
    }

    public mutating func recordCapture(sampleCount: Int, hostTime: TimeInterval) {
        captureDrift.record(sampleCount: sampleCount, hostTime: hostTime)
    }

    /// render のドリフト率(ppm)。現 epoch の計測が 10 秒未満のうちは nil。
    public var renderPPM: Double? { renderDrift.driftPPM }

    /// capture のドリフト率(ppm)。セッション開始からの連続計測。
    public var capturePPM: Double? { captureDrift.driftPPM }

    /// 参照復旧の epoch 境界で、render 側の計測だけを新規に始める。
    ///
    /// capture は参照停止中も受信・記録が継続する(止まるのは参照だけ)ため、
    /// 対称にリセットすると有効な計測履歴を捨てることになる ―― capture 側は
    /// 維持する。この非対称性を崩さないこと。
    public mutating func resetRenderForRecovery() {
        renderDrift = AecDriftEstimator(sampleRate: sampleRate)
    }
}
