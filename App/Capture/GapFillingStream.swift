import AVFoundation
import MimizukuCore
import OSLog

/// 捕捉ストリームの欠落充填の App 側配線(#116、ADR-0017)。
///
/// 捕捉の再構築中(`docs/domain-pitfalls.md` #14 / #16 / #17)や tap がコールバックを
/// 出さない区間(#15)に失われた時間を、ホストタイムの連続性から実測した長さの厳密ゼロ
/// 無音で埋め、録音・文字起こしの時間軸を壁時計に一致させる。判定は Core の
/// `CaptureGapFiller`(純ロジック・CI テスト対象)が行い、ここは無音バッファの生成と
/// yield・ログの副作用だけを持つ。
///
/// 挿入点は **AEC の外側・`AudioRouter` 直前**(ADR-0017)。ソース内部で差し込むと
/// 埋め無音が AEC の状態機械(`AecTimeline` / `AecFeedScheduler`)を通ってしまい、
/// 実機検証済みの回復挙動を乱すため。
enum GapFillingStreamSupport {
    /// 欠落検知の閾値(秒)。**検知の閾値であり、埋める長さの定数ではない**(#116 は
    /// 固定値で埋めることを禁じている ―― 埋める長さは毎回の実測差分)。
    /// `AecTimeline` の capture 側 rebase 閾値と同値に揃える ―― AEC 出力経路の欠落は
    /// capture タイムラインの rebase として現れるため、これより小さい欠落はそもそも
    /// 下流から観測できない。
    static let fillThreshold: TimeInterval = 0.25
    /// 無音チャンクの最大長(秒)。分単位の欠落(実測 129 秒)での巨大確保を避ける。
    static let maxChunkSeconds: TimeInterval = 1.0

    /// timestamped ストリームの欠落を無音で埋めつつ、`buffers()` 契約のバッファ列へ
    /// 変換する(cold・単一消費者の性質は上流に従う)。
    static func fillingGaps(
        _ upstream: AsyncThrowingStream<TimestampedAudioBuffer, Error>,
        kind: StreamKind,
        logger: Logger
    ) -> AsyncThrowingStream<AVAudioPCMBuffer, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                var state = CaptureGapFillState(kind: kind, logger: logger)
                do {
                    for try await item in upstream {
                        for silence in try state.silenceBuffers(before: item) {
                            // 無音バッファは本メソッド内で新規確保した単一所有
                            // (docs/domain-pitfalls.md #9 の既存運用と同一)。
                            nonisolated(unsafe) let silence = silence
                            continuation.yield(silence)
                        }
                        // バッファは独立コピーの単一所有(TimestampedAudioBuffer の
                        // 正当化コメント参照)。
                        nonisolated(unsafe) let buffer = item.buffer
                        continuation.yield(buffer)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// AEC 出力(`AecFrame`)経路の欠落判定と無音フレーム生成(`AecPump` の
/// `mapFramesToBuffers` 用)。判定は `CaptureGapFillState` と同じ `CaptureGapFiller`。
struct AecFrameGapFillState {
    private let sampleRate: Double
    private let logger: Logger
    private var filler: CaptureGapFiller

    init(sampleRate: Double, logger: Logger) {
        self.sampleRate = sampleRate
        self.logger = logger
        filler = CaptureGapFiller(
            sampleRate: sampleRate,
            fillThreshold: GapFillingStreamSupport.fillThreshold
        )
    }

    /// `frame` の**前**に差し込むべき無音フレーム列。欠落が無ければ空。
    mutating func silenceFrames(before frame: AecFrame) -> [AecFrame] {
        guard let gap = filler.observe(
            hostTime: frame.hostTime,
            frameCount: frame.samples.count
        ) else {
            return []
        }
        logger.notice(
            """
            capture gap filled (microphone): \
            \(gap.seconds, format: .fixed(precision: 2), privacy: .public)s \
            = \(gap.frames, privacy: .public) frames
            """
        )
        let lengths = CaptureGapFiller.chunkLengths(
            totalFrames: gap.frames,
            maxChunkFrames: Int(sampleRate * GapFillingStreamSupport.maxChunkSeconds)
        )
        // 無音フレームの時刻は欠落区間の先頭から補間する(下流は時刻を使わないが、
        // 意味のない値を作らない)。
        var start = frame.hostTime - gap.seconds
        return lengths.map { length in
            defer { start += Double(length) / sampleRate }
            return AecFrame(samples: [Int16](repeating: 0, count: length), hostTime: start)
        }
    }
}

/// 1 ストリーム分の欠落判定と無音生成(`referenceTee` からも使う)。
struct CaptureGapFillState {
    private let kind: StreamKind
    private let logger: Logger
    private var filler: CaptureGapFiller?

    init(kind: StreamKind, logger: Logger) {
        self.kind = kind
        self.logger = logger
    }

    /// `item` の**前**に差し込むべき無音バッファ列。欠落が無ければ空。
    /// 無音の確保失敗は throw する(録音経路はドロップ禁止 ―― 無言で時間を失わない)。
    mutating func silenceBuffers(before item: TimestampedAudioBuffer) throws -> [AVAudioPCMBuffer] {
        let format = item.buffer.format
        guard format.sampleRate > 0 else { return [] }
        var current = filler ?? CaptureGapFiller(
            sampleRate: format.sampleRate,
            fillThreshold: GapFillingStreamSupport.fillThreshold
        )
        let gap = current.observe(hostTime: item.hostTime, frameCount: Int(item.buffer.frameLength))
        filler = current
        guard let gap else { return [] }
        let kind = kind
        logger.notice(
            """
            capture gap filled (\(kind.rawValue, privacy: .public)): \
            \(gap.seconds, format: .fixed(precision: 2), privacy: .public)s \
            = \(gap.frames, privacy: .public) frames
            """
        )
        let maxChunkFrames = Int(format.sampleRate * GapFillingStreamSupport.maxChunkSeconds)
        let lengths = CaptureGapFiller.chunkLengths(
            totalFrames: gap.frames,
            maxChunkFrames: maxChunkFrames
        )
        return try lengths.map { length in
            guard let silence = SilenceBuffer.make(
                format: format,
                frameCount: AVAudioFrameCount(length)
            ) else {
                throw CaptureError.bufferCopyFailed
            }
            return silence
        }
    }
}
