import Foundation

/// 文字起こしセグメントを「確定済みの追記ログ」と「ストリーム別の現在の volatile 行」に
/// 集約する純粋な状態(UI / フレームワーク非依存・CI 検証可能)。
///
/// SpeechTranscriber は `.volatileResults` で暫定セグメント(`isFinal == false`)を
/// 繰り返し改訂し、最後に確定セグメント(`isFinal == true`)で置き換える
/// (docs/domain-pitfalls.md #6)。本型はその収束を表現する:
/// - volatile は「ストリームごとに 1 行」だけ保持し、新しい volatile が古いものを置換する。
/// - 確定が来たら確定ログに追記し、そのストリームの volatile を消す。
/// - ストリーム(`.microphone` / `.systemAudio`)は互いに独立
///   ―― 一方の確定が他方の volatile を消さない(docs/domain-pitfalls.md #7)。
///
/// 空文字(空白のみ)は行を生まない: 確定が空なら追記せず volatile を消すだけ、
/// volatile が空ならそのストリームの volatile を消す。
public struct TranscriptLog: Sendable, Equatable {
    /// 確定した行(到着順)。永続化・表示の対象。
    public private(set) var finalized: [TranscriptSegment]

    /// ストリームごとの現在の volatile 行(暫定・dimmed 表示用)。
    private var volatileByStream: [StreamKind: TranscriptSegment]

    public init() {
        finalized = []
        volatileByStream = [:]
    }

    /// 表示順が安定した、現在の volatile 行の一覧(`StreamKind` の宣言順)。
    public var volatileLines: [TranscriptSegment] {
        StreamKind.allCases.compactMap { volatileByStream[$0] }
    }

    /// 指定ストリームの現在の volatile 行(無ければ `nil`)。
    public func volatile(for stream: StreamKind) -> TranscriptSegment? {
        volatileByStream[stream]
    }

    /// 1 セグメントを適用する。volatile は置換、確定は追記 + そのストリームの volatile をクリア。
    public mutating func apply(_ segment: TranscriptSegment) {
        let hasText = !segment.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if segment.isFinal {
            if hasText {
                finalized.append(segment)
            }
            volatileByStream[segment.stream] = nil
        } else {
            volatileByStream[segment.stream] = hasText ? segment : nil
        }
    }
}
