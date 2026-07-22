import Foundation

/// AEC(WebRTC APM)へ渡す固定長フレーム(既定 10ms = 480 サンプル)。
/// `hostTime` は先頭サンプルの捕捉時刻(ホストクロック、秒)。
public struct AecFrame: Sendable, Equatable {
    public var samples: [Int16]
    public var hostTime: TimeInterval

    public init(samples: [Int16], hostTime: TimeInterval) {
        self.samples = samples
        self.hostTime = hostTime
    }
}

/// 任意長のモノラル Int16 チャンク列を固定長フレームへ切り出す純ロジック(ADR-0013 の 4)。
///
/// - 端数は次のチャンクへ持ち越す。フレームの `hostTime` はチャンク先頭時刻から
///   標本数で補間する。
/// - チャンク間に不連続(持ち越しの期待時刻から半フレーム超のずれ)があれば、
///   端数を破棄して新しい時刻から仕切り直す(不連続を跨いだフレームを作らない)。
///   破棄量は `discardedSamples` に積算する(無言で失わない)。
public struct AecFramer: Sendable {
    public let frameLength: Int
    public let sampleRate: Double

    /// 不連続で破棄した持ち越しサンプルの総数(診断用)。
    public private(set) var discardedSamples: Int = 0

    private var remainder: [Int16] = []
    /// `remainder` の先頭サンプルの時刻(remainder が空なら意味を持たない)。
    private var remainderHostTime: TimeInterval = 0

    public init(frameLength: Int = 480, sampleRate: Double = 48000) {
        precondition(frameLength > 0 && sampleRate > 0)
        self.frameLength = frameLength
        self.sampleRate = sampleRate
    }

    /// チャンクを追加し、切り出せた分のフレームを返す。
    public mutating func append(samples: [Int16], hostTime: TimeInterval) -> [AecFrame] {
        guard !samples.isEmpty else { return [] }

        var startTime = hostTime
        if remainder.isEmpty {
            remainderHostTime = hostTime
        } else {
            let expected = remainderHostTime + Double(remainder.count) / sampleRate
            let tolerance = Double(frameLength) / sampleRate / 2
            if abs(hostTime - expected) > tolerance {
                // 不連続: 持ち越しを破棄して新しい時刻から仕切り直す。
                discardedSamples += remainder.count
                remainder.removeAll(keepingCapacity: true)
                remainderHostTime = hostTime
            } else {
                // 連続: 持ち越しの先頭時刻を基準に補間する。
                startTime = remainderHostTime
            }
        }

        remainder.append(contentsOf: samples)
        var frames: [AecFrame] = []
        var offset = 0
        while remainder.count - offset >= frameLength {
            let slice = Array(remainder[offset ..< (offset + frameLength)])
            let time = startTime + Double(offset) / sampleRate
            frames.append(AecFrame(samples: slice, hostTime: time))
            offset += frameLength
        }
        if offset > 0 {
            remainder.removeFirst(offset)
            remainderHostTime = startTime + Double(offset) / sampleRate
        }
        return frames
    }
}
