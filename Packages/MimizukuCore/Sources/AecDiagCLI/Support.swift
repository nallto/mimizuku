import AVFoundation
import Foundation
import MimizukuCore

// MARK: - 入出力ヘルパー

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data(("エラー: " + message + "\n").utf8))
    exit(1)
}

func readJSONLines(_ url: URL) throws -> [String] {
    guard FileManager.default.fileExists(atPath: url.path) else { return [] }
    let content = try String(contentsOf: url, encoding: .utf8)
    return content.split(separator: "\n").map(String.init)
}

func readCAF(_ url: URL, expectedFrames: Int, frameLength: Int, label: String) -> [Int16] {
    guard FileManager.default.fileExists(atPath: url.path) else {
        if expectedFrames > 0 {
            fail("\(label) が存在しませんが、JSONL には \(expectedFrames) フレームあります。")
        }
        return []
    }
    do {
        let file = try AVAudioFile(
            forReading: url,
            commonFormat: .pcmFormatInt16,
            interleaved: true
        )
        let capacity = AVAudioFrameCount(file.length)
        guard capacity > 0 else {
            // 空 CAF も長さ整合の対象(JSONL にフレームがあるのに空なら不整合)。
            guard expectedFrames == 0 else {
                fail("""
                \(label) が空ですが、JSONL には \(expectedFrames) フレームあります。\
                試行を拒否します。
                """)
            }
            return []
        }
        let samples = try readAllSamples(from: file, capacity: capacity, label: label)
        guard samples.count == expectedFrames * frameLength else {
            fail("""
            \(label) の長さ(\(samples.count) サンプル)が JSONL のフレーム数 \
            (\(expectedFrames) × \(frameLength))と一致しません。試行を拒否します。
            """)
        }
        return samples
    } catch {
        fail("\(label) の読み込みに失敗しました: \(error.localizedDescription)")
    }
}

/// 単一の read(into:) は末尾の 4096 フレーム未満の端数を読み残す(実測)。
/// 全量に達するまで追記読みで連結する。
private func readAllSamples(
    from file: AVAudioFile,
    capacity: AVAudioFrameCount,
    label: String
) throws -> [Int16] {
    guard let buffer = AVAudioPCMBuffer(
        pcmFormat: file.processingFormat,
        frameCapacity: 65536
    ) else {
        fail("\(label) の読み込みバッファを確保できませんでした。")
    }
    var samples: [Int16] = []
    samples.reserveCapacity(Int(capacity))
    while file.framePosition < file.length {
        try file.read(into: buffer)
        guard buffer.frameLength > 0 else { break }
        guard let data = buffer.int16ChannelData else {
            fail("\(label) は int16 として読めません。")
        }
        samples.append(contentsOf: UnsafeBufferPointer(
            start: data[0],
            count: Int(buffer.frameLength)
        ))
    }
    return samples
}

func format(_ value: Double, _ digits: Int = 1) -> String {
    String(format: "%.\(digits)f", value)
}

/// 窓別 verdict 列の「delay 中央値 / estimate になった窓の割合」の表示(集計は Core)。
func delaySummaryText(_ verdicts: [AecOfflineAnalysis.WindowVerdict]) -> String {
    guard let summary = AecOfflineAnalysis.delaySummary(verdicts) else { return "n/a" }
    let rate = Int((summary.validRate * 100).rounded())
    guard let med = summary.medianMs else { return "n/a / \(rate)%" }
    return "\(format(med))ms / \(rate)%"
}

struct WindowResult {
    let index: Int
    let startHostTime: Double
    let speechTime: Double
    let verdict: AecOfflineAnalysis.WindowVerdict
}

func describe(_ verdict: AecOfflineAnalysis.WindowVerdict) -> String {
    switch verdict {
    case let .estimate(estimate):
        "delay=\(format(estimate.lagSeconds * 1000))ms corr=\(format(estimate.peakCorrelation, 2))"
    case let .indeterminate(reason):
        "判定なし(\(reason.rawValue))"
    }
}
