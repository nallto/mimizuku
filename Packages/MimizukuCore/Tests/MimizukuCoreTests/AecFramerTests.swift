import Foundation
import MimizukuCore
import Testing

@Suite("AecFramer")
struct AecFramerTests {
    private let frameDuration = 480.0 / 48000.0 // 10ms

    @Test("空チャンクは何も生まない")
    func emptyChunk() {
        var framer = AecFramer()
        let frames = framer.append(samples: [], hostTime: 0)
        #expect(frames.isEmpty)
        #expect(framer.discardedSamples == 0)
    }

    @Test("ちょうど 1 フレーム分で 1 フレーム、時刻はチャンク先頭")
    func exactFrame() {
        var framer = AecFramer()
        let samples = [Int16](repeating: 7, count: 480)
        let frames = framer.append(samples: samples, hostTime: 1.5)
        #expect(frames == [AecFrame(samples: samples, hostTime: 1.5)])
    }

    @Test("端数は持ち越され、跨いだフレームの時刻は持ち越し先頭から補間される")
    func remainderCarry() {
        var framer = AecFramer()
        let first = framer.append(samples: [Int16](repeating: 1, count: 300), hostTime: 0)
        #expect(first.isEmpty)
        // 続き(300 サンプル後 = 300/48000 秒後)を追加すると 480 サンプルで 1 フレーム。
        let second = framer.append(
            samples: [Int16](repeating: 2, count: 300),
            hostTime: 300.0 / 48000.0
        )
        #expect(second.count == 1)
        #expect(second[0].hostTime == 0)
        #expect(second[0].samples == [Int16](repeating: 1, count: 300) + [Int16](
            repeating: 2,
            count: 180
        ))
    }

    @Test("長いチャンクは複数フレームに割れ、時刻が標本数で補間される")
    func multipleFrames() {
        var framer = AecFramer()
        let frames = framer.append(samples: [Int16](repeating: 0, count: 960), hostTime: 2.0)
        #expect(frames.count == 2)
        #expect(frames[0].hostTime == 2.0)
        #expect(abs(frames[1].hostTime - (2.0 + frameDuration)) < 1e-9)
    }

    @Test("不連続チャンクは持ち越しを破棄して仕切り直す")
    func discontinuityDiscardsRemainder() {
        var framer = AecFramer()
        _ = framer.append(samples: [Int16](repeating: 1, count: 300), hostTime: 0)
        // 期待時刻(300/48000 ≒ 6.25ms)から大きく飛んだチャンク。
        let frames = framer.append(samples: [Int16](repeating: 2, count: 480), hostTime: 5.0)
        #expect(framer.discardedSamples == 300)
        #expect(frames == [AecFrame(samples: [Int16](repeating: 2, count: 480), hostTime: 5.0)])
    }
}
