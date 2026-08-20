import AVFoundation
import MimizukuCore
import OSLog

/// 捕捉に失敗した理由。回復不能な失敗は `AudioSource.buffers()` から throw する
/// (無言で止めない ―― AudioSource 契約 / docs/domain-pitfalls.md #3)。
enum CaptureError: Error, LocalizedError {
    /// フォーマット変換器を作れない。
    case converterUnavailable(from: AVAudioFormat, to: AVAudioFormat)
    /// 録音用バッファのコピーに失敗した(録音経路はドロップ禁止のため失敗として扱う)。
    case bufferCopyFailed
    /// エコーキャンセル(AEC ポンプ)の処理に失敗した(マイク経路の欠損は許さない)。
    case aecProcessingFailed
    /// AECブリッジを初期化できず、正式なマイク音源を生成できない。
    case aecInitializationFailed
    /// 初回renderが期限内に届かず、AEC処理を開始できない。
    case aecReferenceStartTimedOut
    /// 一時停止したrenderが期限内に戻らず、AEC処理を再開できない。
    case aecReferenceRecoveryTimedOut
    /// 入力デバイスから有効なフォーマットを得られない(構成変更直後に起こりうる)。
    case micInputFormatUnavailable(sampleRate: Double, channelCount: AVAudioChannelCount)
    /// マイク捕捉が停止し、再構築の上限回数でも回復しなかった。
    case micCaptureStalled(attempts: Int, lastError: String?)
    /// 捕捉ソースの配線が欠けている(到達しない想定の防御。無言 skip にしない)。
    case inputUnavailable(StreamKind)
    /// 選択された捕捉ソースが、キャンセル以外で予期せず終了した。
    case sourceEndedUnexpectedly(StreamKind)

    var errorDescription: String? {
        switch self {
        case let .converterUnavailable(from, to):
            "音声(\(from.sampleRate)Hz)から文字起こし用フォーマット(\(to.sampleRate)Hz)への変換器を作成できませんでした。"
        case .bufferCopyFailed:
            "録音バッファの確保に失敗しました。"
        case .aecProcessingFailed:
            "エコーキャンセル処理に失敗しました。"
        case .aecInitializationFailed:
            "エコーキャンセルを初期化できませんでした。"
        case .aecReferenceStartTimedOut:
            "エコーキャンセルの参照音声を期限内に取得できませんでした。"
        case .aecReferenceRecoveryTimedOut:
            "エコーキャンセルの参照音声を復旧できませんでした。"
        case let .micInputFormatUnavailable(sampleRate, channelCount):
            "マイクの入力形式を取得できませんでした(\(Int(sampleRate))Hz \(channelCount)ch)。"
        case let .micCaptureStalled(attempts, lastError):
            if let lastError {
                "マイクの音声が途絶え、\(attempts)回の再接続でも復旧しませんでした(\(lastError))。"
            } else {
                "マイクの音声が途絶え、\(attempts)回の再接続でも復旧しませんでした。"
            }
        case let .inputUnavailable(stream):
            "捕捉ソースの配線に失敗しました(\(stream.rawValue))。"
        case let .sourceEndedUnexpectedly(stream):
            "音声入力が予期せず終了しました(\(stream.rawValue))。"
        }
    }
}

/// マイク捕捉の実行時状態(UI 表示用)。
///
/// 再構築がオーディオ層の中でブロックしている間、UI が「録音中」のままだと利用者は
/// 何も起きていないことに気づけない(docs/domain-pitfalls.md #16)。失敗させない代わりに、
/// この状態を見せて見切りを利用者へ委ねる(ADR-0016 決定10)。
enum MicCaptureStatus: Equatable, Sendable {
    /// 通常。捕捉が流れている。
    case normal
    /// 再接続がオーディオ層でブロックしている。
    case reconnecting(blockedSeconds: TimeInterval)
}

/// 既定入力デバイス(マイク)を `AVAudioEngine` の入力 tap で捕捉し、**native フォーマットの
/// まま** PCM バッファを流す `AudioSource`。
///
/// 設計:
/// - **native で流す。** 録音(CAF 書き込み)は native 品質で行うため(ADR-0006)、
///   文字起こし推奨フォーマットへの変換はソースではなく文字起こし経路
///   (`AudioRouter` / `BufferConverter`)の責務。
/// - **ハードウェア照会は捕捉開始時のみ。** `AVAudioEngine` の生成と
///   `inputNode.outputFormat` の照会は `buffers()` の中でだけ行う。捕捉前の
///   事前照会(init 等)はデバイス状態によってクラッシュ/ブロックするため行わない
///   (`AudioSource` 契約)。フォーマットは各バッファが運ぶ。
/// - **バッファはコピーする。** tap が渡すバッファはエンジンが再利用するため、
///   `BufferConverter`(同一フォーマット)で新規確保のバッファへ写して所有権を
///   切り離してから流す(docs/domain-pitfalls.md #9)。
/// - **cold・単一消費者。** `buffers()` を呼ぶたびに独立したエンジンを起動し、ストリーム
///   終了 / キャンセルで tap とエンジンを確実に解放する(start/stop 反復での状態リーク防止)。
/// - **無言で止めない。** 録音中に既定入力デバイスが切り替わるとエンジンは停止して通知を
///   出すだけで自動再開しない。通知購読による再構築と、通知が出ない形の停止に対する
///   時間駆動 watchdog をソース内部に持ち、回復できなければ throw する
///   (`MicrophoneSession`、docs/domain-pitfalls.md #14)。
/// - **voice processing(VPIO の AEC)は使わない。** VPIO はシステム全体の他アプリ音声を
///   ダッキングし、システム音声 tap の捕捉信号まで減衰させるため両立しない
///   (docs/domain-pitfalls.md #12)。スピーカー回り込みの対策は WebRTC AEC3 を
///   自前の同期層越しに適用する方式で行う(ADR-0013 / ADR-0014)。本ソースは原音を流し、
///   AEC は `AecPump` が担う。
final class MicrophoneSource: AudioSource {
    let kind: StreamKind = .microphone

    private let logger = Logger(subsystem: "dev.nallto.Mimizuku", category: "capture.mic")
    private let onStatus: @Sendable (MicCaptureStatus) -> Void

    init(onStatus: @escaping @Sendable (MicCaptureStatus) -> Void = { _ in }) {
        self.onStatus = onStatus
    }

    func buffers() -> AsyncThrowingStream<AVAudioPCMBuffer, Error> {
        // 再構築中の欠落は実測長の無音で埋め、時間軸を壁時計に保つ(#116、ADR-0017)。
        GapFillingStreamSupport.fillingGaps(timestampedBuffers(), kind: kind, logger: logger)
    }

    /// AEC 経路用: 捕捉時刻付きで流す(消費者は AEC ポンプ ―― AEC-3。ADR-0013 の 4)。
    /// cold・単一消費者などの契約は `buffers()` と同じ。
    func timestampedBuffers() -> AsyncThrowingStream<TimestampedAudioBuffer, Error> {
        let logger = logger
        let onStatus = onStatus
        return AsyncThrowingStream { continuation in
            // エンジンの所有と再構築は MicrophoneSession に閉じる(制御キュー直列化)。
            let session = MicrophoneSession(
                continuation: continuation,
                logger: logger,
                onStatus: onStatus
            )
            session.start()
            continuation.onTermination = { _ in session.stop() }
        }
    }
}
