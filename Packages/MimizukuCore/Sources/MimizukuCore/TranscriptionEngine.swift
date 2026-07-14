import Foundation

/// 文字起こしの暫定 / 確定の 1 片。1 つのストリームに帰属する。
///
/// 話者帰属モデル(既知の制約): SpeechTranscriber に diarization は無い。
/// 「誰が話したか」は音声がどのストリーム由来かだけで決まる ――
/// `microphone` = ローカルユーザー、`systemAudio` = リモート参加者(混在)。
public struct TranscriptSegment: Sendable, Codable, Identifiable, Equatable {
    public var id: UUID
    public var stream: StreamKind
    public var text: String
    /// 認識器がこのセグメントをまだ改訂しうる間は `false`
    /// (volatile result、`.volatileResults` レポートオプション)。
    public var isFinal: Bool
    /// セッション開始からの秒数。
    public var start: TimeInterval?
    public var end: TimeInterval?

    public init(
        id: UUID = UUID(),
        stream: StreamKind,
        text: String,
        isFinal: Bool,
        start: TimeInterval? = nil,
        end: TimeInterval? = nil
    ) {
        self.id = id
        self.stream = stream
        self.text = text
        self.isFinal = isFinal
        self.start = start
        self.end = end
    }
}

/// オンデバイス文字起こし層の契約。
///
/// 本番実装は SpeechAnalyzer + SpeechTranscriber(Speech framework、macOS 26+)を
/// ラップする。テストで fake engine を使えるよう、またエンジンを差し替え可能に
/// するため、このプロトコルは Speech 型を含めない。
public protocol TranscriptionEngine: Sendable {
    /// `locale` 用のオンデバイスモデルアセットが導入済みであることを保証する。
    /// 本番実装: `SpeechTranscriber.installedLocales` を確認し、無ければ
    /// `AssetInventory.assetInstallationRequest(supporting:)` + `downloadAndInstall()`。
    /// アセットは数百 MB。初回利用でブロックしないよう、アプリ起動時に
    /// バックグラウンドで呼ぶ(docs/domain-pitfalls.md #5)。
    func prepare(locale: Locale) async throws

    /// 1 つの音声ソースを文字起こしする。1 ソースにつき 1 エンジンセッション。
    /// アプリはマイクとシステム音声の 2 セッションを並行実行する。
    /// volatile セグメント(`isFinal == false`)に続いてその確定版を流す。
    /// 消費側は確定セグメントのみ永続化する。
    func segments(from source: any AudioSource) -> AsyncThrowingStream<TranscriptSegment, Error>
}
