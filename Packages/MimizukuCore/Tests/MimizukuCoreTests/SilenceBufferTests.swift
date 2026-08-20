import AVFoundation
import Testing

@testable import MimizukuCore

struct SilenceBufferTests {
    /// バッファの全チャンネル・全バイトが厳密ゼロかを ABL 走査で確認する
    /// (`SpeechEngine` のゼロ判定と同じくフォーマット非依存のバイト走査)。
    private func isAllZero(_ buffer: AVAudioPCMBuffer) -> Bool {
        let list = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        for audioBuffer in list {
            guard let data = audioBuffer.mData else { return false }
            let bytes = data.assumingMemoryBound(to: UInt8.self)
            for index in 0 ..< Int(audioBuffer.mDataByteSize) where bytes[index] != 0 {
                return false
            }
        }
        return true
    }

    @Test("int16 interleaved モノラルの無音を生成する")
    func int16InterleavedMono() throws {
        let format = try #require(AVAudioFormat(
            commonFormat: .pcmFormatInt16, sampleRate: 48000, channels: 1, interleaved: true
        ))
        let buffer = try #require(SilenceBuffer.make(format: format, frameCount: 480))
        #expect(buffer.frameLength == 480)
        #expect(buffer.format == format)
        #expect(isAllZero(buffer))
    }

    @Test("float32 deinterleaved ステレオの無音を生成する")
    func float32DeinterleavedStereo() throws {
        let format = try #require(AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 44100, channels: 2, interleaved: false
        ))
        let buffer = try #require(SilenceBuffer.make(format: format, frameCount: 4410))
        #expect(buffer.frameLength == 4410)
        #expect(isAllZero(buffer))
        // deinterleaved は ABL に 2 バッファ載る(片チャンネルだけのゼロ埋めでないこと)。
        let list = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        #expect(list.count == 2)
    }

    @Test("フレーム数ゼロは nil を返す")
    func zeroFrameCountReturnsNil() throws {
        let format = try #require(AVAudioFormat(
            commonFormat: .pcmFormatInt16, sampleRate: 48000, channels: 1, interleaved: true
        ))
        #expect(SilenceBuffer.make(format: format, frameCount: 0) == nil)
    }
}
