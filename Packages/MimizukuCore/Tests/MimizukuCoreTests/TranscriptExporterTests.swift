import Foundation
import Testing

@testable import MimizukuCore

@Suite("TranscriptExporter")
struct TranscriptExporterTests {
    @Test("60分セッションを時刻・ラベル・未完了表示付きで出力する")
    func exportsLongSession() {
        let trackID = UUID()
        let track = SessionTrack(
            id: trackID,
            origin: .systemAudio,
            label: "相手",
            relativeAudioPath: "system.m4a"
        )
        let document = TranscriptDocument(
            sessionID: UUID(),
            sourceRunID: UUID(),
            appliedSequence: 2,
            blocks: [
                TranscriptBlock(
                    trackID: trackID,
                    text: "開始します。",
                    start: 0,
                    end: 1,
                    isComplete: true
                ),
                TranscriptBlock(
                    trackID: trackID,
                    text: "続きは",
                    start: 3600,
                    end: 3601,
                    isComplete: false
                )
            ]
        )
        let exporter = TranscriptExporter()

        #expect(
            exporter.markdown(document: document, tracks: [track])
                == "- [00:00] **相手:** 開始します。\n- [01:00:00] **相手:** 続きは [未完了]\n"
        )
        #expect(
            exporter.plainText(document: document, tracks: [track])
                == "[00:00] 相手: 開始します。\n[01:00:00] 相手: 続きは [未完了]\n"
        )
    }
}
