import MimizukuCore
import Testing

@Suite("CaptureSelection")
struct CaptureSelectionTests {
    @Test("単独選択は対応する 1 ストリームだけを返す")
    func singleSelections() {
        #expect(CaptureSelection.microphone.streams == [.microphone])
        #expect(CaptureSelection.systemAudio.streams == [.systemAudio])
    }

    @Test("both は両ストリームを StreamKind の宣言順で返す")
    func bothIsOrderedByDeclaration() {
        #expect(CaptureSelection.both.streams == StreamKind.allCases)
    }

    @Test("どの選択も空にならず、ストリームは重複しない")
    func streamsAreNonEmptyAndUnique() {
        for selection in CaptureSelection.allCases {
            let streams = selection.streams
            #expect(!streams.isEmpty)
            #expect(Set(streams).count == streams.count)
        }
    }
}
