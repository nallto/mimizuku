import AVFoundation
import Foundation
import Testing

@testable import MimizukuCore

struct AudioFileWriterTests {
    private func makeTempUrl() -> URL {
        FileManager.default.temporaryDirectory
            .appending(component: "AudioFileWriterTests-\(UUID().uuidString).caf")
    }

    @Test func writesBuffersAndReadsBackSameLength() async throws {
        let url = makeTempUrl()
        defer { try? FileManager.default.removeItem(at: url) }
        let format = AudioBufferTestSupport.standardFormat()
        let writer = AudioFileWriter(url: url)

        for _ in 0 ..< 3 {
            try await writer.write(AudioBufferTestSupport.sineBuffer(format: format, frames: 4800))
        }
        let frames = await writer.finish()

        #expect(frames == 14400)
        let readBack = try AVAudioFile(forReading: url)
        #expect(readBack.length == 14400)
        // ファイル形式は LPCM 16bit(ADR-0006)、フォーマットは最初のバッファに従う。
        #expect(readBack.fileFormat.commonFormat == .pcmFormatInt16)
        #expect(readBack.fileFormat.sampleRate == 48000)
    }

    @Test func rejectsFormatChangeAfterFirstBuffer() async throws {
        let url = makeTempUrl()
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = AudioFileWriter(url: url)
        try await writer.write(AudioBufferTestSupport.sineBuffer(
            format: AudioBufferTestSupport.standardFormat(),
            frames: 480
        ))

        let changedFormat = AudioBufferTestSupport.standardFormat(sampleRate: 44100)
        await #expect(throws: AudioFileWriterError.formatMismatch) {
            try await writer.write(AudioBufferTestSupport.sineBuffer(
                format: changedFormat,
                frames: 441
            ))
        }
    }

    @Test func rejectsWriteAfterFinish() async throws {
        let url = makeTempUrl()
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = AudioFileWriter(url: url)
        _ = await writer.finish()

        await #expect(throws: AudioFileWriterError.alreadyFinished) {
            try await writer.write(AudioBufferTestSupport.sineBuffer(
                format: AudioBufferTestSupport.standardFormat(),
                frames: 480
            ))
        }
    }

    @Test func neverOpenedWriterCreatesNoFile() async {
        let url = makeTempUrl()
        let writer = AudioFileWriter(url: url)

        let frames = await writer.finish()

        // 1 バッファも来なければファイルは作られない(空セッションを残さない)。
        #expect(frames == 0)
        #expect(await writer.duration == 0)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func durationReflectsWrittenFrames() async throws {
        let url = makeTempUrl()
        defer { try? FileManager.default.removeItem(at: url) }
        let format = AudioBufferTestSupport.standardFormat() // 48kHz
        let writer = AudioFileWriter(url: url)

        // 48000 frames @ 48kHz = 1.0 秒。
        try await writer.write(AudioBufferTestSupport.sineBuffer(format: format, frames: 48000))

        #expect(await abs(writer.duration - 1.0) < 0.0001)
    }
}
