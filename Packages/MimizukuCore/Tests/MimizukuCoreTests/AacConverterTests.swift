import AVFoundation
import Foundation
import Testing

@testable import MimizukuCore

struct AacConverterTests {
    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appending(component: "AacConverterTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// 1 秒のサイン波 CAF を作る。
    private func makeCaf(in dir: URL) async throws -> URL {
        let url = dir.appending(component: "mic.caf")
        let format = AudioBufferTestSupport.standardFormat()
        let writer = AudioFileWriter(url: url)
        try await writer.write(AudioBufferTestSupport.sineBuffer(format: format, frames: 48000))
        _ = await writer.finish()
        return url
    }

    @Test func convertsCafToM4aAndDeletesOriginal() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let caf = try await makeCaf(in: dir)

        let m4a = try AacConverter().convert(caf: caf)

        #expect(m4a.lastPathComponent == "mic.m4a")
        #expect(FileManager.default.fileExists(atPath: m4a.path))
        #expect(!FileManager.default.fileExists(atPath: caf.path))
        // デコードでき、長さが元とほぼ一致する(プライミング分の許容差内)。
        let decoded = try AVAudioFile(forReading: m4a)
        #expect(abs(decoded.length - 48000) <= AacConverter.frameTolerance)
    }

    @Test func unreadableSourceThrowsAndLeavesNoOutput() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let missing = dir.appending(component: "missing.caf")

        #expect(throws: AacConversionError.self) {
            _ = try AacConverter().convert(caf: missing)
        }
        #expect(
            !FileManager.default
                .fileExists(atPath: dir.appending(component: "missing.m4a").path)
        )
    }

    @Test func corruptSourceKeepsCafIntact() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        // CAF として読めないゴミデータ。
        let caf = dir.appending(component: "system.caf")
        try Data([0x00, 0x01, 0x02, 0x03]).write(to: caf)

        #expect(throws: AacConversionError.self) {
            _ = try AacConverter().convert(caf: caf)
        }
        // 失敗しても元ファイルは温存される(再変換可能に保つ)。
        #expect(FileManager.default.fileExists(atPath: caf.path))
        #expect(
            !FileManager.default
                .fileExists(atPath: dir.appending(component: "system.m4a").path)
        )
    }
}
