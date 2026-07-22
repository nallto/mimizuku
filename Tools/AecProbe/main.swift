import AVFoundation
import Foundation

// AEC のオフライン検証 CLI(ADR-0013 / #61)。実録音ペアを WebRTC APM(AEC3)に通し、
// 処理後 WAV と抑圧量の実測値を出力する。開発用であり配布物ではない。
//
// 使い方: aecprobe <mic 音声> <system 音声> <出力.wav> [--transcribe]
//   - 入力は AVAudioFile が読める形式(m4a / caf / wav)。48kHz モノラル int16 へ変換して処理する。
//   - ストリーム間の捕捉開始ずれはエンベロープ相互相関で自動整列する。
//   - --transcribe: 処理前後の mic を SpeechTranscriber(ja-JP)で文字起こしして並べる
//     (ゲート判定の本丸 ―― エコーが「文字として」消えたかを直接比較する)。

private let sampleRate = 48000.0

private enum ProbeError: Error, CustomStringConvertible {
    case usage
    case unsupportedFile(String)
    case conversionFailed(String)
    case bridgeFailed(String)

    var description: String {
        switch self {
        case .usage:
            "使い方: aecprobe <mic 音声> <system 音声> <出力.wav> [--transcribe]"
        case let .unsupportedFile(detail):
            "入力を読めません: \(detail)"
        case let .conversionFailed(detail):
            "フォーマット変換に失敗: \(detail)"
        case let .bridgeFailed(detail):
            "APM の初期化/処理に失敗: \(detail)"
        }
    }
}

/// 変換パイプライン(ファイル → 48kHz / モノラル / int16)の器。
private struct ConversionPipeline {
    let converter: AVAudioConverter
    let inputBuffer: AVAudioPCMBuffer
    let outputBuffer: AVAudioPCMBuffer
}

private func makePipeline(for file: AVAudioFile, name: String) throws -> ConversionPipeline {
    guard let target = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: sampleRate,
        channels: 1,
        interleaved: true
    ) else {
        throw ProbeError.conversionFailed("target format")
    }
    guard let converter = AVAudioConverter(from: file.processingFormat, to: target),
          let inputBuffer = AVAudioPCMBuffer(
              pcmFormat: file.processingFormat,
              frameCapacity: AVAudioFrameCount(sampleRate)
          ),
          let outputBuffer = AVAudioPCMBuffer(
              pcmFormat: target,
              frameCapacity: AVAudioFrameCount(sampleRate)
          )
    else {
        throw ProbeError.conversionFailed("converter for \(name)")
    }
    return ConversionPipeline(
        converter: converter,
        inputBuffer: inputBuffer,
        outputBuffer: outputBuffer
    )
}

/// 任意の入力ファイルを 48kHz / モノラル / int16 のサンプル列へ読み込む。
private func loadSamples(from url: URL) throws -> [Int16] {
    let file = try AVAudioFile(forReading: url)
    let pipeline = try makePipeline(for: file, name: url.lastPathComponent)
    let converter = pipeline.converter
    let outputBuffer = pipeline.outputBuffer

    var samples: [Int16] = []
    var reachedEnd = false
    while !reachedEnd {
        // convert は入力ブロックを同期的に呼び切る。非 Sendable な inputBuffer を
        // 渡しても安全(docs/domain-pitfalls.md #9 と同じ根拠)。閉包は throw できない
        // ため、読み込みエラーは捕捉して外で判定する ―― `AVAudioFile.read` は EOF でも
        // 例外を投げることがあるため、ファイル末尾に到達済みなら正常終了、途中なら
        // 本物の I/O エラーとして投げ直す(無警告の切り詰めを許さない)。
        nonisolated(unsafe) let inputBuffer = pipeline.inputBuffer
        nonisolated(unsafe) var readError: Error?
        var conversionError: NSError?
        outputBuffer.frameLength = 0
        let status = converter
            .convert(to: outputBuffer, error: &conversionError) { _, inputStatus in
                inputBuffer.frameLength = 0
                do {
                    try file.read(into: inputBuffer)
                } catch {
                    readError = error
                }
                guard readError == nil, inputBuffer.frameLength > 0 else {
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                inputStatus.pointee = .haveData
                return inputBuffer
            }
        if let readError, file.framePosition < file.length {
            throw ProbeError.unsupportedFile(
                "\(url.lastPathComponent): \(readError.localizedDescription)"
            )
        }
        switch status {
        case .error:
            throw ProbeError.conversionFailed(conversionError?.localizedDescription ?? "unknown")
        case .endOfStream:
            reachedEnd = true
        default:
            break
        }
        if let data = outputBuffer.int16ChannelData {
            samples.append(contentsOf: UnsafeBufferPointer(
                start: data[0],
                count: Int(outputBuffer.frameLength)
            ))
        }
    }
    return samples
}

/// サンプル列を 48kHz / モノラル / int16 の WAV へ書き出す。
private func writeWav(_ samples: [Int16], to url: URL) throws {
    guard let format = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: sampleRate,
        channels: 1,
        interleaved: true
    ) else {
        throw ProbeError.conversionFailed("output format")
    }
    let file = try AVAudioFile(
        forWriting: url,
        settings: format.settings,
        commonFormat: .pcmFormatInt16,
        interleaved: true
    )
    guard let buffer = AVAudioPCMBuffer(
        pcmFormat: format,
        frameCapacity: AVAudioFrameCount(samples.count)
    ),
        let channel = buffer.int16ChannelData
    else {
        throw ProbeError.conversionFailed("output buffer")
    }
    samples.withUnsafeBufferPointer { source in
        if let base = source.baseAddress {
            channel[0].update(from: base, count: samples.count)
        }
    }
    buffer.frameLength = AVAudioFrameCount(samples.count)
    try file.write(from: buffer)
}

private func rms(_ samples: ArraySlice<Int16>) -> Double {
    guard !samples.isEmpty else { return 0 }
    let sum = samples.reduce(0.0) { $0 + Double($1) * Double($1) }
    return (sum / Double(samples.count)).squareRoot()
}

private func decibel(_ ratio: Double) -> Double {
    ratio > 0 ? 20 * log10(ratio) : -.infinity
}

// MARK: - ストリーム間の粗整列

/// 10ms ごとの RMS エンベロープ(平均除去済み)。
private func envelope(of samples: [Int16], hop: Int) -> [Double] {
    var values: [Double] = []
    values.reserveCapacity(samples.count / hop)
    var index = 0
    while index + hop <= samples.count {
        values.append(rms(samples[index ..< (index + hop)]))
        index += hop
    }
    let mean = values.reduce(0, +) / Double(max(values.count, 1))
    return values.map { $0 - mean }
}

/// system(far-end)のエコーが mic に現れるまでの遅れをエンベロープ相互相関で推定する
/// (返り値はサンプル数。正 = mic 側で遅れて現れる)。探索範囲は ±3 秒。
///
/// 録音ファイルはストリームごとに捕捉開始時刻が異なる(実測: システム tap は
/// マイクより約 1.2 秒遅く始まる)ため、単純な先頭合わせでは AEC3 の遅延推定範囲
/// (数百 ms)を超えてロックしない。ライブ統合(AEC-3)では捕捉タイムスタンプで
/// 整列するが、オフライン検証では内容から推定する。
private func estimateEchoLag(mic: [Int16], system: [Int16]) -> Int {
    let hop = Int(sampleRate) / 100 // 10ms
    let micEnvelope = envelope(of: mic, hop: hop)
    let systemEnvelope = envelope(of: system, hop: hop)
    let searchRange = 300 // ±3 秒(10ms 単位)
    let count = min(micEnvelope.count, systemEnvelope.count)
    var bestLag = 0
    var bestScore = -Double.infinity
    for lag in -searchRange ... searchRange {
        var score = 0.0
        var matched = 0
        for index in stride(from: 0, to: count, by: 2) {
            let micIndex = index + lag
            guard micIndex >= 0, micIndex < micEnvelope.count else { continue }
            score += systemEnvelope[index] * micEnvelope[micIndex]
            matched += 1
        }
        guard matched > 0 else { continue }
        let normalized = score / Double(matched)
        if normalized > bestScore {
            bestScore = normalized
            bestLag = lag
        }
    }
    return bestLag * hop
}

// MARK: - メイン

let arguments = CommandLine.arguments
guard arguments.count == 4 || (arguments.count == 5 && arguments[4] == "--transcribe") else {
    print(ProbeError.usage)
    exit(2)
}

let micURL = URL(fileURLWithPath: arguments[1])
let systemURL = URL(fileURLWithPath: arguments[2])
let outputURL = URL(fileURLWithPath: arguments[3])
let wantsTranscription = arguments.count == 5

do {
    var mic = try loadSamples(from: micURL)
    var system = try loadSamples(from: systemURL)
    print(
        "mic: \(String(format: "%.1f", Double(mic.count) / sampleRate))s / " +
            "system: \(String(format: "%.1f", Double(system.count) / sampleRate))s"
    )

    // 粗整列: エコー遅れが AEC3 の推定範囲に収まるよう、少しの正の遅延(50ms)を
    // 残して先頭をトリムする。
    let lag = estimateEchoLag(mic: mic, system: system)
    print(String(format: "推定エコー遅れ: %+.0f ms(エンベロープ相互相関)", Double(lag) * 1000 / sampleRate))
    let margin = Int(sampleRate) / 20 // 50ms
    let shift = lag - margin
    if shift > 0 {
        mic.removeFirst(min(shift, mic.count))
    } else if shift < 0 {
        system.removeFirst(min(-shift, system.count))
    }

    let bridge = AudioProcessingBridge()
    guard bridge.initializeProcessing() else {
        throw ProbeError.bridgeFailed("initializeProcessing")
    }
    defer { bridge.shutdown() }

    let frameLength = Int(AudioProcessingBridge.frameSampleCount)
    let frameCount = min(mic.count, system.count) / frameLength
    var processed: [Int16] = []
    processed.reserveCapacity(frameCount * frameLength)
    var frame = [Int16](repeating: 0, count: frameLength)

    // 順序厳守: 各 10ms tick で render(far-end)→ capture の順に供給する(ADR-0013)。
    for index in 0 ..< frameCount {
        let range = (index * frameLength) ..< ((index + 1) * frameLength)
        let renderOk = system[range].withContiguousStorageIfAvailable { pointer -> Bool in
            guard let base = pointer.baseAddress else { return false }
            return bridge.processRenderFrame(base)
        } ?? false
        frame.replaceSubrange(0 ..< frameLength, with: mic[range])
        let captureOk = frame.withUnsafeMutableBufferPointer { pointer -> Bool in
            guard let base = pointer.baseAddress else { return false }
            return bridge.processCaptureFrame(base)
        }
        guard renderOk, captureOk else {
            throw ProbeError.bridgeFailed("frame \(index)")
        }
        processed.append(contentsOf: frame)
    }

    try? FileManager.default.removeItem(at: outputURL)
    try writeWav(processed, to: outputURL)

    // 抑圧量の実測: 1 秒窓ごとに処理前後の mic RMS 比を取る。収束期間(先頭 2 秒)は除外。
    // far-end 有音の閾値は -44dBFS 相当(int16 RMS 200)。
    //
    // 注意: 「抑圧量」には AEC だけでなく NS + HPF の寄与も混入する。far-end 無音窓の
    // 平均を NS ベースラインとして併記するので、AEC 純度は「有音平均 − 無音平均」で読む
    // (ゲート目安 20dB の判定時はこの差分と試聴を併用する。ADR-0013 の 7)。
    let window = Int(sampleRate)
    let farActiveThreshold = 200.0
    let convergenceWindows = 2
    var activeSuppressions: [Double] = []
    var idleSuppressions: [Double] = []
    print("win  far(dBFS)  mic-in(dBFS)  mic-out(dBFS)  supp(dB)")
    for windowIndex in 0 ..< (processed.count / window) {
        let range = (windowIndex * window) ..< ((windowIndex + 1) * window)
        let far = rms(system[range])
        let inRms = rms(mic[range])
        let outRms = rms(processed[range])
        let farActive = far > farActiveThreshold
        let suppression = decibel(inRms / max(outRms, 1))
        if windowIndex >= convergenceWindows {
            if farActive {
                activeSuppressions.append(suppression)
            } else {
                idleSuppressions.append(suppression)
            }
        }
        let mark = farActive ? "*" : " "
        print(String(
            format: "%3d%@  %8.1f  %11.1f  %12.1f  %7.1f",
            windowIndex, mark,
            decibel(far / 32768), decibel(inRms / 32768), decibel(outRms / 32768),
            suppression
        ))
    }
    if activeSuppressions.isEmpty {
        print("far-end が有音の窓が無く、抑圧量を算出できません(system 側が無音?)")
    } else {
        let active = activeSuppressions.reduce(0, +) / Double(activeSuppressions.count)
        print(String(
            format: "far-end 有音 %d 窓(収束後)の平均抑圧量: %.1f dB(AEC + NS + HPF 込み)",
            activeSuppressions.count, active
        ))
        if !idleSuppressions.isEmpty {
            let idle = idleSuppressions.reduce(0, +) / Double(idleSuppressions.count)
            print(String(
                format: "far-end 無音 %d 窓の平均(NS ベースライン): %.1f dB → AEC 寄与の目安: %.1f dB",
                idleSuppressions.count, idle, active - idle
            ))
        }
    }
    print("出力: \(outputURL.path)")

    if wantsTranscription {
        print("\n=== 文字起こし比較(確定セグメントのみ、ja-JP)===")
        print("--- 処理前(元の mic ―― エコー混入あり)---")
        for line in try await transcribe(url: micURL) {
            print(line)
        }
        print("--- 処理後(AEC 適用)---")
        for line in try await transcribe(url: outputURL) {
            print(line)
        }
        print("※ 処理後にだけ相手の発言由来の行が消えていれば、二重文字起こしは解消。")
    }
} catch {
    print("error: \(error)")
    exit(1)
}
