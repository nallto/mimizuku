import AVFoundation

/// テスト用の合成 PCM バッファ(サイン波)を作る。
enum AudioBufferTestSupport {
    /// float32・非インターリーブの標準フォーマット。
    static func standardFormat(sampleRate: Double = 48000, channels: UInt32 = 1) -> AVAudioFormat {
        guard let format = AVAudioFormat(
            standardFormatWithSampleRate: sampleRate,
            channels: AVAudioChannelCount(channels)
        ) else {
            preconditionFailure("standard format \(sampleRate)Hz/\(channels)ch を作成できない")
        }
        return format
    }

    /// 指定フレーム数のサイン波バッファ。
    static func sineBuffer(
        format: AVAudioFormat,
        frames: AVAudioFrameCount,
        frequency: Double = 440
    ) -> AVAudioPCMBuffer {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else {
            preconditionFailure("PCM バッファ(\(frames) frames)を作成できない")
        }
        buffer.frameLength = frames
        guard let channelData = buffer.floatChannelData else {
            preconditionFailure("floatChannelData を取得できない")
        }
        let sampleRate = format.sampleRate
        for channel in 0 ..< Int(format.channelCount) {
            let data = channelData[channel]
            for frame in 0 ..< Int(frames) {
                data[frame] = Float(sin(2 * .pi * frequency * Double(frame) / sampleRate)) * 0.5
            }
        }
        return buffer
    }
}
