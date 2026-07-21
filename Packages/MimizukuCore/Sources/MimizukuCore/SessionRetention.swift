import Foundation

/// 停止時にセッションを保持するか破棄するかの判定(ADR-0006 の 8)。
///
/// 複数ストリーム(マイク + システム音声)のセッションでは**最長**の録音時間で判定する
/// ―― 片方が無音・未開始でも、もう片方に実用的な長さの録音があれば保持する。
public enum SessionRetention {
    /// 全ストリームの録音時間の最長が `minimumDuration` 未満なら破棄(`true`)。
    /// `durations` が空(1 本も録音されなかった)場合も破棄。
    public static func shouldDiscard(
        durations: [TimeInterval],
        minimumDuration: TimeInterval
    ) -> Bool {
        (durations.max() ?? 0) < minimumDuration
    }
}
