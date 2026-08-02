import AVFoundation
import Foundation
import MimizukuCore

// AEC 診断試行(#75 / ADR-0015)のオフライン解析 CLI。
//
// 使い方: `aec-diag <試行ディレクトリ>`(`just aec-diag <dir>`)。
//
// 解析対象は 3 対に分かれる:
// - raw × render-received: 捕捉クロック・参照信号そのものの診断(host time 整列)
// - raw × render-fed: APM が見た参照系列の診断(fedIndex = APM 内部時間の正典)
// - raw × processed: echo-dominant candidate window の処理前後電力比
//
// valid=false、または CAF 長と JSONL の不整合がある試行は正式数値を出さず拒否する。

// MARK: - 引数と meta 検証

let arguments = CommandLine.arguments
guard arguments.count == 2 else {
    fail("使い方: aec-diag <試行ディレクトリ>")
}

let directory = URL(filePath: arguments[1], directoryHint: .isDirectory)

let metaURL = directory.appending(component: AecDiagnosticsLayout.metaFileName)
guard let metaLine = try? String(contentsOf: metaURL, encoding: .utf8) else {
    fail("meta.json を読めません(close 前に終了した試行の可能性): \(metaURL.path)")
}

let meta: AecDiagnosticsMeta
do {
    meta = try AecDiagnosticsJSONL.decode(
        AecDiagnosticsMeta.self,
        from: metaLine.trimmingCharacters(in: .whitespacesAndNewlines)
    )
} catch {
    fail("meta.json を解釈できません: \(error.localizedDescription)")
}

guard meta.valid else {
    fail("""
    この試行は診断経路自身に欠損があり(\(meta.invalidReasons.joined(separator: " / ")))、\
    正式数値を出せません。試行をやり直してください。
    """)
}

// MARK: - frames.jsonl の読み込みと整合検査

var captures: [AecDiagnosticsRecord.Capture] = []
var received: [AecDiagnosticsRecord.RenderReceived] = []
var fed: [AecDiagnosticsRecord.RenderFed] = []
var chunks: [AecDiagnosticsRecord.InputChunk] = []
var events: [AecDiagnosticsRecord.Event] = []
var apmStats: [AecDiagnosticsRecord.ApmStats] = []

do {
    let lines = try readJSONLines(
        directory.appending(component: AecDiagnosticsLayout.framesFileName)
    )
    for line in lines {
        switch try AecDiagnosticsJSONL.decode(AecDiagnosticsRecord.self, from: line) {
        case let .capture(record): captures.append(record)
        case let .renderReceived(record): received.append(record)
        case let .renderFed(record): fed.append(record)
        case let .inputChunk(record): chunks.append(record)
        case let .event(record): events.append(record)
        case let .apmStats(record): apmStats.append(record)
        }
    }
} catch {
    fail("frames.jsonl を解釈できません: \(error.localizedDescription)")
}

for (label, actual, expected) in [
    ("capture", captures.count, meta.captureFrameCount),
    ("renderReceived", received.count, meta.renderReceivedFrameCount),
    ("renderFed", fed.count, meta.renderFedFrameCount)
] where actual != expected {
    fail("\(label) レコード数(\(actual))が meta の記録(\(expected))と一致しません。")
}

let frameLength = meta.frameLength
let rawSamples = readCAF(
    directory.appending(component: AecDiagnosticsLayout.captureRawFileName),
    expectedFrames: captures.count, frameLength: frameLength, label: "capture-raw.caf"
)
let processedSamples = readCAF(
    directory.appending(component: AecDiagnosticsLayout.captureProcessedFileName),
    expectedFrames: captures.count, frameLength: frameLength, label: "capture-processed.caf"
)
let receivedSamples = readCAF(
    directory.appending(component: AecDiagnosticsLayout.renderReceivedFileName),
    expectedFrames: received.count, frameLength: frameLength, label: "render-received.caf"
)
let fedSamples = readCAF(
    directory.appending(component: AecDiagnosticsLayout.renderFedFileName),
    expectedFrames: fed.count, frameLength: frameLength, label: "render-fed.caf"
)

// MARK: - サマリ

print("# aec-diag: \(meta.trialID)")
print("モード=\(meta.mode) 開始=\(meta.startedAt) startHostTime=\(format(meta.startHostTime, 3))")
print("""
capture=\(captures.count)f(\(format(Double(captures.count) * 0.01))s) \
received=\(received.count)f fed=\(fed.count)f 無音置換=\(captures.count(where: \.silenced))f
""")

// MARK: - inputChunk(正規化前の実測時刻・ドリフト)

print("\n## inputChunk(実測時刻 vs サンプルクロック予測)")
for stream in [AecDiagnosticsRecord.ChunkStream.capture, .render] {
    let streamChunks = chunks.filter { $0.stream == stream }
    guard !streamChunks.isEmpty else {
        print("- \(stream.rawValue): チャンクなし")
        continue
    }
    let deltas = streamChunks.compactMap(\.timingDeltaMs).sorted()
    let rebases = streamChunks.count(where: \.rebased)
    let lastDrift = streamChunks.compactMap(\.driftPPM).last
    var line = "- \(stream.rawValue): \(streamChunks.count) chunks rebase=\(rebases)"
    if !deltas.isEmpty {
        let median = deltas[deltas.count / 2]
        line += " deltaMs(min/med/max)=\(format(deltas[0]))/\(format(median))"
        line += "/\(format(deltas[deltas.count - 1]))"
    }
    line += " driftPPM=\(lastDrift.map { format($0) } ?? "n/a")"
    print(line)
}

// MARK: - イベント

print("\n## イベント")
if events.isEmpty {
    print("- なし")
}

for event in events {
    var line = "- \(event.kind.rawValue) epoch=\(event.epoch)"
    if let hostTime = event.hostTime { line += " t=\(format(hostTime, 3))" }
    if let first = event.firstHostTime, let last = event.lastHostTime {
        line += " range=\(format(first, 3))..\(format(last, 3))"
    }
    if let count = event.frameCount { line += " frames=\(count)" }
    if let count = event.sampleCount { line += " samples=\(count)" }
    if let delta = event.deltaMs { line += " deltaMs=\(format(delta))" }
    if let message = event.message { line += " (\(message))" }
    print(line)
}

// MARK: - APM 統計(内部推定値)

print("\n## APM 統計(APM 内部推定値 ―― 実測の除去量そのものではない)")
if apmStats.isEmpty {
    print("- 記録なし")
}

for stats in apmStats {
    var line = "- t=\(format(stats.hostTime, 1))"
    line += " erl=\(stats.echoReturnLoss.map { format($0) } ?? "-")"
    line += " erle=\(stats.echoReturnLossEnhancement.map { format($0) } ?? "-")"
    line += " delay=\(stats.delayMs.map { format($0, 0) } ?? "-")"
    line += " median=\(stats.delayMedianMs.map { format($0, 0) } ?? "-")"
    line += " std=\(stats.delayStdMs.map { format($0, 0) } ?? "-")"
    line += " divergent=\(stats.divergentFilterFraction.map { format($0, 2) } ?? "-")"
    line += " residual=\(stats.residualEchoLikelihood.map { format($0, 2) } ?? "-")"
    print(line)
}

// MARK: - 窓解析

let analysisConfig = AecOfflineAnalysis.Config()
let windowFrames = Int(analysisConfig.windowDuration * 100)
let hopFrames = Int(analysisConfig.hopDuration * 100)
let frameDuration = Double(frameLength) / meta.sampleRate

/// capture フレーム列が窓の中で連続しているか(正規化タイムラインの跳び・epoch 跨ぎを除外)。
@MainActor
func isContiguousCaptureWindow(_ range: Range<Int>) -> Bool {
    guard let first = range.first, let last = range.last else { return false }
    guard captures[first].epoch == captures[last].epoch else { return false }
    for index in range.dropFirst() {
        let expected = captures[index - 1].hostTime + frameDuration
        if abs(captures[index].hostTime - expected) > 0.001 { return false }
    }
    return true
}

/// host time 範囲に対応する renderReceived の連続フレーム列を返す(欠落があれば nil)。
@MainActor
func receivedContext(from start: Double, to end: Double) -> (samples: [Int16], offset: Double)? {
    let indices = received.indices.filter { received[$0].hostTime >= start - frameDuration / 2
        && received[$0].hostTime < end
    }
    guard let firstIndex = indices.first, let lastIndex = indices.last,
          indices.count == lastIndex - firstIndex + 1
    else { return nil }
    for index in (firstIndex + 1) ... max(firstIndex + 1, lastIndex) where index <= lastIndex {
        let expected = received[index - 1].hostTime + frameDuration
        if abs(received[index].hostTime - expected) > 0.001 { return nil }
    }
    let samples = Array(
        receivedSamples[firstIndex * frameLength ..< (lastIndex + 1) * frameLength]
    )
    return (samples, received[firstIndex].hostTime)
}

print("\n## 遅延推定: raw × render-received(捕捉クロック・参照信号の診断)")
var receivedResults: [WindowResult] = []
var windowIndex = 0
var frameStart = 0
while frameStart + windowFrames <= captures.count {
    defer {
        frameStart += hopFrames
        windowIndex += 1
    }
    let range = frameStart ..< (frameStart + windowFrames)
    guard isContiguousCaptureWindow(range) else { continue }
    let start = captures[frameStart].hostTime
    let captureWindow = Array(
        rawSamples[frameStart * frameLength ..< (frameStart + windowFrames) * frameLength]
    )
    let verdict: AecOfflineAnalysis.WindowVerdict = if let context = receivedContext(
        from: start - analysisConfig.maxLag,
        to: start + analysisConfig.windowDuration - analysisConfig.minLag
    ) {
        AecOfflineAnalysis.estimateDelay(
            capture: captureWindow,
            render: context.samples,
            renderStartOffset: context.offset - start,
            sampleRate: meta.sampleRate
        )
    } else {
        .indeterminate(.insufficientRenderContext)
    }
    let result = WindowResult(
        index: windowIndex,
        startHostTime: start,
        speechTime: captures[frameStart].speechTimeSeconds,
        verdict: verdict
    )
    receivedResults.append(result)
    print(
        "- w\(result.index) t=\(format(start, 2)) speech=\(format(result.speechTime, 1))s "
            + describe(verdict)
    )
}

if receivedResults.isEmpty {
    print("- 解析可能な窓なし")
}

print("\n## 遅延推定: raw × render-fed(APM が見た参照系列 ―― fedIndex 整列)")
// 解析本体は Core(`AecOfflineAnalysis.analyzeFedPair` ―― epoch ごとに silenced を
// 除いた処理順を capture 軸とし、窓ごとに fed の hostTime から対応点を復元)。
// 合成試行での最終遅延値の検証は Core のテストが担う。
let fedResults = AecOfflineAnalysis.analyzeFedPair(.init(
    captures: captures,
    fed: fed,
    rawSamples: rawSamples,
    fedSamples: fedSamples,
    frameLength: frameLength,
    sampleRate: meta.sampleRate
))
for result in fedResults {
    print(
        "- epoch\(result.epoch) frame=\(result.captureFrameIndex) "
            + describe(result.verdict)
    )
}

if fedResults.isEmpty {
    print("- 解析可能な窓なし")
}

print("\n## 残留: echo-dominant candidate window の処理前後電力比(ERLE ではない)")
print("(条件: raw×render-received の遅延推定が有効な窓のみ。近端発話を除外できない窓は")
print(" far-end 単独と断定しない ―― controlled test では人間は発話しないこと)")
var ratios: [Double] = []
for result in receivedResults {
    guard case .estimate = result.verdict else { continue }
    let start = result.index * hopFrames
    // silenced フレームは processed=0 のため電力比を「∞(完全抑圧)」へ歪める。
    // 無音置換を含む窓は残留判定の対象にしない。
    guard !captures[start ..< (start + windowFrames)].contains(where: \.silenced) else {
        continue
    }
    let range = start * frameLength ..< (start + windowFrames) * frameLength
    let raw = Array(rawSamples[range])
    let processed = Array(processedSamples[range])
    guard let ratio = AecAudioMetrics.powerRatioDB(raw: raw, processed: processed) else {
        continue
    }
    ratios.append(ratio)
    print(
        "- w\(result.index) t=\(format(result.startHostTime, 2)) "
            + "ratio=\(ratio.isInfinite ? "∞(完全抑圧)" : format(ratio) + "dB")"
    )
}

if ratios.isEmpty {
    print("- 対象窓なし")
} else {
    let finite = ratios.filter(\.isFinite).sorted()
    if !finite.isEmpty {
        print("中央値=\(format(finite[finite.count / 2]))dB(有限値 \(finite.count) 窓)")
    }
}

// MARK: - Speech(診断写し)

print("\n## Speech(speech.jsonl ―― start/end はセッション原点。mic 解析原点との対応は下記 offset)")
if let offsets = meta.speechStartOffsets, !offsets.isEmpty {
    let joined = offsets.sorted { $0.key < $1.key }
        .map { "\($0.key)=+\(format($0.value, 3))s" }
        .joined(separator: " ")
    print("startOffsets: \(joined)(mic の start/end からこの値を引くと speechTimeSeconds 軸)")
} else {
    print("startOffsets: 記録なし(旧試行)")
}

do {
    let lines = try readJSONLines(
        directory.appending(component: AecDiagnosticsLayout.speechFileName)
    )
    if lines.isEmpty {
        print("- なし")
    }
    for line in lines {
        let record = try AecDiagnosticsJSONL.decode(AecSpeechRecord.self, from: line)
        let kind = record.isFinal ? "final" : "volatile"
        let range = [record.start, record.end]
            .map { value in value.map { format($0, 2) } ?? "?" }
            .joined(separator: "-")
        print("- [\(record.stream)] \(range)s (\(kind)) \(record.text)")
    }
} catch {
    fail("speech.jsonl を解釈できません: \(error.localizedDescription)")
}

// MARK: - 試行サマリー(Issue #75 記録用)

print("\n## 試行サマリー(Issue #75 記録用 ―― 行をそのまま表へ貼る。Speech 回り込みのみ手動判定)")
let receivedSummary = delaySummaryText(receivedResults.map(\.verdict))
let fedSummary = delaySummaryText(fedResults.map(\.verdict))
let captureDrift = chunks.filter { $0.stream == .capture }.compactMap(\.driftPPM).last
let renderDrift = chunks.filter { $0.stream == .render }.compactMap(\.driftPPM).last
let residualMedian = AecOfflineAnalysis.median(ratios.filter(\.isFinite))
    .map { format($0) + "dB" } ?? "n/a"
let erleMedian = AecOfflineAnalysis.median(apmStats.compactMap(\.echoReturnLossEnhancement))
    .map { format($0) + "dB" } ?? "n/a"
let eventSummary = events.isEmpty
    ? "なし"
    : Dictionary(grouping: events, by: \.kind.rawValue)
    .sorted { $0.key < $1.key }
    .map { "\($0.key)×\($0.value.count)" }
    .joined(separator: " ")
print("""
| trial | mode | received delay med/valid | fed delay med/valid | capture driftPPM \
| render driftPPM | 残留比 med | APM ERLE med | events | Speech回り込み |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| \(meta.trialID) | \(meta.mode) | \(receivedSummary) | \(fedSummary) \
| \(captureDrift.map { format($0) } ?? "n/a") \
| \(renderDrift.map { format($0) } ?? "n/a") \
| \(residualMedian) | \(erleMedian) | \(eventSummary) | (手動) |
""")
