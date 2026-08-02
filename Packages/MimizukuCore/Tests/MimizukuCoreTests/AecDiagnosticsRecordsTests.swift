import Foundation
import MimizukuCore
import Testing

@Suite("AecDiagnosticsRecords")
struct AecDiagnosticsRecordsTests {
    @Test("capture レコードは type 判別子付きで round-trip する")
    func captureRoundTrip() throws {
        let record = AecDiagnosticsRecord.capture(.init(
            frameIndex: 12,
            outputFrameIndex: 15,
            speechTimeSeconds: 0.15,
            hostTime: 100.12,
            silenced: false,
            epoch: 1,
            rawRMSDBFS: -20.5,
            processedRMSDBFS: -41.25,
            renderFedCount: 2
        ))
        let line = try AecDiagnosticsJSONL.encode(record)
        #expect(line.contains("\"type\":\"capture\""))
        #expect(!line.contains("\n"))
        let decoded = try AecDiagnosticsJSONL.decode(AecDiagnosticsRecord.self, from: line)
        #expect(decoded == record)
    }

    @Test("完全無音の RMS(nil)はキーごと省略される")
    func nilRMSKeysAreOmitted() throws {
        let record = AecDiagnosticsRecord.capture(.init(
            frameIndex: 0,
            outputFrameIndex: 0,
            speechTimeSeconds: 0,
            hostTime: 0,
            silenced: true,
            epoch: 0,
            rawRMSDBFS: nil,
            processedRMSDBFS: nil,
            renderFedCount: 0
        ))
        let line = try AecDiagnosticsJSONL.encode(record)
        #expect(!line.contains("rawRMSDBFS"))
        #expect(!line.contains("processedRMSDBFS"))
        let decoded = try AecDiagnosticsJSONL.decode(AecDiagnosticsRecord.self, from: line)
        #expect(decoded == record)
    }

    @Test("renderFed は provenance(actual / gapFilled)を保持して round-trip する")
    func renderFedRoundTrip() throws {
        for provenance in [AecDiagnosticsRecord.RenderProvenance.actual, .gapFilled] {
            let record = AecDiagnosticsRecord.renderFed(.init(
                fedIndex: 5,
                hostTime: 3.14,
                epoch: 2,
                provenance: provenance,
                fedBeforeCaptureFrameIndex: 7,
                rmsDBFS: -30
            ))
            let line = try AecDiagnosticsJSONL.encode(record)
            let decoded = try AecDiagnosticsJSONL.decode(AecDiagnosticsRecord.self, from: line)
            #expect(decoded == record)
        }
    }

    @Test("inputChunk は初回チャンク(delta / driftPPM なし)も round-trip する")
    func inputChunkRoundTrip() throws {
        let first = AecDiagnosticsRecord.inputChunk(.init(
            stream: .capture,
            observedHostTime: 10.0,
            normalizedHostTime: 10.0,
            sampleCount: 4096,
            timingDeltaMs: nil,
            rebased: false,
            epoch: 0,
            driftPPM: nil
        ))
        let later = AecDiagnosticsRecord.inputChunk(.init(
            stream: .render,
            observedHostTime: 20.002,
            normalizedHostTime: 20.0,
            sampleCount: 4096,
            timingDeltaMs: 2.0,
            rebased: true,
            epoch: 1,
            driftPPM: -12.5
        ))
        for record in [first, later] {
            let line = try AecDiagnosticsJSONL.encode(record)
            let decoded = try AecDiagnosticsJSONL.decode(AecDiagnosticsRecord.self, from: line)
            #expect(decoded == record)
        }
    }

    @Test("event / apmStats(全フィールド欠落を含む)が round-trip する")
    func eventAndStatsRoundTrip() throws {
        let event = AecDiagnosticsRecord.event(.init(
            kind: .leadRenderDropped,
            firstHostTime: 1.0,
            lastHostTime: 1.03,
            frameCount: 4,
            epoch: 0
        ))
        // APM 統計は全フィールド optional ―― 何も報告されない期間のレコードも成立する。
        let emptyStats = AecDiagnosticsRecord.apmStats(.init(hostTime: 5.0))
        let fullStats = AecDiagnosticsRecord.apmStats(.init(
            hostTime: 6.0,
            echoReturnLoss: 10.5,
            echoReturnLossEnhancement: 22.0,
            delayMs: 120,
            delayMedianMs: 118,
            delayStdMs: 4,
            divergentFilterFraction: 0.02,
            residualEchoLikelihood: 0.1
        ))
        for record in [event, emptyStats, fullStats] {
            let line = try AecDiagnosticsJSONL.encode(record)
            let decoded = try AecDiagnosticsJSONL.decode(AecDiagnosticsRecord.self, from: line)
            #expect(decoded == record)
        }
    }

    @Test("未知の type は decode エラーになる")
    func unknownTypeThrows() {
        let line = #"{"type":"mystery","hostTime":0}"#
        #expect(throws: DecodingError.self) {
            _ = try AecDiagnosticsJSONL.decode(AecDiagnosticsRecord.self, from: line)
        }
    }

    @Test("meta.json と speech.jsonl のレコードが round-trip する")
    func metaAndSpeechRoundTrip() throws {
        let meta = AecDiagnosticsMeta(
            trialID: "20260730-120000",
            mode: "micOnly",
            startedAt: Date(timeIntervalSince1970: 1_785_484_800),
            startHostTime: 1234.5,
            valid: false,
            invalidReasons: ["writerOverflow"],
            droppedRecords: 3,
            captureFrameCount: 100,
            renderReceivedFrameCount: 90,
            renderFedFrameCount: 95
        )
        let metaLine = try AecDiagnosticsJSONL.encode(meta)
        let decodedMeta = try AecDiagnosticsJSONL.decode(AecDiagnosticsMeta.self, from: metaLine)
        #expect(decodedMeta == meta)

        let speech = AecSpeechRecord(
            stream: "microphone",
            text: "こんにちは",
            isFinal: true,
            start: 1.5,
            end: 2.1
        )
        let speechLine = try AecDiagnosticsJSONL.encode(speech)
        let decodedSpeech = try AecDiagnosticsJSONL.decode(
            AecSpeechRecord.self,
            from: speechLine
        )
        #expect(decodedSpeech == speech)
    }

    // MARK: - RMS / 電力比

    @Test("RMS: フルスケールは約 0 dBFS、半分の振幅は約 −6 dBFS")
    func rmsReferenceValues() throws {
        let fullScale = [Int16](repeating: 32767, count: 480)
        let full = try #require(AecAudioMetrics.rmsDBFS(fullScale))
        #expect(abs(full) < 0.001)
        let halfScale = [Int16](repeating: 16384, count: 480)
        let half = try #require(AecAudioMetrics.rmsDBFS(halfScale))
        #expect(abs(half - 20 * log10(0.5)) < 0.001)
    }

    @Test("RMS: 完全無音と空配列は nil(−∞ を返さない)")
    func rmsSilenceIsNil() {
        #expect(AecAudioMetrics.rmsDBFS([Int16](repeating: 0, count: 480)) == nil)
        #expect(AecAudioMetrics.rmsDBFS([]) == nil)
    }

    @Test("電力比: 振幅 10 倍の差は 20 dB")
    func powerRatioReferenceValue() throws {
        let raw = [Int16](repeating: 1000, count: 480)
        let processed = [Int16](repeating: 100, count: 480)
        let ratio = try #require(AecAudioMetrics.powerRatioDB(raw: raw, processed: processed))
        #expect(abs(ratio - 20) < 0.001)
    }

    @Test("電力比: raw 無音は nil、processed のみ無音(完全抑圧)は +∞")
    func powerRatioEdgeCases() {
        let silence = [Int16](repeating: 0, count: 480)
        let tone = [Int16](repeating: 1000, count: 480)
        #expect(AecAudioMetrics.powerRatioDB(raw: silence, processed: tone) == nil)
        #expect(AecAudioMetrics.powerRatioDB(raw: tone, processed: silence) == .infinity)
    }
}
