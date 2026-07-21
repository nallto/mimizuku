import Foundation

/// 捕捉する入力ソースの選択(マイクのみ / システム音声のみ / 両方)。
/// UI の Picker とセッション配線(どのストリームを起動するか)をつなぐ純ロジック。
public enum CaptureSelection: String, Sendable, Codable, CaseIterable {
    case microphone
    case systemAudio
    case both

    /// この選択で捕捉するストリーム。順序は `StreamKind` の宣言順で安定
    /// (録音ファイル名・UI 表示・ログの並びを再現可能に保つ)。
    public var streams: [StreamKind] {
        switch self {
        case .microphone: [.microphone]
        case .systemAudio: [.systemAudio]
        case .both: [.microphone, .systemAudio]
        }
    }
}
