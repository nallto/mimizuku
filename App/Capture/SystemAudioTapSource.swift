import AVFoundation
import CoreAudio
import Foundation
import MimizukuCore
import OSLog

/// システム音声 tap の失敗理由。
enum SystemAudioTapError: Error, LocalizedError {
    case coreAudio(operation: String, status: OSStatus)
    case tapFormatUnavailable
    case defaultOutputDeviceUnavailable
    case rebuildFailed(lastError: String)

    var errorDescription: String? {
        switch self {
        case let .coreAudio(operation, status):
            "システム音声の捕捉に失敗しました(\(operation): \(status))。"
        case .tapFormatUnavailable:
            "システム音声 tap のフォーマットを取得できませんでした。"
        case .defaultOutputDeviceUnavailable:
            "既定の出力デバイスが見つかりませんでした。"
        case let .rebuildFailed(lastError):
            "システム音声捕捉の再構築に失敗しました: \(lastError)"
        }
    }
}

/// システム音声(全プロセスのミックス)を Core Audio process tap で捕捉し、
/// **native フォーマットのまま** PCM バッファを流す `AudioSource`。
///
/// 構成(docs/domain-pitfalls.md #1〜#3 を厳守):
/// - `CATapDescription(stereoGlobalTapButExcludeProcesses: [])` → 以後 `isExclusive` に
///   触らない(#1: 意味反転の罠)。
/// - tap をサブ tap とする private aggregate device を既定出力デバイスに紐付け、
///   `AudioDeviceCreateIOProcIDWithBlock` で直接消費する(#2: AVAudioEngine の
///   向け直しは無言で失敗する)。
/// - ゼロサンプル watchdog(`ZeroSampleWatchdog`、バックオフ付き)の発火と既定出力
///   デバイスの変更で、tap + aggregate の**両方**を破棄・再作成する(#3)。再構築は
///   ソース内部で完結し、ストリームは切らない(録音・セッションを継続させる)。
///   CoreAudio API の失敗が連続した場合のみ throw する(正当な無音では殺さない)。
/// - **時間駆動の停止検知は持たない。** 無音時は IOProc が 2 分以上発火しないことがあり
///   (実測、docs/domain-pitfalls.md #15)、「無出力 = 異常」と扱えない。マイクと違い、
///   録音開始から実際に音が鳴るまでの時間は予測できないため、無出力を根拠に失敗させない。
///   IOProc が戻らない形の停止は現状どの watchdog も拾えない(#92 で方針を決める)。
/// - フォーマットはストリーム生涯で固定: 初回 tap フォーマットを基準とし、再構築後に
///   デバイス由来でフォーマットが変わったら内部で基準へ変換して流す(下流の録音
///   ファイル・変換器を不変に保つ)。
/// - cold・単一消費者。ストリーム終了 / キャンセルで tap・aggregate・リスナーを
///   確実に解放する。
final class SystemAudioTapSource: AudioSource {
    let kind: StreamKind = .systemAudio

    private let logger = Logger(subsystem: "dev.nallto.Mimizuku", category: "capture.tap")

    func buffers() -> AsyncThrowingStream<AVAudioPCMBuffer, Error> {
        // 再構築や無音時の無出力(#15)による欠落は実測長の無音で埋め、時間軸を
        // 壁時計に保つ(#116、ADR-0017)。
        GapFillingStreamSupport.fillingGaps(timestampedBuffers(), kind: kind, logger: logger)
    }

    /// AEC 経路用: 捕捉時刻付きで流す(消費者は AEC ポンプ ―― AEC-3。ADR-0013 の 4)。
    /// cold・単一消費者などの契約は `buffers()` と同じ。
    func timestampedBuffers() -> AsyncThrowingStream<TimestampedAudioBuffer, Error> {
        let logger = logger
        return AsyncThrowingStream { continuation in
            // TapSession はキュー直列化を根拠に @unchecked Sendable(宣言部の正当化
            // コメント参照)。ここでは生成して開始し、終了時に stop するだけ。
            let session = TapSession(continuation: continuation, logger: logger)
            session.start()
            continuation.onTermination = { _ in session.stop() }
        }
    }
}
