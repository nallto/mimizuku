import AVFoundation
import MimizukuCore
import OSLog

/// 捕捉に失敗した理由。回復不能な失敗は `AudioSource.buffers()` から throw する
/// (無言で止めない ―― AudioSource 契約 / docs/domain-pitfalls.md #3)。
enum CaptureError: Error, LocalizedError {
    /// 入力フォーマットから文字起こし器の推奨フォーマットへの変換器を作れない。
    case converterUnavailable(from: AVAudioFormat, to: AVAudioFormat)

    var errorDescription: String? {
        switch self {
        case let .converterUnavailable(from, to):
            "マイク入力(\(from.sampleRate)Hz)から文字起こし用フォーマット(\(to.sampleRate)Hz)への変換器を作成できませんでした。"
        }
    }
}

/// 既定入力デバイス(マイク)を `AVAudioEngine` の入力 tap で捕捉し、文字起こし器の
/// 推奨フォーマット(`targetFormat`)へ変換した PCM バッファを流す `AudioSource`。
///
/// 設計:
/// - **フォーマットは注入する。** Speech 依存を持ち込まないため、App の配線側が
///   `SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith:)` から得た値を渡す。
///   これで下流での再サンプリングを防ぐ(`AudioSource.format` 契約)。
/// - **バッファはコピーする。** tap が渡すバッファはエンジンが再利用するため、変換時に
///   新規 `AVAudioPCMBuffer` へ書き出して所有権を切り離す。これは正しさとして必須で、
///   同時に Swift 6 の Sendable 境界も解消する(docs/domain-pitfalls.md #9 を「コピー」で
///   解決、`@unchecked Sendable` を使わない)。
/// - **cold・単一消費者。** `buffers()` を呼ぶたびに独立したエンジンを起動し、ストリーム
///   終了 / キャンセルで tap とエンジンを確実に解放する(start/stop 反復での状態リーク防止)。
final class MicrophoneSource: AudioSource {
    let kind: StreamKind = .microphone
    let format: AVAudioFormat

    private let logger = Logger(subsystem: "dev.nallto.Mimizuku", category: "capture.mic")

    /// - Parameter targetFormat: 文字起こし器の推奨フォーマット。流すバッファはこれに揃う。
    init(targetFormat: AVAudioFormat) {
        format = targetFormat
    }

    func buffers() -> AsyncThrowingStream<AVAudioPCMBuffer, Error> {
        let targetFormat = format
        let logger = logger
        return AsyncThrowingStream { continuation in
            // AVAudioEngine とそのノードは Sendable ではない。本エンジンはこの 1 ストリーム
            // だけが所有し、tap コールバック・start・teardown 以外から触れない(単一所有)。
            // onTermination は @Sendable なので、単一所有を明示して nonisolated(unsafe) とする
            // (docs/domain-pitfalls.md #9。型ごと覆う @unchecked Sendable は使わない)。
            nonisolated(unsafe) let engine = AVAudioEngine()
            let input = engine.inputNode
            let inputFormat = input.outputFormat(forBus: 0)

            guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
                continuation.finish(throwing: CaptureError.converterUnavailable(
                    from: inputFormat,
                    to: targetFormat
                ))
                return
            }

            input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { buffer, _ in
                guard let converted = Self.convertedCopy(
                    of: buffer,
                    using: converter,
                    to: targetFormat
                ) else {
                    return
                }
                continuation.yield(converted)
            }

            do {
                engine.prepare()
                try engine.start()
                let inHz = Int(inputFormat.sampleRate)
                let outHz = Int(targetFormat.sampleRate)
                let msg = "mic capture started: \(inHz)→\(outHz)Hz"
                logger.info("\(msg, privacy: .public)")
            } catch {
                input.removeTap(onBus: 0)
                continuation.finish(throwing: error)
                return
            }

            continuation.onTermination = { _ in
                // ストリーム終了 / キャンセルで tap とエンジンを解放する(状態リーク防止)。
                engine.stop()
                engine.inputNode.removeTap(onBus: 0)
                logger.info("microphone capture stopped")
            }
        }
    }

    /// 入力バッファを `targetFormat` へ変換し、**新規に確保したバッファ**へ書き出して返す。
    /// 返り値は tap のバッファと記憶域を共有しない(所有権を切り離したコピー)。
    private static func convertedCopy(
        of input: AVAudioPCMBuffer,
        using converter: AVAudioConverter,
        to targetFormat: AVAudioFormat
    ) -> sending AVAudioPCMBuffer? {
        let ratio = targetFormat.sampleRate / input.format.sampleRate
        let capacity = AVAudioFrameCount((Double(input.frameLength) * ratio).rounded(.up)) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else {
            return nil
        }

        // convert(to:error:withInputFrom:) の入力ブロックは @Sendable。convert は同期的に
        // このブロックを呼び切るため、非 Sendable な入力バッファを渡しても安全
        // (docs/domain-pitfalls.md #9)。
        nonisolated(unsafe) let inputBuffer = input
        var suppliedInput = false
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
            if suppliedInput {
                inputStatus.pointee = .noDataNow
                return nil
            }
            suppliedInput = true
            inputStatus.pointee = .haveData
            return inputBuffer
        }

        guard status != .error, output.frameLength > 0 else {
            return nil
        }
        return output
    }
}
