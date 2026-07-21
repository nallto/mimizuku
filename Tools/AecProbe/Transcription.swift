import AVFoundation
import Foundation
import Speech

// aecprobe の文字起こし比較(--transcribe)。ゲート判定の本丸は「エコーが文字として
// 消えるか」なので、処理前後の mic を SpeechTranscriber で並べて比較できるようにする。

enum TranscriptionError: Error, CustomStringConvertible {
    case setupFailed(String)

    var description: String {
        switch self {
        case let .setupFailed(detail):
            "文字起こしの準備に失敗: \(detail)"
        }
    }
}

/// ファイルを SpeechTranscriber(ja-JP)で文字起こしし、確定セグメントを
/// 「[開始秒] テキスト」の行として返す。
func transcribe(url: URL) async throws -> [String] {
    let requested = Locale(identifier: "ja-JP")
    let locale = await SpeechTranscriber.supportedLocale(equivalentTo: requested) ?? requested
    let transcriber = SpeechTranscriber(
        locale: locale,
        transcriptionOptions: [],
        reportingOptions: [],
        attributeOptions: [.audioTimeRange]
    )
    let analyzer = SpeechAnalyzer(modules: [transcriber])
    guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
    else {
        throw TranscriptionError.setupFailed("入力フォーマットを取得できません")
    }

    let collector = Task {
        var lines: [String] = []
        for try await result in transcriber.results where result.isFinal {
            let start = result.range.start.seconds
            lines.append(String(format: "[%6.1fs] %@", start, String(result.text.characters)))
        }
        return lines
    }

    let (inputSequence, inputContinuation) = AsyncStream.makeStream(of: AnalyzerInput.self)
    try await analyzer.start(inputSequence: inputSequence)
    try feedAudio(from: url, format: format, into: inputContinuation)
    inputContinuation.finish()
    try await analyzer.finalizeAndFinishThroughEndOfInput()
    return try await collector.value
}

/// 対象ファイルを解析フォーマットへ変換して給餌する(SpeechEngine と同じ経路)。
private func feedAudio(
    from url: URL,
    format: AVAudioFormat,
    into continuation: AsyncStream<AnalyzerInput>.Continuation
) throws {
    let file = try AVAudioFile(forReading: url)
    guard let converter = AVAudioConverter(from: file.processingFormat, to: format),
          let inputBuffer = AVAudioPCMBuffer(
              pcmFormat: file.processingFormat,
              frameCapacity: AVAudioFrameCount(file.processingFormat.sampleRate)
          )
    else {
        throw TranscriptionError.setupFailed("変換器を作成できません(\(url.lastPathComponent))")
    }
    var reachedEnd = false
    while !reachedEnd {
        // 給餌したバッファは解析側が保持するため、出力バッファは毎回新規に確保する。
        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(format.sampleRate)
        ) else {
            throw TranscriptionError.setupFailed("バッファを確保できません")
        }
        // convert は入力ブロックを同期的に呼び切る(docs/domain-pitfalls.md #9 と同じ根拠)。
        nonisolated(unsafe) let inputBuffer = inputBuffer
        var conversionError: NSError?
        let status = converter
            .convert(to: outputBuffer, error: &conversionError) { _, inputStatus in
                inputBuffer.frameLength = 0
                try? file.read(into: inputBuffer)
                guard inputBuffer.frameLength > 0 else {
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                inputStatus.pointee = .haveData
                return inputBuffer
            }
        if status == .error {
            throw TranscriptionError.setupFailed(conversionError?.localizedDescription ?? "unknown")
        }
        if status == .endOfStream {
            reachedEnd = true
        }
        if outputBuffer.frameLength > 0 {
            continuation.yield(AnalyzerInput(buffer: outputBuffer))
        }
    }
}
