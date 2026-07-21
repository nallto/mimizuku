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
    ///   サンプルが厳密に 0.0f になる)は、**ソース内部で** tap + aggregate device の
    ///   両方を破棄・再作成して回復し、ストリームは切らない(録音・セッションを
    ///   継続させる)。回復不能(API 失敗の連続)な場合のみ throw する
    ///   (docs/domain-pitfalls.md #3)。
    /// - ストリーム生涯でフォーマットを固定する。内部再構築でデバイス由来の
    ///   フォーマットが変わったら、初回の基準フォーマットへ変換して流す
    ///   (下流の録音ファイル・変換器を不変に保つ)。
    func buffers() -> AsyncThrowingStream<AVAudioPCMBuffer, Error>
}
