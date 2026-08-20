import Foundation

/// 捕捉ストリームの**時間軸の欠落**を検知し、埋めるべき無音の長さを実測で算出する
/// 純ロジック(#116、ADR-0017)。
///
/// 捕捉の再構築中(デバイス切替、`docs/domain-pitfalls.md` #14 / #16 / #17)や、
/// システム音声 tap がコールバックを出さない区間(#15)はバッファが 1 つも届かず、
/// その時間が録音・文字起こしから消える。欠落長はデバイスと HAL の状態で大きく変わる
/// (実測 0.4 秒〜129 秒)ため、**固定値では埋められない** ―― ホストタイムの連続性から
/// その回の欠落長を毎回測る(#116 の前提)。
///
/// 設計は `AecTimeline` と同型: 「先頭時刻 + 積算フレーム数 / レート」の予測タイムラインを
/// 正典とし、実測ホストタイムは欠落判定にのみ使う。ジッタ(閾値以下のずれ)では発火せず、
/// 予測にも影響させない。閾値超の遅れを本物の欠落とみなし、その差分をフレーム数へ換算して
/// 返す。呼び出し側はそのフレーム数の無音を下流へ差し込み、時間軸だけを維持する。
///
/// - 時刻は単調なホストクロック(秒)で渡す。判定に必要な時刻はすべて引数で受け取り、
///   内部で時計を読まない(ADR-0016 決定2 と同じ分割方針)。
/// - 実測が予測より**早い**方向の閾値超(通常は起きない)は、無音を挿入せずに実測へ
///   追従する(時間を削る操作はしない。回数は `backwardRebases` に残す)。
public struct CaptureGapFiller: Sendable, Equatable {
    /// 検知した欠落。`frames` 分の無音を、次のバッファより**前**に差し込む。
    public struct Gap: Sendable, Equatable {
        /// 欠落の実測長(秒)。
        public let seconds: TimeInterval
        /// 欠落をフレーム数へ換算した値(四捨五入)。常に正。
        public let frames: Int

        public init(seconds: TimeInterval, frames: Int) {
            self.seconds = seconds
            self.frames = frames
        }
    }

    public let sampleRate: Double
    /// 実測 − 予測がこれを超えたら本物の欠落とみなす。**検知の閾値であり、埋める長さの
    /// 定数ではない**(埋める長さは毎回の実測差分)。`AecTimeline` の capture 側閾値と
    /// 同値に揃える前提の設計だが、値は呼び出し側が与える。
    public let fillThreshold: TimeInterval

    /// これまでに埋めると判定したフレーム総数(診断用)。
    public private(set) var filledFrames: Int = 0
    /// 欠落を検知した回数(診断用)。
    public private(set) var fillCount: Int = 0
    /// 実測が予測より早い方向へ閾値超で跳んだ回数(診断用。無音は挿入しない)。
    public private(set) var backwardRebases: Int = 0

    /// 予測タイムラインの起点。
    private var baseHostTime: TimeInterval?
    /// 起点からの積算フレーム数。
    private var accumulatedFrames: Int = 0

    public init(sampleRate: Double, fillThreshold: TimeInterval) {
        precondition(sampleRate > 0 && fillThreshold > 0)
        self.sampleRate = sampleRate
        self.fillThreshold = fillThreshold
    }

    /// バッファの到着を 1 件反映する。欠落を検知したら、埋めるべき無音の長さを返す。
    /// - Parameters:
    ///   - hostTime: バッファ先頭の実測ホストタイム(秒)。
    ///   - frameCount: バッファのフレーム数。
    /// - Returns: このバッファの**前**に差し込むべき無音。欠落が無ければ nil。
    public mutating func observe(hostTime: TimeInterval, frameCount: Int) -> Gap? {
        guard frameCount > 0 else { return nil }
        guard hostTime.isFinite else {
            // 時刻が壊れているバッファでは判定しない。フレームだけ進め、次の正常な
            // 時刻で判定を再開する(壊れた時刻を起点にしない)。
            accumulatedFrames += frameCount
            return nil
        }
        guard let base = baseHostTime else {
            baseHostTime = hostTime
            accumulatedFrames = frameCount
            return nil
        }
        let predicted = base + Double(accumulatedFrames) / sampleRate
        let delta = hostTime - predicted
        if delta > fillThreshold {
            // 本物の欠落。差分をフレーム数へ換算し、起点は実測へ追従する(丸め誤差を
            // 次回以降へ累積させない)。
            let frames = Int((delta * sampleRate).rounded())
            baseHostTime = hostTime
            accumulatedFrames = frameCount
            filledFrames += frames
            fillCount += 1
            return Gap(seconds: delta, frames: frames)
        }
        if delta < -fillThreshold {
            // 時間を巻き戻す欠落は存在しない。無音を挿入せず実測へ追従だけする。
            backwardRebases += 1
            baseHostTime = hostTime
            accumulatedFrames = frameCount
            return nil
        }
        accumulatedFrames += frameCount
        return nil
    }

    /// 長い欠落を分割生成するためのチャンク長列。巨大な単一バッファの確保を避ける
    /// (実測では分単位の欠落がある)。
    /// - Returns: 各チャンクのフレーム数(合計 = `totalFrames`)。
    public static func chunkLengths(totalFrames: Int, maxChunkFrames: Int) -> [Int] {
        guard totalFrames > 0, maxChunkFrames > 0 else { return [] }
        var lengths: [Int] = []
        var remaining = totalFrames
        while remaining > 0 {
            let length = Swift.min(remaining, maxChunkFrames)
            lengths.append(length)
            remaining -= length
        }
        return lengths
    }
}
