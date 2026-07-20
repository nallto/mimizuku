import AVFoundation

/// `AacConverter` の失敗理由。失敗時は元の CAF を温存する。
public enum AacConversionError: Error, LocalizedError {
    /// 変換元の CAF を読めない。
    case sourceUnreadable(URL)
    /// 変換結果の検証(デコード可否 + フレーム長照合)に失敗した。
    case verificationFailed(URL)

    public var errorDescription: String? {
        switch self {
        case let .sourceUnreadable(url):
            "録音ファイルを読み込めませんでした: \(url.lastPathComponent)"
        case let .verificationFailed(url):
            "変換結果の検証に失敗しました: \(url.lastPathComponent)"
        }
    }
}

/// CAF(PCM)を AAC(.m4a)へ変換し、検証後に元 CAF を削除する(ADR-0006 の 2)。
///
/// - ビットレートはチャンネル数から選ぶ: モノラル 64kbps / 2ch 以上 128kbps。
/// - 検証はデコード可否とフレーム長の照合(AAC のプライミングで先頭が僅かに
///   ずれるため許容差 `frameTolerance` を持つ)。
/// - 失敗時は throw し、CAF を温存、部分的な m4a は削除する(再変換可能に保つ)。
public struct AacConverter: Sendable {
    /// フレーム長照合の許容差(AAC エンコーダのプライミング/パディング分)。
    public static let frameTolerance: AVAudioFramePosition = 4096

    public init() {}

    /// `caf` を同名の `.m4a` へ変換・検証し、成功したら CAF を削除して m4a の URL を返す。
    public func convert(caf: URL) throws -> URL {
        let source: AVAudioFile
        do {
            source = try AVAudioFile(forReading: caf)
        } catch {
            throw AacConversionError.sourceUnreadable(caf)
        }

        let destination = caf.deletingPathExtension().appendingPathExtension("m4a")
        // 前回の失敗で残った部分ファイルがあれば消してから書く。
        try? FileManager.default.removeItem(at: destination)

        do {
            try encode(source: source, to: destination)
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw AacConversionError.verificationFailed(caf)
        }

        guard let verified = try? AVAudioFile(forReading: destination),
              abs(verified.length - source.length) <= Self.frameTolerance
        else {
            try? FileManager.default.removeItem(at: destination)
            throw AacConversionError.verificationFailed(caf)
        }

        try FileManager.default.removeItem(at: caf)
        return destination
    }

    /// PCM を読み出しながら AAC へ書く。出力ファイルはこの関数を抜けた時点で
    /// 閉じられている(検証はその後に行う)。
    private func encode(source: AVAudioFile, to destination: URL) throws {
        let format = source.processingFormat
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: format.channelCount,
            AVEncoderBitRateKey: format.channelCount >= 2 ? 128_000 : 64000
        ]
        let output = try AVAudioFile(
            forWriting: destination,
            settings: settings,
            commonFormat: format.commonFormat,
            interleaved: format.isInterleaved
        )

        let chunkFrames: AVAudioFrameCount = 32768
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunkFrames) else {
            throw AacConversionError.verificationFailed(destination)
        }
        source.framePosition = 0
        while source.framePosition < source.length {
            try source.read(into: buffer, frameCount: chunkFrames)
            if buffer.frameLength == 0 { break }
            try output.write(from: buffer)
        }
    }
}
