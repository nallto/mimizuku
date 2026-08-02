import AVFoundation
import Foundation
import Testing

@testable import MimizukuCore

@Suite("AecDiagnosticsWriter")
struct AecDiagnosticsWriterTests {
    private func makeTempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(component: "AecDiagnosticsWriterTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func frame(_ value: Int16) -> [Int16] {
        [Int16](repeating: value, count: 480)
    }

    private func captureRecord(
        frameIndex: Int,
        silenced: Bool = false
    ) -> AecDiagnosticsRecord.Capture {
        .init(
            frameIndex: frameIndex,
            outputFrameIndex: frameIndex,
            speechTimeSeconds: Double(frameIndex) * 0.01,
            hostTime: 100 + Double(frameIndex) * 0.01,
            silenced: silenced,
            epoch: 0,
            rawRMSDBFS: -20,
            processedRMSDBFS: silenced ? nil : -40,
            renderFedCount: silenced ? 0 : 1
        )
    }

    private func readCAFSamples(_ url: URL) throws -> [Int16] {
        let file = try AVAudioFile(
            forReading: url,
            commonFormat: .pcmFormatInt16,
            interleaved: true
        )
        guard file.length > 0,
              let buffer = AVAudioPCMBuffer(
                  pcmFormat: file.processingFormat,
                  frameCapacity: AVAudioFrameCount(file.length) + 4096
              )
        else { return [] }
        var samples: [Int16] = []
        while file.framePosition < file.length {
            try file.read(into: buffer)
            guard buffer.frameLength > 0, let data = buffer.int16ChannelData else { break }
            samples.append(contentsOf: UnsafeBufferPointer(
                start: data[0],
                count: Int(buffer.frameLength)
            ))
        }
        return samples
    }

    /// silenced → 処理済みの順で capture 2 フレーム + received / fed 各 1 フレーム、
    /// pumpFinished イベント、その後の Speech final を投入する(close 順序の検証を含む)。
    private func enqueueAlignedFixture(into trial: AecDiagnosticsTrial) {
        trial.recorder.enqueue(.capture(
            captureRecord(frameIndex: 0, silenced: true),
            raw: frame(11),
            processed: frame(0)
        ))
        trial.recorder.enqueue(.renderReceived(
            .init(renderFrameIndex: 0, hostTime: 100.0, epoch: 0, rmsDBFS: -20),
            samples: frame(22)
        ))
        trial.recorder.enqueue(.renderFed(
            .init(
                fedIndex: 0,
                hostTime: 100.0,
                epoch: 0,
                provenance: .actual,
                fedBeforeCaptureFrameIndex: 1,
                rmsDBFS: -20
            ),
            samples: frame(33)
        ))
        trial.recorder.enqueue(.capture(
            captureRecord(frameIndex: 1),
            raw: frame(44),
            processed: frame(4)
        ))
        trial.recorder.enqueue(.record(.event(.init(kind: .pumpFinished, epoch: 0))))
        // pumpFinished 後に届く Speech final も close 前なら受け付ける(close 順序)。
        trial.recorder.enqueue(.speech(.init(
            stream: "microphone",
            text: "こんにちは",
            isFinal: true,
            start: 1.0,
            end: 2.0
        )))
    }

    /// CAF 整列: raw は silenced でも原音、processed はゼロ。位置 = frameIndex×480。
    private func verifyAlignedAudio(in directory: URL) throws {
        let raw = try readCAFSamples(
            directory.appending(component: AecDiagnosticsLayout.captureRawFileName)
        )
        let processed = try readCAFSamples(
            directory.appending(component: AecDiagnosticsLayout.captureProcessedFileName)
        )
        #expect(raw == frame(11) + frame(44))
        #expect(processed == frame(0) + frame(4))
        let received = try readCAFSamples(
            directory.appending(component: AecDiagnosticsLayout.renderReceivedFileName)
        )
        let fed = try readCAFSamples(
            directory.appending(component: AecDiagnosticsLayout.renderFedFileName)
        )
        #expect(received == frame(22))
        #expect(fed == frame(33))
    }

    /// JSONL: 全レコードが decode でき、speech は分離され、meta.json が読み戻せる。
    private func verifyJSONL(in directory: URL, meta: AecDiagnosticsMeta) throws {
        let framesURL = directory.appending(component: AecDiagnosticsLayout.framesFileName)
        let lines = try String(contentsOf: framesURL, encoding: .utf8)
            .split(separator: "\n").map(String.init)
        let records = try lines.map {
            try AecDiagnosticsJSONL.decode(AecDiagnosticsRecord.self, from: $0)
        }
        #expect(records.count == 5)
        let speechURL = directory.appending(component: AecDiagnosticsLayout.speechFileName)
        let speechLines = try String(contentsOf: speechURL, encoding: .utf8)
            .split(separator: "\n").map(String.init)
        #expect(speechLines.count == 1)
        let speech = try AecDiagnosticsJSONL.decode(AecSpeechRecord.self, from: speechLines[0])
        #expect(speech.text == "こんにちは")
        let metaLine = try String(
            contentsOf: directory.appending(component: AecDiagnosticsLayout.metaFileName),
            encoding: .utf8
        )
        let decodedMeta = try AecDiagnosticsJSONL.decode(
            AecDiagnosticsMeta.self,
            from: metaLine.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        #expect(decodedMeta == meta)
    }

    @Test("4 CAF と JSONL がサンプル整列したまま書かれ、meta が確定する")
    func writesAlignedFilesAndMeta() async throws {
        let directory = try makeTempDirectory()
        let trial = AecDiagnosticsTrial(
            directory: directory,
            mode: "both",
            startedAt: Date(timeIntervalSince1970: 1_785_484_800),
            startHostTime: 100
        )
        enqueueAlignedFixture(into: trial)
        let meta = await trial.close(speechStartOffsets: ["microphone": 0.25])

        #expect(meta.valid)
        #expect(meta.invalidReasons.isEmpty)
        #expect(meta.captureFrameCount == 2)
        #expect(meta.renderReceivedFrameCount == 1)
        #expect(meta.renderFedFrameCount == 1)
        #expect(meta.speechStartOffsets == ["microphone": 0.25])
        try verifyAlignedAudio(in: directory)
        try verifyJSONL(in: directory, meta: meta)
        try? FileManager.default.removeItem(at: directory)
    }

    @Test("close は冪等(2 回目は同じ meta を返し、二重書き込みしない)")
    func closeIsIdempotent() async throws {
        let directory = try makeTempDirectory()
        let trial = AecDiagnosticsTrial(
            directory: directory,
            mode: "micOnly",
            startedAt: Date(timeIntervalSince1970: 0),
            startHostTime: 0
        )
        trial.recorder.enqueue(.capture(
            captureRecord(frameIndex: 0),
            raw: frame(1),
            processed: frame(2)
        ))
        let first = await trial.close()
        let second = await trial.close()
        #expect(first == second)
        #expect(first.captureFrameCount == 1)
        try? FileManager.default.removeItem(at: directory)
    }

    @Test("書き込み失敗(ディレクトリ消失)は valid=false になり、以後は drain のみ")
    func writeFailureInvalidatesTrial() async throws {
        let directory = try makeTempDirectory()
        // 試行ディレクトリを消してから書かせる → CAF open が失敗する。
        try FileManager.default.removeItem(at: directory)
        let trial = AecDiagnosticsTrial(
            directory: directory,
            mode: "micOnly",
            startedAt: Date(timeIntervalSince1970: 0),
            startHostTime: 0
        )
        for index in 0 ..< 3 {
            trial.recorder.enqueue(.capture(
                captureRecord(frameIndex: index),
                raw: frame(1),
                processed: frame(2)
            ))
        }
        let meta = await trial.close()
        #expect(!meta.valid)
        #expect(meta.invalidReasons.contains { $0.hasPrefix("writeError") })
        // 失敗後は書かれない(整合カウントは失敗前の成功分のみ = 0)。
        #expect(meta.captureFrameCount == 0)
    }

    @Test("バッファ溢れは 1 件でも drop したら valid=false になる")
    func overflowInvalidatesTrial() async throws {
        let directory = try makeTempDirectory()
        let trial = AecDiagnosticsTrial(
            directory: directory,
            mode: "micOnly",
            startedAt: Date(timeIntervalSince1970: 0),
            startHostTime: 0,
            bufferCapacity: 0
        )
        for index in 0 ..< 5 {
            trial.recorder.enqueue(.capture(
                captureRecord(frameIndex: index),
                raw: frame(1),
                processed: frame(2)
            ))
        }
        // 容量 0 でも、待機中の writer Task へ 1 件直渡しされ得るため drop 数は
        // 4〜5 で揺れる。契約は「1 件でも drop したら invalid」なので件数は固定しない。
        #expect(trial.recorder.droppedRecords > 0)
        let meta = await trial.close()
        #expect(!meta.valid)
        #expect(meta.droppedRecords == trial.recorder.droppedRecords)
        #expect(meta.invalidReasons.contains { $0.hasPrefix("writerOverflow") })
        try? FileManager.default.removeItem(at: directory)
    }
}
