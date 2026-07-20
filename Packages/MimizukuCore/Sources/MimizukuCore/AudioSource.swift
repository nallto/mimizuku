import AVFoundation

/// 会話のどちら側を捕捉するストリームかを表す。
public enum StreamKind: String, Sendable, Codable, CaseIterable {
    /// ローカルユーザーの声。既定の入力デバイスから AVAudioEngine で取得する。
    case microphone
    /// リモート参加者 / システム出力。Core Audio process tap
    /// (CATapDescription + AudioHardwareCreateProcessTap、macOS 14.2+)で取得する。
    case systemAudio
}

/// 捕捉層と文字起こし層をつなぐ契約(ADR-0003)。
///
/// 設計ルール:
/// - ストリームは cold。最初のイテレーションで捕捉開始、キャンセルで停止する。
/// - 1 ストリームにつき消費者は 1 つ。ファンアウト(文字起こし + ファイル録音)は
///   本プロトコルの実装ではなく `AudioRouter`(App ターゲット)の責務。
/// - `AVAudioPCMBuffer` は `Sendable` ではない。アクター境界を跨ぐ前にコピーするか
///   所有権を移譲(`sending`)すること。Swift 6 strict concurrency では実装時に
///   明示的に解決する。ADR への記載なしに `@unchecked` で握りつぶさない
///   (docs/domain-pitfalls.md #9)。
/// - 実装はデバイスの **native フォーマットのまま**バッファを流す(録音は native 品質で
///   行うため。ADR-0006)。文字起こし器の推奨フォーマット
///   (`SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith:)`)への変換は、
///   文字起こし経路(App の `AudioRouter` / `BufferConverter`)の責務。
/// - フォーマットは各バッファ(`AVAudioPCMBuffer.format`)が運ぶ。ソースに事前照会用の
///   プロパティは置かない ―― 捕捉開始前のハードウェア照会(`inputNode.outputFormat` 等)は
///   デバイス状態によってクラッシュ/ブロックしうるため、消費側は最初のバッファから
///   フォーマットを確定させる(録音ファイルの遅延オープン等)。
public protocol AudioSource: Sendable {
    var kind: StreamKind { get }

    /// cold・単一消費者の PCM バッファストリーム。
    ///
    /// 実装は以下を守る:
    /// - 回復不能な捕捉失敗時は(無言で止めず)throw する。
    /// - macOS 26 既知の process-tap 障害モード(IOProc は発火し続けるのに
    ///   サンプルが厳密に 0.0f になる)を検知し、error として表面化させ、
    ///   ルーターが tap + aggregate device の完全再構築を起動できるようにする
    ///   (docs/domain-pitfalls.md #3)。
    func buffers() -> AsyncThrowingStream<AVAudioPCMBuffer, Error>
}
