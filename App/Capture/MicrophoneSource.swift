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

    var errorDescription: String? {
        switch self {
        case let .converterUnavailable(from, to):
            "音声(\(from.sampleRate)Hz)から文字起こし用フォーマット(\(to.sampleRate)Hz)への変換器を作成できませんでした。"
        case .bufferCopyFailed:
            "録音バッファの確保に失敗しました。"
        }
    }
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
/// - **voice processing(AEC)は使わない。** スピーカー再生中はマイクが再生音を拾い
///   「自分」として二重に文字起こしされるが、VPIO の AEC はシステム全体の他アプリ音声
///   ダッキングを伴い、システム音声 tap の捕捉信号まで減衰させるため採用できない
///   (docs/domain-pitfalls.md #12)。スピーカー運用時のエコーはヘッドホン利用で回避する。
final class MicrophoneSource: AudioSource {
    let kind: StreamKind = .microphone

    private let logger = Logger(subsystem: "dev.nallto.Mimizuku", category: "capture.mic")

    func buffers() -> AsyncThrowingStream<AVAudioPCMBuffer, Error> {
        let logger = logger
        return AsyncThrowingStream { continuation in
            // AVAudioEngine とそのノードは Sendable ではない。本エンジンはこの 1 ストリーム
            // だけが所有し、tap コールバック・start・teardown 以外から触れない(単一所有)。
            // onTermination は @Sendable なので、単一所有を明示して nonisolated(unsafe) とする
            // (docs/domain-pitfalls.md #9。型ごと覆う @unchecked Sendable は使わない)。
            nonisolated(unsafe) let engine = AVAudioEngine()
            let input = engine.inputNode
            let inputFormat = input.outputFormat(forBus: 0)

            // 同一フォーマットの「変換」= 所有権を切り離したコピー。
            guard let copier = BufferConverter(from: inputFormat, to: inputFormat) else {
                continuation.finish(throwing: CaptureError.converterUnavailable(
                    from: inputFormat,
                    to: inputFormat
                ))
                return
            }

            input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { buffer, _ in
                guard let copy = copier.convertedCopy(of: buffer) else { return }
                continuation.yield(copy)
            }

            do {
                engine.prepare()
                try engine.start()
                let hz = Int(inputFormat.sampleRate)
                let ch = Int(inputFormat.channelCount)
                logger
                    .notice(
                        "mic capture started: \(hz, privacy: .public)Hz \(ch, privacy: .public)ch"
                    )
            } catch {
                input.removeTap(onBus: 0)
                continuation.finish(throwing: error)
                return
            }

            continuation.onTermination = { _ in
                // ストリーム終了 / キャンセルで tap とエンジンを解放する(状態リーク防止)。
                engine.stop()
                engine.inputNode.removeTap(onBus: 0)
                logger.notice("microphone capture stopped")
            }
        }
    }
}
