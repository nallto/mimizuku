import AVFoundation

/// `AudioFileWriter` の失敗理由。
public enum AudioFileWriterError: Error, LocalizedError, Equatable {
    /// 書き込みバッファのフォーマットが最初のバッファ(=ファイル)と一致しない。
    case formatMismatch
    /// `finish()` 後に書き込もうとした。
    case alreadyFinished

    public var errorDescription: String? {
        switch self {
        case .formatMismatch:
            "録音バッファのフォーマットが録音ファイルと一致しません。"
        case .alreadyFinished:
            "録音ファイルはすでに閉じられています。"
        }
    }
}

/// 捕捉バッファを CAF(LPCM 16bit)へ追記書き込みする actor(ADR-0006)。
///
/// - CAF は音声チャンク長を不定のまま追記できるため、書き込み途中の突然死でも
///   そのまま読める(録音中のクラッシュ耐性を形式選定で担保)。
/// - **ファイルは最初の `write` で遅延オープン**し、フォーマットはそのバッファから
///   確定させる。捕捉開始前のハードウェアフォーマット照会はデバイス状態によって
///   クラッシュしうるため行わない(`AudioSource` 契約)。1 バッファも来なければ
///   ファイルは作られない(空セッションを残さない)。
/// - `AVAudioFile` は Sendable でないため actor 内に閉じ込め、外には URL と
///   フレーム数だけを出す(docs/domain-pitfalls.md #9 と同じ規律)。
public actor AudioFileWriter {
    public nonisolated let url: URL

    private var file: AVAudioFile?
    private var framesWritten: AVAudioFramePosition = 0
    private var processingFormat: AVAudioFormat?
    private var finished = false

    /// - Parameter url: 書き込み先(親ディレクトリは作成済みであること)。
    ///   ファイル自体は最初の `write` まで作られない。
    public init(url: URL) {
        self.url = url
    }

    /// 書き込んだ録音の長さ(秒)。フォーマット未確定(1 バッファも来ていない)なら 0。
    /// 短すぎるセッションの破棄判定に使う(ADR-0006 の 8)。
    public var duration: TimeInterval {
        guard let sampleRate = processingFormat?.sampleRate, sampleRate > 0 else { return 0 }
        return TimeInterval(framesWritten) / sampleRate
    }

    /// バッファを追記する。初回はバッファのフォーマットでファイルを作成する。
    /// 2 回目以降のフォーマット不一致(セッション中のデバイス変更等)は無言で
    /// 欠損させず throw する。
    public func write(_ buffer: sending AVAudioPCMBuffer) throws {
        guard !finished else { throw AudioFileWriterError.alreadyFinished }
        if file == nil {
            try open(with: buffer.format)
        }
        guard let file, let processingFormat else { throw AudioFileWriterError.alreadyFinished }
        guard isCompatible(buffer.format, with: processingFormat) else {
            throw AudioFileWriterError.formatMismatch
        }
        try file.write(from: buffer)
        framesWritten += AVAudioFramePosition(buffer.frameLength)
    }

    /// 書き込みを終えてファイルを閉じる。返り値は書き込んだ総フレーム数
    /// (1 バッファも来なければ 0 で、ファイルは存在しない)。
    /// (`AVAudioFile.length` は未フラッシュ分を反映しないため自前で数える)
    public func finish() -> AVAudioFramePosition {
        // AVAudioFile は解放時にフラッシュ・クローズされる。
        file = nil
        finished = true
        return framesWritten
    }

    private func open(with format: AVAudioFormat) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: format.channelCount,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
        let file = try AVAudioFile(
            forWriting: url,
            settings: settings,
            commonFormat: format.commonFormat,
            interleaved: format.isInterleaved
        )
        self.file = file
        processingFormat = file.processingFormat
    }

    /// サンプルレート・チャンネル数・サンプル形式の一致を確認する。
    /// (`AVAudioFormat` の完全一致比較は channelLayout の有無で偽陰性になるため使わない)
    private func isCompatible(_ format: AVAudioFormat, with reference: AVAudioFormat) -> Bool {
        format.sampleRate == reference.sampleRate
            && format.channelCount == reference.channelCount
            && format.commonFormat == reference.commonFormat
            && format.isInterleaved == reference.isInterleaved
    }
}
