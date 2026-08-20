import AVFoundation

/// 任意のフォーマット・任意フレーム数の**厳密ゼロ**の PCM バッファを作る(#116、ADR-0017)。
///
/// 捕捉の欠落区間を埋める無音は厳密ゼロでなければならない ―― `SpeechEngine` は厳密ゼロの
/// バッファを解析へ供給せず(幻聴対策、`docs/domain-pitfalls.md` #11)、タイムラインだけを
/// 進めるため、埋めた無音が文字起こしへ悪影響を与えない性質はゼロ埋めに依存する。
/// `AVAudioPCMBuffer` は確保直後の内容がゼロとは保証されないため、明示的にゼロ埋めする。
public enum SilenceBuffer {
    /// 指定フォーマットで `frameCount` フレームの無音バッファを作る。
    /// - Returns: 確保に失敗したら nil(呼び出し側は欠落として扱い、無言で落とさない)。
    public static func make(
        format: AVAudioFormat,
        frameCount: AVAudioFrameCount
    ) -> AVAudioPCMBuffer? {
        guard frameCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)
        else {
            return nil
        }
        buffer.frameLength = frameCount
        // interleaved / deinterleaved の両方を覆うため、ABL の全バッファをゼロ埋めする。
        let list = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        for audioBuffer in list {
            guard let data = audioBuffer.mData else { return nil }
            memset(data, 0, Int(audioBuffer.mDataByteSize))
        }
        return buffer
    }
}
