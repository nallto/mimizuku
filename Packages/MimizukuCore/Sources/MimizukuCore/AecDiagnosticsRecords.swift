import Foundation

/// AEC 診断試行(#75 / ADR-0015)の frames.jsonl に書く 1 行 = 1 レコード。
///
/// - `capture` の音声上の位置: `frameIndex × frameLength` が capture-raw.caf /
///   capture-processed.caf のサンプル位置。
/// - `renderFed` の `fedIndex` は **APM への給餌順 = APM 内部時間の正典**。
///   render-fed.caf のサンプル位置は `fedIndex × frameLength`。hostTime は補助情報。
/// - RMS はすべて Int16 フルスケール基準の dBFS。完全無音は −∞ を JSON に載せられない
///   ため nil(キー省略)とする。
public enum AecDiagnosticsRecord: Sendable, Equatable {
    case capture(Capture)
    case renderReceived(RenderReceived)
    case renderFed(RenderFed)
    case inputChunk(InputChunk)
    case event(Event)
    case apmStats(ApmStats)

    /// APM へ給餌する render フレームの出自。
    public enum RenderProvenance: String, Sendable, Equatable, Codable {
        case actual
        case gapFilled
    }

    /// 入力チャンクの由来ストリーム。
    public enum ChunkStream: String, Sendable, Equatable, Codable {
        case capture
        case render
    }

    /// production 側イベントの種別。
    public enum EventKind: String, Sendable, Equatable, Codable {
        case firstRender
        case epochReset
        case recoveryEntered
        case referenceInterrupted
        case leadRenderDropped
        case lateRenderDropped
        case renderQueueOverflowDropped
        case heldCaptureDropped
        case captureFramerDiscarded
        case renderFramerDiscarded
        case pumpFinished
    }

    /// APM 直前 / 直後の capture フレーム対。
    public struct Capture: Sendable, Equatable, Codable {
        /// capture 解放順の連番。raw / processed CAF のフレーム位置と 1:1。
        public var frameIndex: Int
        /// `.silence` を含め、実際に output へ yield したフレームごとに増加する連番。
        /// 入力 capture のフレーム番号とは別物(Speech への供給順)。
        public var outputFrameIndex: Int
        /// `outputFrameIndex × 0.01` 秒。マイク Speech 入力(解析器)の時刻原点。
        /// speech.jsonl の start/end はセッション原点へシフト済み(#94)のため、
        /// 対応は meta の `speechStartOffsets`(mic の値を引く)で取る。
        public var speechTimeSeconds: Double
        /// 正規化タイムライン上のフレーム開始時刻。
        public var hostTime: Double
        /// scheduler が無音置換した(APM を通っていない)フレームか。
        /// raw は原音のまま、processed はゼロが書かれる。
        public var silenced: Bool
        public var epoch: Int
        public var rawRMSDBFS: Double?
        public var processedRMSDBFS: Double?
        /// このフレームの直前に APM へ給餌した render フレーム数。
        public var renderFedCount: Int

        public init(
            frameIndex: Int,
            outputFrameIndex: Int,
            speechTimeSeconds: Double,
            hostTime: Double,
            silenced: Bool,
            epoch: Int,
            rawRMSDBFS: Double?,
            processedRMSDBFS: Double?,
            renderFedCount: Int
        ) {
            self.frameIndex = frameIndex
            self.outputFrameIndex = outputFrameIndex
            self.speechTimeSeconds = speechTimeSeconds
            self.hostTime = hostTime
            self.silenced = silenced
            self.epoch = epoch
            self.rawRMSDBFS = rawRMSDBFS
            self.processedRMSDBFS = processedRMSDBFS
            self.renderFedCount = renderFedCount
        }
    }

    /// tap → 変換 → framer 後の実参照フレーム(aligner へ入る前)。
    public struct RenderReceived: Sendable, Equatable, Codable {
        /// render-received.caf のフレーム位置と 1:1 の連番。
        public var renderFrameIndex: Int
        public var hostTime: Double
        public var epoch: Int
        public var rmsDBFS: Double?

        public init(renderFrameIndex: Int, hostTime: Double, epoch: Int, rmsDBFS: Double?) {
            self.renderFrameIndex = renderFrameIndex
            self.hostTime = hostTime
            self.epoch = epoch
            self.rmsDBFS = rmsDBFS
        }
    }

    /// APM が実際に受け付けた参照フレーム(充填無音を含む。受付失敗分は記録しない)。
    public struct RenderFed: Sendable, Equatable, Codable {
        /// 給餌順の連番 = APM 内部時間の正典。render-fed.caf のフレーム位置と 1:1。
        public var fedIndex: Int
        public var hostTime: Double
        public var epoch: Int
        public var provenance: RenderProvenance
        /// どの capture フレームの直前に給餌したか(`Capture.frameIndex`)。
        public var fedBeforeCaptureFrameIndex: Int
        public var rmsDBFS: Double?

        public init(
            fedIndex: Int,
            hostTime: Double,
            epoch: Int,
            provenance: RenderProvenance,
            fedBeforeCaptureFrameIndex: Int,
            rmsDBFS: Double?
        ) {
            self.fedIndex = fedIndex
            self.hostTime = hostTime
            self.epoch = epoch
            self.provenance = provenance
            self.fedBeforeCaptureFrameIndex = fedBeforeCaptureFrameIndex
            self.rmsDBFS = rmsDBFS
        }
    }

    /// 捕捉コールバックから届いた入力チャンク(正規化前の実測時刻を保持する)。
    public struct InputChunk: Sendable, Equatable, Codable {
        public var stream: ChunkStream
        /// コールバックの実測時刻(正規化前)。
        public var observedHostTime: Double
        /// `AecTimeline` 正規化後のチャンク開始時刻。
        public var normalizedHostTime: Double
        public var sampleCount: Int
        /// 実測 − 予測(ms)。初回チャンクは予測を持たないため nil。
        public var timingDeltaMs: Double?
        public var rebased: Bool
        public var epoch: Int
        /// `AecDriftDiagnostics` の現在値。計測開始 10 秒未満は nil。
        public var driftPPM: Double?

        public init(
            stream: ChunkStream,
            observedHostTime: Double,
            normalizedHostTime: Double,
            sampleCount: Int,
            timingDeltaMs: Double?,
            rebased: Bool,
            epoch: Int,
            driftPPM: Double?
        ) {
            self.stream = stream
            self.observedHostTime = observedHostTime
            self.normalizedHostTime = normalizedHostTime
            self.sampleCount = sampleCount
            self.timingDeltaMs = timingDeltaMs
            self.rebased = rebased
            self.epoch = epoch
            self.driftPPM = driftPPM
        }
    }

    /// production 側の破棄・遷移イベント。発生しても診断試行は invalid にしない
    /// (invalid の対象は診断経路自身の欠損のみ ―― `AecDiagnosticsMeta.invalidReasons`)。
    public struct Event: Sendable, Equatable, Codable {
        public var kind: EventKind
        public var hostTime: Double?
        public var firstHostTime: Double?
        public var lastHostTime: Double?
        public var frameCount: Int?
        public var sampleCount: Int?
        public var deltaMs: Double?
        public var epoch: Int
        public var message: String?

        public init(
            kind: EventKind,
            hostTime: Double? = nil,
            firstHostTime: Double? = nil,
            lastHostTime: Double? = nil,
            frameCount: Int? = nil,
            sampleCount: Int? = nil,
            deltaMs: Double? = nil,
            epoch: Int,
            message: String? = nil
        ) {
            self.kind = kind
            self.hostTime = hostTime
            self.firstHostTime = firstHostTime
            self.lastHostTime = lastHostTime
            self.frameCount = frameCount
            self.sampleCount = sampleCount
            self.deltaMs = deltaMs
            self.epoch = epoch
            self.message = message
        }
    }

    /// APM の `GetStatistics()`。すべて **APM 内部推定値**であり、実測の除去量そのもの
    /// ではない。全フィールド optional(APM が値を報告しない間は欠落する)。
    /// delay median/std は初回取得後に 1 秒集約へ切り替わる(webrtc 仕様)。
    public struct ApmStats: Sendable, Equatable, Codable {
        public var hostTime: Double
        public var echoReturnLoss: Double?
        public var echoReturnLossEnhancement: Double?
        public var delayMs: Double?
        public var delayMedianMs: Double?
        public var delayStdMs: Double?
        public var divergentFilterFraction: Double?
        public var residualEchoLikelihood: Double?

        public init(
            hostTime: Double,
            echoReturnLoss: Double? = nil,
            echoReturnLossEnhancement: Double? = nil,
            delayMs: Double? = nil,
            delayMedianMs: Double? = nil,
            delayStdMs: Double? = nil,
            divergentFilterFraction: Double? = nil,
            residualEchoLikelihood: Double? = nil
        ) {
            self.hostTime = hostTime
            self.echoReturnLoss = echoReturnLoss
            self.echoReturnLossEnhancement = echoReturnLossEnhancement
            self.delayMs = delayMs
            self.delayMedianMs = delayMedianMs
            self.delayStdMs = delayStdMs
            self.divergentFilterFraction = divergentFilterFraction
            self.residualEchoLikelihood = residualEchoLikelihood
        }
    }
}

// MARK: - 判別子付き Codable(1 行 = 1 JSON オブジェクト、"type" で判別)

extension AecDiagnosticsRecord: Codable {
    private enum TypeCodingKey: String, CodingKey {
        case type
    }

    private var typeName: String {
        switch self {
        case .capture: "capture"
        case .renderReceived: "renderReceived"
        case .renderFed: "renderFed"
        case .inputChunk: "inputChunk"
        case .event: "event"
        case .apmStats: "apmStats"
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: TypeCodingKey.self)
        try container.encode(typeName, forKey: .type)
        switch self {
        case let .capture(payload): try payload.encode(to: encoder)
        case let .renderReceived(payload): try payload.encode(to: encoder)
        case let .renderFed(payload): try payload.encode(to: encoder)
        case let .inputChunk(payload): try payload.encode(to: encoder)
        case let .event(payload): try payload.encode(to: encoder)
        case let .apmStats(payload): try payload.encode(to: encoder)
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: TypeCodingKey.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "capture": self = try .capture(Capture(from: decoder))
        case "renderReceived": self = try .renderReceived(RenderReceived(from: decoder))
        case "renderFed": self = try .renderFed(RenderFed(from: decoder))
        case "inputChunk": self = try .inputChunk(InputChunk(from: decoder))
        case "event": self = try .event(Event(from: decoder))
        case "apmStats": self = try .apmStats(ApmStats(from: decoder))
        default:
            throw DecodingError.dataCorrupted(DecodingError.Context(
                codingPath: container.codingPath,
                debugDescription: "未知のレコード種別: \(type)"
            ))
        }
    }
}
