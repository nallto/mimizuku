import Foundation

/// 入力アクティビティ表示(・・・)用のレベルゲート(#63)。
///
/// バッファごとの RMS レベル(dBFS)を観測し、「一定音量以上の入力を検知しているか」の
/// **状態遷移だけ**を返す(チャタリング防止のハングオーバー付き)。認識器の都合
/// (volatile の遅延)と切り離した即時フィードバックのための純ロジックで、
/// 音声処理経路には関与しない(読み取り観測のみ)。
public struct AudioActivityGate: Sendable {
    /// これ以上でアクティブ。実測の目安: ノイズフロア -45〜-49dBFS、発話 -37dBFS 前後
    /// (#63 の実機計測)。環境により実機で微調整する。
    public let thresholdDBFS: Double
    /// 閾値を下回ってから非アクティブへ落とすまでの猶予(発話間の息継ぎで点滅させない)。
    public let hangover: TimeInterval

    private var isActive = false
    private var lastActiveTime: TimeInterval?

    public init(thresholdDBFS: Double = -42, hangover: TimeInterval = 0.4) {
        precondition(hangover >= 0)
        self.thresholdDBFS = thresholdDBFS
        self.hangover = hangover
    }

    /// レベルを観測する。状態が変化したら新しい状態(true = アクティブ)を返し、
    /// 変化がなければ nil。`time` は単調増加の時刻(秒)。
    public mutating func observe(levelDBFS: Double, at time: TimeInterval) -> Bool? {
        if levelDBFS >= thresholdDBFS {
            lastActiveTime = time
            if !isActive {
                isActive = true
                return true
            }
            return nil
        }
        guard isActive, let last = lastActiveTime, time - last >= hangover else { return nil }
        isActive = false
        return false
    }
}
