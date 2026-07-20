import AVFoundation
import MimizukuCore
import OSLog

/// `AVAudioConverter` で入力バッファを target フォーマットの独立コピーへ変換する。
/// 単一タスク内でのみ使う(非 Sendable)。docs/domain-pitfalls.md #9。
final class BufferConverter {
    private let converter: AVAudioConverter
    private let targetFormat: AVAudioFormat

    init?(from sourceFormat: AVAudioFormat, to targetFormat: AVAudioFormat) {
        guard let converter = AVAudioConverter(from: sourceFormat, to: targetFormat) else {
            return nil
        }
        self.converter = converter
        self.targetFormat = targetFormat
    }

    /// 入力バッファを target フォーマットへ変換し、**新規に確保したバッファ**へ書き出して返す。
    /// 返り値は入力と記憶域を共有しない(所有権を切り離したコピー)。
    func convertedCopy(of input: AVAudioPCMBuffer) -> sending AVAudioPCMBuffer? {
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

/// ルーターの文字起こし出力を `AudioSource` として `SpeechEngine` へ渡すアダプタ。
///
/// `AudioSource` の cold 契約に対し、本アダプタはルーター起動済みのストリームを
/// **1 回だけ**返す(単一消費者・単回使用。2 回目の `buffers()` は空で終わる)。
/// ストリームは唯一の消費者(SpeechEngine のセッション)だけが触るため、
/// 保持は nonisolated(unsafe) とする(`@unchecked Sendable` で型ごと覆わない)。
final class RoutedAudioSource: AudioSource {
    let kind: StreamKind

    private nonisolated(unsafe) var stream: AsyncThrowingStream<AVAudioPCMBuffer, Error>?

    init(kind: StreamKind, stream: AsyncThrowingStream<AVAudioPCMBuffer, Error>) {
        self.kind = kind
        self.stream = stream
    }

    func buffers() -> AsyncThrowingStream<AVAudioPCMBuffer, Error> {
        guard let stream else {
            return AsyncThrowingStream { $0.finish() }
        }
        self.stream = nil
        return stream
    }
}

/// 1 つの `AudioSource` を「文字起こし(推奨フォーマットへ変換)」と「録音(native 品質の
/// CAF 書き込み)」の 2 消費者へ配る(ADR-0003 の AudioRouter / ADR-0006)。
///
/// - 変換器はソースの **最初のバッファ**のフォーマットから遅延生成する(捕捉開始前の
///   ハードウェア照会をしない ―― `AudioSource` 契約)。
/// - 録音経路はドロップしない(録音の欠落 = データ喪失)。バッファリングはソース
///   ストリーム側の無制限バッファに任せ、ルーターはディスク書き込み速度で消費する。
/// - 録音の書き込み失敗は文字起こしストリームへ伝播させ、セッション全体を止める
///   (無言の欠損を許さない)。
/// - ソースの失敗(watchdog 等)も同様に伝播する(tap 再構築は S3)。
enum AudioRouter {
    /// ルーターを起動し、`SpeechEngine` に渡す文字起こし用ソースを返す。
    /// 録音はルーター内で `recorder` へ直接書き込む(ファイルは最初のバッファで
    /// 遅延オープンされる)。
    ///
    /// 停止フロー: 文字起こし側ストリームの終了(セッション Task のキャンセル)で
    /// ルーター Task が畳まれ、ソースの tap / エンジンが解放される。`recorder` の
    /// `finish()` は呼び出し側(セッション所有者)の責務。
    static func route(
        source: any AudioSource,
        transcriptionFormat: AVAudioFormat,
        recorder: AudioFileWriter
    ) -> RoutedAudioSource {
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: AVAudioPCMBuffer.self)

        let task = Task {
            // 最初のバッファのフォーマットから遅延生成する変換器。
            // 注意: optional 連鎖(`converter?.convertedCopy`)を挟むと戻り値の sending 性が
            // 失われるため、呼び出しは非 optional の let に剥がしてから行う。
            var converters: (transcription: BufferConverter, recording: BufferConverter)?
            do {
                for try await buffer in source.buffers() {
                    let (transcriptionConverter, recordingCopier) = if let converters {
                        converters
                    } else {
                        try (
                            makeConverter(from: buffer.format, to: transcriptionFormat),
                            makeConverter(from: buffer.format, to: buffer.format)
                        )
                    }
                    converters = (transcriptionConverter, recordingCopier)

                    if let converted = transcriptionConverter.convertedCopy(of: buffer) {
                        continuation.yield(converted)
                    }
                    // 録音経路はドロップ禁止: コピー失敗(バッファ確保失敗)も無言で
                    // 欠損させず、セッション全体を止める。
                    guard let copy = recordingCopier.convertedCopy(of: buffer) else {
                        throw CaptureError.bufferCopyFailed
                    }
                    try await recorder.write(copy)
                }
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
        continuation.onTermination = { _ in task.cancel() }

        return RoutedAudioSource(kind: source.kind, stream: stream)
    }

    private static func makeConverter(
        from sourceFormat: AVAudioFormat,
        to targetFormat: AVAudioFormat
    ) throws -> BufferConverter {
        guard let converter = BufferConverter(from: sourceFormat, to: targetFormat) else {
            throw CaptureError.converterUnavailable(from: sourceFormat, to: targetFormat)
        }
        return converter
    }
}
