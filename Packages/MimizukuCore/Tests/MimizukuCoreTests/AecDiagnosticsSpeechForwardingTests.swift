import AVFoundation
import Foundation
import Testing

@testable import MimizukuCore

@Suite("AecDiagnosticsSpeechForwarding")
struct AecDiagnosticsSpeechForwardingTests {
    private func makeTempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(component: "AecDiagnosticsSpeechTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("enqueueSpeech は TranscriptRun の正規化済み segment を speech.jsonl へ写す")
    func enqueueSpeechRecordsNormalizedSegment() async throws {
        // stop 直後の start 回帰の CI 検証可能部分: 転送は StreamExecution が保持する
        // recorder へ直接行い(generation 判定なし)、TranscriptRun がセッション原点へ
        // シフトした start/end がそのまま speech.jsonl に残ることを確認する。
        let directory = try makeTempDirectory()
        let trial = AecDiagnosticsTrial(
            directory: directory,
            mode: "micOnly",
            startedAt: Date(timeIntervalSince1970: 0),
            startHostTime: 0
        )
        let journalURL = directory.appending(component: "journal.jsonl")
        let run = try TranscriptRun(
            sessionID: UUID(),
            trackIDs: [.microphone: UUID()],
            journalURL: journalURL
        )
        await run.setStartOffset(0.25, for: .microphone)
        let persisted = try await run.apply(TranscriptSegment(
            stream: .microphone,
            text: "テスト",
            isFinal: true,
            start: 1.0,
            end: 2.0
        ))
        trial.recorder.enqueueSpeech(persisted)
        let meta = await trial.close(speechStartOffsets: ["microphone": 0.25])
        #expect(meta.speechStartOffsets == ["microphone": 0.25])

        let speechURL = directory.appending(component: AecDiagnosticsLayout.speechFileName)
        let lines = try String(contentsOf: speechURL, encoding: .utf8)
            .split(separator: "\n").map(String.init)
        #expect(lines.count == 1)
        let record = try AecDiagnosticsJSONL.decode(AecSpeechRecord.self, from: lines[0])
        #expect(record.stream == "microphone")
        #expect(record.isFinal)
        // セッション原点へ +0.25 シフト済み。mic 解析原点へは offsets で戻せる。
        #expect(record.start == 1.25)
        #expect(record.end == 2.25)
        try? FileManager.default.removeItem(at: directory)
    }

    @Test("recorder は溢れたメッセージだけを数える(bufferingOldest)")
    func recorderCountsOnlyDroppedMessages() {
        // stream を保持しないと continuation が terminated になり drop を数えられない。
        let (stream, continuation) = AsyncStream.makeStream(
            of: AecDiagnosticsMessage.self,
            bufferingPolicy: .bufferingOldest(1)
        )
        defer { _ = stream }
        let recorder = AecDiagnosticsRecorder(continuation: continuation)
        // 消費者がいないため 1 件目はバッファに載り、以降は drop される。
        for _ in 0 ..< 3 {
            recorder.enqueue(.record(.event(.init(kind: .pumpFinished, epoch: 0))))
        }
        #expect(recorder.droppedRecords == 2)
        continuation.finish()
    }
}
